# Plan: Diskette Write Support for MacLC_MiSTer

Scoped 2026-09-07; staging rationale revised 2026-09-14 (§1). No code
written yet.

Prior art, all local and all ours:

- `../MacPlus_MiSTer/FLOPPY_WRITE_PLAN.md` — the same feature, phases 0–5 done
  and shipped. Donates RTL and a six-defect review list.
- `../UK101_MiSTer/SAVE_AND_DISK_PLAN.md` — donates the **write-address
  anchoring** design (§6.1) and the multi-slot block-device plumbing pattern.

This plan is not a copy of either. It records what is DIFFERENT here, and what
ports over unchanged.

---

## 1. Scope

**RELEASE GATE — owner's ruling 2026-09-15: nothing is released until every
format is covered.** One PR, one release: GCR *and* MFM, read *and* write *and*
format. The stage split below is INTERNAL SEQUENCING — the order we build and
validate in — and is not a shipping plan. Do not describe it as one outside this
repo; the maintainer has been given the finished format list, not the stages.

**Stage 1 — GCR (400K/800K).** Exact MacPlus parity, and it keeps the first
hardware write run inside a format whose write semantics are already solved on a
sister core. 1.44MB/720K MFM stays read-only until stage 2.

**Stage 2 — MFM/ISM writes.** §8.

★ Revised 2026-09-14. The original rationale — *"it carries the one design
problem that is new to this core"* — is **retired**: UK101 answered that problem
(§6.1) before any code was written. The split stands on two different legs, both
stronger than the one they replace:

- **Risk containment.** Phase 3 proves the write handshake on hardware for the
  first time, and a wrong handshake HANGS the machine (§2.1, §6.4). A GCR data
  field self-identifies its sector (§4), so a stage-1 commit is gated by
  "checksum valid AND the field named its own sector" — no positional inference
  anywhere in the path. Folding MFM in puts an unproven handshake and an
  unproven positional anchor on the same first hardware run, against the user's
  real images. UK101's severity inversion is the warning (§6.1): its
  rotational-position attempt failed *safely* and was caught by the guest's own
  verify; the more plausible-sounding replacement failed *catastrophically*,
  writing through to media and destroying an unrelated sector header.
- ~~**Shippability.**~~ **RETIRED 2026-09-15** by the release gate above — GCR
  write is not a release on its own any more, so this leg is gone. Risk
  containment carries the split unaided: the first hardware write run should not
  also be the first run of an unproven positional anchor.

What the UK101 find DID change is scheduling *within* stage 1: two stage-2
design decisions are cheap now and expensive to retrofit, so they land in
Phase 3 even though MFM writes ship later — the identity-bearing staging ring
and the format-neutral committer.

**Formatting is IN SCOPE, for both formats.** ★ Corrected 2026-09-15. This
paragraph previously read *"out of scope in both stages, as on MacPlus"* and
both halves of that were wrong:

- **MacPlus ships formatting.** `../MacPlus_MiSTer` `7712c0e` (2026-09-10 —
  three days after this plan was first written) landed Erase Disk, hardware
  confirmed: *"Read, write and a full format have all been confirmed on hardware
  through the chained drive."* Donor inventory in §1.1.
- **MFM formatting is not the flux job it sounds like.** The LC's MFM path is
  BYTE-level: the SWIM does the data separation and the CPU only ever sees
  decoded bytes plus a mark flag through the ISM FIFO (`rtl/mfm_track_encoder.v`
  header; `rtl/swim.v:40` "Push data+mark to FIFO", FIFO b8 = MARK at `:164`).
  A guest format is therefore the CPU pushing `00 x12 / A1 A1 A1 (mark) / FE /
  C H R N / CRC-16 / 4E …` as plain bytes — a byte-stream state machine plus
  CRC-16-CCITT, with no flux recovery, no PLL and no bit windows. If anything it
  is SIMPLER than the GCR decoder, which carries 6:2 nibblization and a
  three-way checksum chain.

So whole-track address-field writes are the same class of work here as sector
writes, not a separate discipline. What makes formatting non-trivial on this
core is not the encoding but the **read-side relay** (§1.1) and the **sidedness
ceiling** (§1.1) — two defects MacPlus already found and fixed, which we would
otherwise rediscover on hardware.

(UK101's `wr_ptr` reset-on-seek makes its FORMAT correct for free — see §6.1.)

### 1.1 Donor inventory — MacPlus `7712c0e` (Erase Disk)

Surveyed 2026-09-15. Only the floppy half of that commit is relevant; its
daisy-chain / HD 20 / `iwm.v` half is Plus-specific and the LC has neither an
HD 20 nor an IWM chip (it has a SWIM).

| From MacPlus | Lines | Transfer to LC |
|---|---|---|
| `rtl/floppy_track_decoder.v` | 384 | **Essentially verbatim.** Machine-independent: raw write-stream bytes + geometry in, verified sectors out. Already reports the address fields a format writes (`amark`, `fmt_mark`, `fmt_ds`) — that *is* its format support. |
| `rtl/floppy_write_committer.v` | 160 | Ports; LC slot / base-address differences only. |
| `rtl/floppy_sd_writer.v` | 218 | Ports; same. |
| `floppy_track_encoder.v` format relay | ~+60 | **Clean port.** Diffed 2026-09-15: our encoder is the same file minus the relay. |
| Media sidedness (`floppy_loader.v` + `floppy.v`) | ~125 | Concept only — our `floppy_loader.v` is the new block-device one, so this is a re-implementation, not a copy. |

Two defects that commit paid for, which we inherit the fixes to rather than
rediscovering:

1. **The format relay / `fmt1Err`.** The ROM requires sector 0 to be the first
   address field it sees after the track is written; a free-running read side
   fails the format. The encoder must relay the read position to wherever the
   format actually put sector 0, measured from the address mark the decoder
   reports.
2. **The sidedness ceiling.** The address field's format byte was derived from
   the image file's SIZE, so a One-Sided erase of an 819,200-byte image
   formatted side 0 and then advertised the disk as double-sided — letting the
   driver build an 800K volume over a side that was never formatted. Every 3.5"
   diskette is one medium; 400K vs 800K is a formatting choice and nothing on
   the diskette records it. `doubleSidedDisk` needs three terms, each a ceiling
   on the next: drive mechanism, file size, then the medium itself (sniffed from
   the volume header at load, re-read from the format byte once a format
   overwrites it).

**Also checked, and no help** (confirming the 2026-09-07 survey in §8 from the
local copies): `../BBCMicro_MiSTer/rtl/fdc1772/fdc1772.v` stubs the WD1772's
Write Track outright — `// write track TODO: fake` at `:657` — and the MiSTer
Atari ST core uses the same file. `../Apple-IIgs_MiSTer/rtl/iwm_flux.v` is
flux-level but Apple GCR, not MFM. Minimig/Amiga does decode written MFM tracks,
but to Amiga track layout (sync `$4489`, odd/even bit split, no IDAM and no
CRC-16), so only the cell-level encoding would transfer and that is exactly the
layer we do not need. See §8 for why the controller-model cores (`u765.sv`,
`fdc1772.v`) structurally cannot donate an answer.

---

## 2. Where the core stands today

**2.1 — Every disk reports write-protected.** `rtl/floppy.v:241` hardwires
`1'b0, // WRTPRT = locked` in `driveRegsAsRead`. The OS reads this, concludes
the disk is locked, and never attempts a write.

★ This is load-bearing today, not merely a default. Per CLAUDE.md the ROM's
write primitive polls its handshake in an UNBOUNDED loop: a write attempted
against the current stub handshake would HANG the machine, not fail.
Unhardwiring WRTPRT and implementing the real handshake are the same commit.

**2.2 — The write datapath is a stub.** `rtl/floppy.v:76` declares
`input [7:0] writeData` and the file never references it again.

**2.3 — The IWM handshake lies.** `rtl/swim.v:176`:

```verilog
assign _iwmBusy = 1'b1;       // write buffer empty
assign _writeUnderrun = 1'b1;
```

**2.4 — ISM write mode runs no engine at all.** `rtl/swim.v:376`:
`ism_arm = ism_mode && ism_mode_reg[3] && !ism_mode_reg[4]` — ACTION on, WRITE
off. Setting Mode b4 today does nothing.

**2.5 — Floppies are downloads, not block devices.** `MacLC.sv:83-84` are
`F1`/`F2` CONF_STR rows streamed once through `ioctl_download` into SDRAM
(images live at word `23'h600000` internal / `23'h700000` external,
`rtl/addrController_top.v:275-276`). `ioctl_download` is one-way: there is no
file handle to write back through, so no amount of GCR decoding persists
anything. **This is the single biggest structural obstacle**, exactly as on
MacPlus. `VDNUM` is already 6 (`MacLC.sv:211`), so widening is routine.

**2.6 — There is a free extra slot, but the write path should not use it.**
`extra_slot_count == 2` is idle (`rtl/addrController_top.v:359`, legacy sound
DMA removed). Use the `sdram.v` LEVEL-handshake requester pattern instead — §6.3.

---

## 3. What the LC does NOT have to deal with

Stated explicitly because it is where the LC's validation matrix is strictly
smaller than MacPlus's.

| Axis | MacPlus | MacLC |
|---|---|---|
| CPU speed | OSD `O5,Speed,8MHz,16MHz` fans `status_turbo` into `cpu_en_p/n`, DTACK, BOTH VIAs' `E_div`, and the disk logic | **One fixed rate.** No turbo, no `E_div` select, no `clk16_en_*` |
| Machine model | 5 models via `rtl/mac_model.v` → `configROMSize`, `machineType`, `romSlot`, `drive800k`, `scsiPresent` | **One machine.** No equivalent module, none needed |
| ROM | 4 `bootN.rom` images selected by `romSlot` | **One ROM** (`dio_index == 0`, `MacLC.sv:167`) |
| CPU | Plus/SE 68000 variants | **Hardwired** `localparam [1:0] status_cpu = 2'b10; // 68020` (`MacLC.sv:170`) |
| Drive capability | Per-model `drive800k` gates 400K-only mechanisms, passed into `floppy.v` | Both drives identical; media type comes from the image |
| External port contention | HD20/DCD is exclusive with the external floppy | Nothing else claims the port |

MacPlus's write path must hold across roughly *5 ROMs × 2 CPU rates × 2 drive
capabilities × DCD-present-or-not*. Stage 1 here is **2 drives × {400K, 800K}**.

In particular there is **one ROM write loop to satisfy**, so MacPlus's Phase 3
risk ("will this ROM tolerate the byte-synchronous drive model") is answered
once and stays answered.

The one axis where the LC is *more* complex is format: GCR and MFM through the
same SWIM. Stage 1 exists to take that off the table for v1.

★ **CLAUDE.md was stale here; CORRECTED 2026-09-14.** "CPU speeds: 8 MHz
(original) or 16 MHz" and the known limitation "Floppy won't read at 16 MHz CPU
speed" were both inherited MacPlus text, and neither was true of this core. The
rate is **fixed 16.25 MHz**: `clk_sys` 32.5 MHz (`rtl/pll.v` outclk_1) with
`clk16_en_p/n` alternating every cycle (`rtl/addrController_top.v:115`), so a
phi1/phi2 pair spans 2 clk_sys cycles. The 8.125 MHz `clk8_en_p/n` off the same
divider is the peripheral bus enable — the likely origin of the "8 MHz" half.
The second line mattered most: it is a *floppy timing* limitation pointing at a
mode that does not exist, i.e. a ready-made false lead for exactly this work.

---

## 4. Target architecture (stage 1)

```
Mac CPU --write--> IWM writeData reg  --> floppy.v write strobe (1 byte / 16us)
                        |                          |
              real _iwmBusy handshake              v
                                        floppy_track_decoder.v   (PORT)
                                        strip sync, find D5 AA AD,
                                        de-nibblize 6:2, verify checksum
                                                   |
                                                   v
                                        512-byte BRAM sector buffer
                                                   |
                              +--------------------+--------------------+
                              v                                         v
                  SDRAM image write-back                     HPS sd_wr -> file on SD
                  (sdram.v level-handshake port)             (LBA = offset >> 9,
                  keeps the read path coherent                + DC42 header offset)
```

Two choices carried from MacPlus, both still right here:

- **Buffer a whole sector in BRAM before committing.** Gives a natural place to
  enforce "only commit on valid checksum", produces exactly the 512-byte buffer
  `sd_buff` wants, and avoids byte-granular strobe control.
- **Write to both SDRAM and SD.** SDRAM keeps the in-memory image coherent so
  the guest's read-after-write verify passes; the `sd_wr` makes it durable.

**Stage 1 needs no rotational anchor.** An Apple GCR data field carries its own
sector number (`D5 AA AD` + 6-bit sector), so: **sector** from the decoded
data-field header, **track** from `driveTrack`, **side** from `driveSide`. This
is the property that made MacPlus tractable. Stage 2 loses it — §6.1.

---

## 5. Phases

Each phase ends at a gate evaluable on its own.

### Phase 0 — Sim harness and format ground truth — **COMPLETE 2026-09-14**
*No core changes, and none were made.*

**Gate result: PASS.** 160 track dumps (all 80 tracks x 2 sides) from the real
`rtl/floppy_track_encoder.v`; **1600/1600 sectors round-trip byte-exactly**, and
all rejection cases hold. Artifacts:
`verilator/tb_floppy_track_encoder.v`, `scripts/gcr_common.py`,
`scripts/gcr_gen_image.py`, `scripts/gcr_decode_track.py`,
`scripts/gcr_test_negative.py` (build + run lines in each header).

- ~~Bench driving `rtl/floppy_track_encoder.v` standalone against a synthetic
  image.~~ **DONE.** Runs under **Icarus 12.0, natively on Windows** (no
  Verilator, no WSL) — the bench is one standalone module with `$readmemh` /
  `$fopen`, so it needs none of the `verilator/Makefile` machinery. `+alltracks`
  does the full sweep in ~83 s; the default is the representative 4 tracks x 2
  sides in ~4.5 s. **Phase 1 onward still needs Verilator 5.x** (`tb_disk_swap.v`,
  and Phase 2's RTL-to-RTL round-trip); apt on Ubuntu 22.04 ships 4.038, which
  has neither `--binary` nor `--timing`, so that means building from source.
- ~~Reference decoder in Python; confirm byte-exact recovery of all sectors.~~
  **DONE**, against the RTL dumps rather than a model of the encoder.
- ~~Fix the stale CLAUDE.md CPU-speed lines (§3).~~ **DONE 2026-09-14.**

**Gate:** the reference decoder round-trips every sector of a synthetic 800K
image byte-exactly, and rejects a corrupt data byte, a corrupt checksum byte,
and a truncated field.

MacPlus's `sim/` artifacts ported over. **The "confirm, do not assume" check
was done and is the strongest single result here: `rtl/floppy_track_encoder.v`
is BYTE-IDENTICAL between the two cores** (plain `diff`, zero differences), so
the ported decoder inherits MacPlus's validation rather than merely resembling
it. Re-run that diff before trusting any of this again.

★ **UPDATE 2026-09-15 — the two files are no longer byte-identical, and the
claim above still holds.** MacPlus `7712c0e` added the format relay to its
encoder (§1.1), so a plain `diff` now reports 76 changed lines. Re-checked
line by line: **every one of them is inside the relay block** (the `wr_*`
ports, the `relay_*` registers, `STATE_GAP`, `rev_len`/`SECTOR_BYTES`) or is
trailing whitespace. Ours is MacPlus's file MINUS the relay, so the stream
this core emits is unchanged and the inheritance is intact. The right check
from here is therefore not `diff` but `diff -w` filtered for relay lines — or
simply the Phase 2 round-trip, which tests the property directly rather than
by proxy. Two deliberate
departures from MacPlus's artifact list:

- **`encoder_model.py` was NOT ported.** Its job there was to prove a Python
  reading of the nibbler correct so a decoder could be built from it. With
  Icarus present the decoder is validated directly against real RTL dumps,
  which is strictly stronger — a model cannot catch a misunderstanding it
  shares with the decoder built from it. Port it only if a future task needs
  GCR streams generated without a simulator.
- **The negative tests were rebuilt, not ported.** MacPlus's asserted only that
  an error was reported *somewhere near* the corruption, and its truncation case
  asserted `len(errors) >= 0`, which is vacuously true. Ours name the sector:
  the corrupted one must vanish and every other sector must survive byte-intact.
  ★ That required cutting the stream to ONE REVOLUTION first — a 20000-byte
  capture holds 2+ revolutions, so each sector appears twice and corrupting one
  copy leaves the other to be "recovered", a test that passes while proving
  nothing.

Format facts established from the FSM while building this, all load-bearing for
Phase 2's RTL decoder:

- Sector layout is `SYN0 56 | ADDR 10 | SYN1 5 | DHDR 4 | DZRO 12 | DPRE 4 |
  DATA 683 | DSUM 4 | DTRL 3 | WAIT 1` = **782 bytes**, confirmed against the
  observed mark-to-mark pitch. ★ **DZRO is 12 bytes, not 8** — the RTL comment
  says "8 zero bytes" but the FSM counts to 11.
- The encoder writes with an **interleave of 2** (sectors come off the track
  0,2,4,... then 1,3,5,...). Harmless for a decoder keyed on the sector number
  in the field; fatal for one that infers position.
- **The nibbler needs a one-group LOOKBACK.** `nib_xor_0/1/2` are registers read
  combinationally, so group *g*'s four output bytes encode group *(g-1)*'s three
  data bytes, not their own. This is the bug MacPlus shipped first and caught
  only by round-tripping against RTL — not by reading the Verilog.

### Phase 1 — Convert floppies to block devices (still read-only) — **COMPLETE 2026-09-15**
*The riskiest plumbing change, isolated from any write behaviour.*

**Gate result: PASS, on hardware, on a STOCK Main.** Every item below was run;
details in "Gate progress".<br>
Code: `2fff730` + `85bdf83` + `410a064`.

- CONF_STR: `F1`/`F2` → `S` mount slots; widen `VDNUM` from 6, keeping every
  existing device on its current index so users' saved mounts are undisturbed.
- Mount-time loader FSM: on `img_mounted`, stream the image via `sd_rd` into
  SDRAM at the existing `600000`/`700000` word offsets.
- Re-derive the media-change machinery from `img_mounted`/`img_size` — §6.2.
- Latch `img_readonly` per slot **at that slot's own mount pulse**. Precedent to
  copy verbatim: `../UK101_MiSTer/UK101.sv:274-277` (four drives, four
  independent latches) — cited by MacPlus's plan for the same reason.

**Gate (hardware):** boots from floppy exactly as before — both drives, 400K and
800K, GCR and MFM, DC42 and raw, eject and remount, floppy + SCSI together. No
write behaviour introduced. A regression here is provably plumbing.

**Gate progress (2026-09-15) — ALL ITEMS PASS.** "Both drives" is moot since
`410a064` removed the phantom second floppy.
- ✅ **Boots from floppy** — raw 800K GCR, System 6.0.8 System Tools.
- ✅ **Mounts** — 400K GCR, 800K GCR and 1.44MB MFM, DC42 *and* raw.
- ✅ **Eject and remount** (media change) — several disks mounted and
  unmounted in succession, all correct. No ghost volume, no stuck `SWITCHED`.
  ★ Run it
  **guest-eject-first**, and **not against the boot floppy**: per CLAUDE.md,
  swapping under a live volume is hostile on a real Mac too (MAME 6.0.8 bombs
  with "Disk Initialization package not present" when the boot floppy is
  yanked), because drives only eject under software control and the OS has no
  graceful path. An OSD swap with no guest eject would therefore produce a
  FALSE failure. Boot from SCSI, then mount / guest-eject / mount-a-different
  image. The regression being hunted is the ghost volume: mounts and lists but
  every call fails with no driver error and zero disk I/O, which is what the
  guest never being told the medium changed looks like.
- ✅ **Boots from a DC42** — the `mk_dc42.py` fixture built from the same
  System 6.0.8 disk. No LC-bootable DC42 existed to test with (every one to
  hand is 1985-87 era, a non-bootable application disk, or truncated), so the
  fixture is the raw disk that is known to boot, wrapped: byte-identical
  payload, making raw-vs-DC42 an exact A/B whose only variable is the 84-byte
  strip. Both booted. **The strip is correct end to end**, which is a stronger
  result than a mount — a wrong offset would still mount and list.

★ Watch the **tag section** when making DC42 fixtures. A DC42 may legally carry
`tagSize` 0, and an 800K image built that way has a payload of exactly 819200
bytes — which *passes* the raw size test, masking a regression to size-based
geometry with the very image meant to catch it. `mk_dc42.py` therefore always
writes the tags (zero-filled; HFS does not read them), giving the 838400-byte
payload that matches no size test.

★ **Four of the 19 DC42 images on the owner's machine are damaged**, found by
checksum-verifying them all before choosing a fixture: the three System 2.0.1
disks have bad data checksums (modified after creation) and
`Arkanoid_1_00.dsk` is a valid DC42 truncated by exactly 84 bytes — its payload
is 819116, not a whole number of sectors. Verify a fixture before gating on it;
a bad image imitates a core bug perfectly. (`Arkanoid_1_00` would make a good
negative case later.)

### Phase 2 — GCR decoder RTL — **COMPLETE 2026-09-15**

**Gate result: PASS.** `verilator/tb_floppy_track_decoder.v` drives the real
`rtl/floppy_track_encoder.v` into the real `rtl/floppy_track_decoder.v`:
**6269 checks green over all 160 track/side combinations**, 4000 sector
acceptances (25 per track = 2+ revolutions each), covering all
16×(12+11+10+9+8)×2 = **1600 distinct sectors byte-exactly**, plus six negative
cases. Runs on Icarus 12.0 natively — ~2m38s for the sweep, ~20 s for the
default representative 8 tracks. Build + run lines are in the bench header.

`rtl/floppy_track_decoder.v` is a **verbatim** port (source md5
`6fcd1267e0d1765847c7d1009763848a`); only a provenance header was added. That is
the whole value of the port — this core's encoder is MacPlus's file minus the
format relay (**re-diffed 2026-09-15: every differing line is inside the relay
block**, so Phase 0's inheritance claim still holds even though the two files
are no longer byte-identical), so the decoder is the algebraic inverse of the
exact stream we emit and arrives already validated on a sister core.

**Two independent positive checks**, both riding on
`scripts/gcr_gen_image.py`'s self-identifying pattern (bytes 0..2 of a sector
are track, side, sector):
1. `recovered[0..2]` == the (track, side, sector) the bench is driving — proves
   the decoded PAYLOAD is this sector's data, using no address at all.
2. `recovered[k] == mem[addr + k]` for all 512 — proves `addr` lands on exactly
   this sector. **This is the check Phase 3's committer rides on.** A generic
   counter pattern would let a wrong-address fetch pass it; this one cannot.

**Format neutrality — decided, and it is the opposite of the obvious reading.**
The GCR geometry (`soff`/`spt`, the variable-speed zones) stays INSIDE the
decoder rather than moving to the committer. Putting `addr` in the committer
would force the committer to hold a geometry table per format — i.e. make it
format-AWARE, exactly what the §1 carve-out exists to prevent. So the contract
Phase 3 consumes is **`(sector_valid, sector, addr, buf)`**, with `track`/`side`
as decoder inputs, and stage 2's MFM decoder presents the same tuple while
computing its own flat 18-sector geometry.

**A behavioural difference from the Phase 0 Python decoder, where the RTL is
the one that is right** — recorded because it will look like a bug to the next
reader. Corrupting an ADDRESS field's checksum makes the Python decoder lose
the sector (it pairs an address field with the data field that follows it). The
RTL scans for `D5 AA AD` independently and takes the sector number from the
DATA field, which carries its own checksum — so the sector still decodes and
only `fmt_mark` is suppressed. That independence *is* the §4 property stage 1
rests on: no positional inference anywhere. The bench asserts the RTL behaviour
explicitly (case 6) so nobody later "fixes" it into agreement with Python.

Negative cases, each naming the sector that must vanish while every other
sector survives byte-intact (the Phase 0 standard, not MacPlus's "an error was
reported somewhere near here"): corrupt payload byte → a different VALID GCR
code, corrupt checksum byte → likewise, an invalid nibble, a broken `DE AA`
trailer, a stream cut mid-field, and the address-checksum case above. Corruption
values are taken FROM the captured stream rather than from a copy of the forward
table, so the bench cannot drift from the encoder's table. ★ All negative runs
are **one revolution only** — a 20000-byte capture holds 2+ revolutions, so
corrupting one copy of a sector leaves the other to be "recovered", a test that
passes while proving nothing. Same trap as Phase 0.

★ **`rtl/floppy_track_decoder.v` is deliberately NOT in `files.qip` yet.**
Phase 3 adds it, when it is first instantiated. Adding dead RTL now would
perturb the Quartus warning baseline that §7 defect 1 tells us to diff compile
over compile, for no gain.

★ Bench bug worth remembering (cost one debug cycle): `integer corrupt_idx`
powers up **x**, and `x >= 0` is x, so the injector's ternary fed the decoder x
for the entire run. The symptom was a perfect "the decoder detects nothing" —
zero sectors, zero rejects, zero address marks, on every track — which reads as
a broken DUT rather than a broken bench. An uninitialised `integer` in a
comparison is the same class of hazard as the `#1` edge discipline: it fails
silently and blames the wrong module.

### Phase 3 — IWM write path, volatile writes only
*The "will the ROM cooperate" gate. Structurally cannot touch the user's file.*

**Phase 3a — the handshake — CODE LANDED 2026-09-15, sim gate PASS.** Split out
deliberately: §6.4 says a wrong handshake HANGS the machine, so the handshake
gets its own hardware run with nothing able to reach memory or the file. Sim
gate is `verilator/tb_floppy_write.v`, **55 checks** on Icarus — handshake
shape (busy asserts on accept, clears after exactly 128 cep ticks, one
`decReady` per byte), four silent refusals (write-protected / no disk / CSTIN
set / drive deselected), deselect-mid-byte raising underrun, a media change
abandoning an in-flight byte, and a **full-track round-trip**: all 12 sectors
of track 0 written through the IWM data register and decoded back byte-exact
at the right address.

★ **With the OSD toggle Off — the default — hardware behaviour is identical to
today.** `writeBusy` can never assert (no byte is ever accepted), so `_iwmBusy`
and `_writeUnderrun` read 1 exactly as the old hardwired stubs did, and WRTPRT
reads locked. That is what makes 3a safe to fit and boot.

What is NOT in 3a: any commit path. `wrSecValid/Num/Addr` are produced and
watched, and go nowhere.

Three things worth carrying forward:
- **`writeReq` is a LEVEL, not a pulse.** One CPU access spans several `cen`
  ticks, and floppy.v's `!writeBusyReg` guard is what collapses that to one
  byte. A pulse-shaped bench stimulus would pass while never reaching that
  guard, so the bench holds the level on purpose. (Held longer than a whole
  byte time it would hand over a second byte — unreachable here, since an
  E-paced VPA access is ~1.23 us against a 15.75 us byte time. Recorded rather
  than asserted against.)
- ~~**Placement in `floppy.v` is load-bearing.**~~ **RETRACTED 2026-09-15 — this
  was wrong, and it is recorded rather than deleted because the wrong version
  was reported as a caught bug.** The claim was that putting the write block
  above `driveWriteAddr` would make Verilog implicitly declare it a 1-BIT net
  and silently truncate the 3-bit eject compare. `floppy.v` itself disproves it:
  the `dbg_media` block does exactly that compare ~20 lines ABOVE
  `driveWriteAddr`'s declaration, and it is hardware-validated (2026-08-06, and
  ejects worked on hardware again today). A forward reference to a net
  **declared later in the same module** resolves correctly; a scan found ~82 of
  them across `floppy.v`, `swim.v`, `MacLC.sv` and `dataController_top.sv`, in
  code that ships. Declare-before-use is better style and the blocks were left
  in their moved positions, but it is not a correctness fix.
  ★ The REAL hazard is adjacent and worth keeping: an identifier **never
  declared anywhere** does get an implicit 1-bit net, and that truncates
  silently. Verilator flags it as Warning-IMPLICIT (`selectASC` in `sim.v` is a
  live example); Quartus need not. So the thing to watch is a mistyped signal
  name, not declaration order.
- **The decoder needs an anchor or it does not exist in the fit.** Nothing
  consumes the tuple until Phase 4, so synthesis sweeps the whole decoder away;
  it would then appear for the first time in the same fit as the committer and
  the SDRAM requester, giving a timing failure three candidate causes instead
  of one. `wr_anchor0/1/2` in `floppy.v` pin it, under the same never-fold law
  as MacLC.sv's always-on anchor (§ the 2026-08-04 floppy-cone extension).

**Gate (hardware) for 3a — PASS, 2026-09-15.** Fit `MacLC_5608e02a_phase3a.rbf`
(md5 `31f777b0`). No hang, no crash. With the toggle On and a scratch raw image,
a Finder copy ran to completion and then failed with *"the file couldn't be
verified, because a disk error occurred"*; the file did not land.

★ **The failure was at the VERIFY stage, not the WRITE stage, and that is where
the information is.** Three separate things are confirmed by which error
appeared:
- **WRTPRT unhardwiring works.** A still-locked disk makes the Finder refuse up
  front ("the disk is locked") and never start copying.
- **The handshake works and raises no spurious underruns.** A misbehaving
  `_writeUnderrun` surfaces as a write error mid-copy, not a verify failure at
  the end. The ROM's UNBOUNDED poll loop (§2.1) completed every time — that was
  the hang risk this phase existed to retire.
- **Nothing was committed, as designed.** The verify reads SDRAM, which still
  holds the pre-write contents, so it mismatches.

★ **Consequence for Phase 3b's gate: the guest's own verify is a built-in
oracle.** A Finder copy completes only if every sector decoded byte-exactly —
sector number, address and all 512 payload bytes. So "the copy succeeds" is a
far stronger check than it appears, and no HUD or JTAG fit is needed to read the
decoder's counters. A wrong decode fails in exactly the way just observed.

(The owner expected the file to appear and then vanish on unmount. That is the
**Phase 3b** behaviour — it needs the SDRAM commit for the verify read to find
anything.)

**Phase 3b — commit to SDRAM.** The committer, `wrBufAddr` driven for real, and
the read-after-write the guest's verify depends on. Also lands, now that 3a is
gated:
- **Drop the `!flp_int_raw` term** from `flp_int_wp` (§6.2) — DC42 is writable
  by the owner's ruling, and phases 3a/3b need nothing else for it because
  SDRAM holds normalised sector data whatever the container was.
- **A parameter on `floppy.v` so `floppyExt` elaborates WITHOUT the write
  path.** The Phase 3a fit revealed the cost: `floppy_track_decoder` is
  instantiated unconditionally, so the external drive — which never has media
  and has `writeProtect` tied high — carries a decoder it can never use.
  Quartus reported it as Warning 18550, "implemented as ROM because the write
  logic is always disabled", which also independently confirms the tie-off
  works. It wastes roughly 1 M10K at 92% M10K utilisation. Unlike removing the
  `floppyExt` instance itself (which `410a064` deliberately kept), this changes
  nothing drive-visible.

- Real `writeReq`/strobe/byte from `swim.v` into `floppy.v`.
- Real `_iwmBusy` (assert on CPU write to the data register, clear after one
  byte time) and an honest `_writeUnderrun`, replacing `rtl/swim.v:176`.
- Unhardwire `rtl/floppy.v:241`; drive WRTPRT from a new OSD write-enable
  **defaulting to Off**, ANDed with the latched `img_readonly`.
- Commit decoded sectors to the **SDRAM image only**. No `sd_wr` yet.
- **Stage-2 carve-out — do it now:** latch the emitting sector's identity into
  `swim.v`'s 16-deep staging ring **alongside each delivered byte**. Stage 1
  never reads it; stage 2's anchor is unimplementable without it (§6.1 item 4),
  and widening that ring after stage 1 ships means reopening validated
  read-path code — the one part of the floppy stack that is hardware-proven.
- **Stage-2 carve-out — do it now:** keep the committer format-neutral, taking
  the Phase 2 tuple from *either* decoder. A GCR-shaped committer is rework.

**Gate (hardware):** with a scratch disk enabled, save a file from the Finder;
it reads back correctly and survives an eject/reinsert within the session. Reset
the core — the change must be **gone**.

★ Build the handshake BEFORE anything can commit (§2.1): a wrong handshake hangs
the machine, so this phase's first hardware run is also the hang test.

### Phase 4 — Persistence to SD
Port `rtl/floppy_sd_writer.v`. Add the DC42 offset (§6.2). Gate `sd_wr` with a
`write_ok` backstop as well as the decoder's own condition — belt and braces,
per `../UK101_MiSTer/UK101.sv:304`.

**Status 2026-09-16:** code complete for raw AND DC42 (`9195c0a` + the review
fixes described in §6.2). Raw images HARDWARE-GATED, both halves. DC42 not yet
fitted. `verilator/tb_floppy_sd_writer.v` covers the byte order, the queue, the
ack-timeout re-presentation, the DC42 RMW and checksum rewrite, the partial-
tail refusal, and (sections 10-14) the remount abort and the flush trigger.
The writer exports a 32-bit witness word (`PFSW` in the observer deck): the
DC42 hardware gate should include a sustained large-file copy and read back a
ZERO overflow count, since four SD transactions per sector against the ~10 ms
sector cadence is the one capacity assumption nothing offline can test.

**Gate (hardware + host):** write, eject, remount → the change persists. Then
verify on the PC: the image opens in an emulator, and a byte-level diff against
the pre-write copy shows *only* the intended sectors changed. **The diff is the
important half** — it catches a wrong-LBA bug that "it still boots" would miss.
UK101's attempt-2 post-mortem is what a byte-diff buys you: it located a
263-byte displacement and reconstructed the cause from it.

### Phase 4b — Persistence, second design: SDRAM-sourced, unbounded backlog

**Why (2026-09-16).** The card-sourced writer's 450 KB soak FAILED: the
depth-2 shadow queue overflowed twice and four sectors of the copied
application were wrong on the card while the volume still checked out (§6.2,
review finding). Root cause is the environment, not the RTL: Main opens a
writable image `O_RDWR|O_SYNC`, so each block is a synchronous card write with
bursty latency, against a sector every ~11 ms. Any fixed-depth copy of the
data will overflow on a long enough stall, and it does so silently. **Owner
chose option B**: keep no second copy of the data at all.

**Fallback.** `floppy-write` stays at `ce07e67` (tag `phase4-card-sourced`,
RBF `scratch/phase4/MacLC_ce07e672_phase4dc42.rbf`). This work is on branch
`floppy-write-sdram-src`.

**Design.**
1. **Queue sector NUMBERS, not data.** On `commit_done && write_ok` the
   writer pushes the sector index (`commit_addr[21:9]`) into a FIFO (1024
   deep x 13 bits, 2 M10K). The committer has already landed the data in
   SDRAM, which always holds the NEWEST version, so a sector re-written while
   still queued is simply queued twice and written twice with the latest
   contents — no dedupe, no bitmap, no re-dirty tracking. 1024 pending
   sectors is ~11 s of write backlog; if even that fills, the push is REFUSED
   and a sticky `lost` flag is raised (option C's safety net — visible, never
   corrupting).
2. **Fetch from SDRAM at write time** into ONE 256x16 block buffer, then
   present it to hps_io as before (same output byte swap). Raw: block N =
   sector N. DC42: block N = payload words `N*256-42 .. N*256+213`, i.e. the
   tail of sector N-1 and the head of sector N, both straight from SDRAM; the
   card is never READ any more, so a DC42 sector costs two writes, not two
   reads + two writes. **Block 0's first 42 words are the stripped header**,
   which SDRAM does not have: `floppy_loader.v` now keeps them (captured as
   file block 0 streams past at mount) and exports a small read port.
3. **SDRAM access = the existing Ethernet DMA port, shared.** `rtl/sdram.v`'s
   `eth_*` requester is a proven LEVEL two-phase read/write port that never
   touches `cpu_done`, starts only on idle edges, and is already crossed
   clk_sys -> clk_64 correctly. A small arbiter module (`rtl/eth_port_arb.v`)
   in MacLC.sv grants it per transaction to pds_enet or the floppy writer,
   pds_enet first, lock held from request-rise through ack-fall (a grant that
   flipped with `eth_ack` still high would hand the next client a spurious
   ack), and the muxed bundle is REGISTERED before it reaches the controller
   (pds_enet's own note: combinational depth on that crossing broke hold).
   **`rtl/sdram.v` is not edited.** Bandwidth: one word per idle
   clk_sys-aligned edge, ~0.2 us/word unloaded, so a block fetch is ~50-100 us
   against an 11 ms sector.
4. **Eject flush = SDRAM scan.** Drain the FIFO, then read the whole data
   section from SDRAM accumulating `ror32(sum + word)` (~0.1-0.2 s for
   800K), then write block 0 assembled from the loader's header words with
   36/37 substituted plus sector 0's head from SDRAM. The tag checksum is
   left as stored (tags are never written).
5. **Unchanged from 4:** `write_ok` as the single gate, `file_blocks`
   partial-tail refusal, remount ABORT (now also empties the FIFO), the
   `PFSW` witness word (overflow byte now counts FIFO refusals).

**Gate.** `tb_floppy_sd_writer.v` rewritten around an SDRAM model on the
eth-port protocol + the hps_io model (byte order, raw, DC42 assembly incl.
block 0, flush, refusals, remount abort, FIFO-full refusal, re-written-
while-queued ordering); `tb_eth_port_arb.v` for the arbiter (lock through
ack-fall, no cross-talk of acks); Quartus A&S; then on hardware the SAME 450
KB copy with `PFSW` overflow == 0 and a byte-for-byte fork diff against the
source volume — the test that failed 4.

★ **HARDWARE GATE PASS 2026-09-16 evening** — commit `60d1e95`, fit
`MacLC_60d1e95b_phase4b.rbf` (STA +0.157 ns). The same Speedometer 3.23
folder (450 KB, ~900 sectors) copied onto `Blank800K (DC42).dsk`, then
guest-ejected:
- `PFSW` after the copy `00001800`, after the eject `00001B10`: refusals 0,
  out-of-range 0, flushes 1, idle.
- Written image vs baseline: header words changed = {36, 37} only, data
  checksum stored == recomputed (2f6a8a58), tag checksum and tag section
  untouched, 901 payload sectors changed (MDB/bitmap, catalog, the two
  files) and nothing else.
- **Both forks byte-IDENTICAL to the source on `boot.vhd`**: Speedometer
  3.23 rsrc 409015 B, Machine Records rsrc 41203 B. `hfs_check` VOLUME
  CONSISTENT. The four wrong sectors the card-sourced design produced on
  this exact test are gone.
★ **RAW SOAK PASS, same evening.** The same folder onto the raw
`Blank800Kformatted.dsk` (baseline = the unwritten file): `PFSW` `0000A810`
= refusals 0, out-of-range 0, flushes unchanged at 1 (correct: a raw image
has no header to rewrite, so the eject triggers nothing), idle. 901 sectors
changed, every one inside MDB/bitmap, the catalog extent or a file extent
(a script check, not an eyeball); both forks byte-identical to `boot.vhd`;
`hfs_check` CONSISTENT, and the source image's off-by-one MDB file count was
corrected by the Finder as predicted.

Still to do before PR: the guest-side remount check of a DC42 write (trivial
now the file is right), and stage 2 (MFM/ISM writes).

### Phase 5 — Hardening
Port MacPlus's Phase 5 work and its six-defect review list (§7). Stress the
structures nothing exercises incidentally: commit-queue depth, write-to-one-
drive-while-mounting-the-other, and write-then-immediate-OSD-remount.

---

## 6. LC-specific hazards

### 6.1 Two formats — and MFM has no free sector number

An Apple GCR data field self-identifies (§4). **An IBM MFM data field does
not.** The ISM writes only the data field, after the ID field has already passed
under the head, so the write target must be derived from position.

**UK101 has already solved this exact class of problem**
(`../UK101_MiSTer/SAVE_AND_DISK_PLAN.md:411`, "three answers, and a byte-diff
that settled it"). Its conclusions transfer directly and should be treated as
the starting design for stage 2, not rediscovered:

1. **Do not write at the live rotational position** (attempt 1). `.65D` is a
   gap-free format, so a rotational write address stored the idle byte-times as
   real bytes — it wrote the physical inter-record gap that real media has and
   the file does not (22 bytes, ERR #2). *LC analogue:* our images are likewise
   sector images with no gaps. We are structurally safer because we commit
   **decoded data fields** rather than captured raw bytes — but the same trap
   returns the moment anyone proposes capturing the raw stream.
2. **Do not use a cumulative counter** (attempt 2). `read_ptr` was reset only by
   a seek while the DOS re-anchored to the index hole before every access, so it
   was an odometer, not a position. ★ Note the **severity inversion** recorded
   there: attempt 1 failed *safely* (consistent misplacement, caught by the
   DOS's own verify); attempt 2 failed *catastrophically* (arbitrary
   misplacement, straight through to the media, destroying an unrelated sector
   header). A more plausible-sounding fix produced a far more destructive bug.
3. **Anchor to the last byte actually DELIVERED to the guest** (attempt 3):
   set the write pointer to one past the head on every delivered byte, +1 per
   accepted write, 0 on seek/mount. *LC analogue:* the anchor is **the ID field
   most recently delivered to the guest** — which is what the driver itself used
   to decide to write. `rtl/mfm_track_encoder.v` knows exactly which sector it
   is emitting, so latch that at the delivery strobe.
4. **Anchor to the byte RECEIVED, not the live head** (hardening, `08d6fc5`).
   UK101's `rx_latch` is filled at `rot_div == 4` of a byte-time, so a poll
   landing past the boundary receives byte P−1 while the live head already says
   P — a one-byte shift, fatal to the verify-reread and intermittent. Fixed by
   capturing the position alongside the byte in the same cycle. *LC analogue is
   direct and worse:* `floppy.v` delivers through `mfm_byte`/`mfm_mark`/
   `mfm_stb` into `swim.v`'s **16-deep staging ring**, so the delivered byte and
   the encoder's live position are separated by more than one byte-time by
   design. Capture the sector identity **into the ring alongside the byte**.
5. **Reset on seek/mount makes FORMAT correct for free** — now load-bearing
   rather than a curiosity, since formatting is in scope (§1).

★ Method note carried over: UK101's replay simulator could not see defect 4
either way, because its reads are atomic. That one came from reading the RTL
against the hardware model. A byte-exact replay and an RTL read catch different
classes of fault; stage 2 needs both.

### 6.2 Block-device conversion is messier here than on MacPlus

- **DC42 is detected mid-download-stream and its 84-byte header is NOT
  sector-aligned** (`MacLC.sv:2529` subtracts 42 words). **DECIDED 2026-09-14,
  owner's call:**
  1. **Load normalises.** The 84-byte header is stripped while streaming, so
     SDRAM holds pure sector data and guest sector N is at SDRAM offset N*512.
     Everything downstream of SDRAM is then format-agnostic. This is right under
     either write policy, so it is not a decision the write side can regret.
  2. ~~**Stage-1 writes are RAW IMAGES ONLY**~~ **REVERSED 2026-09-15 — DC42 IS
     WRITABLE.** Owner's ruling, taken live and unambiguously: every format we
     can read, we can write. Dani's question on the forum was exactly "which
     file formats will you support writing", and the answer given is "all
     currently supported formats" — so this is now a commitment, not a
     preference.

     ⚠ **Provenance note, because it matters for how much weight the old
     decision carried.** §6.2 and commit `4007848` both recorded the raw-only
     choice as "owner's call, 2026-09-14". On 2026-09-15 the owner said he had
     no memory of discussing it. It cannot be verified either way from here —
     both records are a previous session's own claim. **Lesson: do not write
     "owner's call" into a doc or a commit message unless the owner actually
     said it in that session.** An unverifiable attribution is worse than none,
     because it silently converts a proposal into a settled decision that
     nobody feels able to revisit.

  3. **What DC42 writes actually cost.** The load-normalises decision (item 1)
     does most of the work for free: SDRAM holds pure sector data, so guest
     sector N is at SDRAM offset N*512 **whatever the container was**.
     Therefore:
     - **Phases 3a/3b need NOTHING.** Volatile (SDRAM-only) writes are already
       container-agnostic. DC42 works there the moment the write-protect term
       is dropped.
     - **Only Phase 4 — the SD write-back — is affected.**

     And the misalignment is far more tractable than "84 is not a multiple of
     512" suggests, because the offset is CONSTANT. Guest sector N sits at file
     byte `84 + N*512`; dividing by 512 gives block N with a remainder of
     exactly 84, for every N. So a DC42 sector write is always:
     - bytes 84..511 of **block N** (428 bytes), and
     - bytes 0..83 of **block N+1** (84 bytes).

     One fixed 428/84 split, never a variable one. The RMW is a known shape, not
     a general case.

  4. **The real work is the partial-failure window, and the header checksums.**
     - *Partial failure*: block N lands and block N+1 does not, leaving a sector
       torn across two blocks. It reads back self-consistently, which is the
       dangerous kind. Needs the same never-retire/re-present discipline §7
       item 2 demands of the SD writer.
     - ★ **The DC42 header carries data and tag checksums, and they cannot be
       updated incrementally.** The algorithm is `sum = ror32(sum + word)` over
       the whole payload — every word's contribution depends on its position, so
       changing one sector invalidates the running sum from there on.
       `scripts/mk_dc42.py` implements it and was verified against four
       known-good images. Three options, to be decided before Phase 4:
       (a) leave the checksums stale — most emulators never check them, but
           `mk_dc42.py`'s own verifier and real DiskCopy would flag the image;
       (b) recompute on eject/unmount by re-reading the payload (819200 bytes
           for an 800K image — cheap, and it happens once per session);
       (c) zero the fields.

  ★ **DECIDED 2026-09-16 — option (b): in-container read-modify-write, with
     the header's DATA checksum recomputed on the guest's eject.** Owner's
     choice, taken in that session. Implemented in `rtl/floppy_sd_writer.v`
     (commit `9195c0a`, reviewed and corrected the same day — see below).

     **The neighbour bytes come from the CARD, not from SDRAM.** An earlier
     draft of this paragraph argued the opposite (SDRAM holds the whole
     normalised payload, so assemble each block locally); the code does not
     do that, and the reasons are the writer's LC addition 2:
     - sourcing from SDRAM would make the writer a FIFTH requester on
       `rtl/sdram.v`, the most invariant-laden file in the core (§6.3), for
       the sake of one extra SD read per block against a sector rate of one
       per ~10 ms;
     - the card is the more CORRECT source. If the user turns Floppy Write
       off and later on again, SDRAM has moved on but the file has not;
       reading the neighbour bytes back from the very block about to be
       rewritten means each write changes only the sector it was for, and
       never smuggles in sectors the user chose not to persist.
     So each DC42 sector is four SD transactions: read N, write N patched,
     read N+1, write N+1 patched. The read side reuses `sd_rd`/`sd_buff_wr`
     exactly as `floppy_loader.v` does, and the slot's `sd_lba`/`sd_rd`/
     `sd_wr` are muxed between loader and writer in `MacLC.sv`.

     **The checksum is recomputed by re-reading the file from the card** on
     the guest's eject (the only moment the file is still mounted and the
     guest has finished with it): pass 1 scans blocks 0..last-data-block
     accumulating `sum = ror32(sum + word)` over the data section, pass 2
     re-reads block 0 and writes it back with words 36/37 substituted. The
     TAG checksum is left as read — the tag section is never written, so it
     is still right. ~1600 reads for an 800K image, once per session.

     **Documented limits:** the file's final PARTIAL block is refused (hps_io
     writes whole blocks; a tagless DC42 therefore never persists the 84-byte
     tail of its last sector — and, symmetrically, the loader never LOADS it,
     an older gap now documented in both modules); an OSD-first unmount skips
     the checksum rewrite, leaving a stale checksum over correct data.

     ★ **REVIEW FINDING, 2026-09-16 — the ported remount interlock was a
     corruption path here, fixed before any fit.** MacPlus's writer clears
     the queue on `img_mounted` but leaves the FSM running, which is safe when
     a sector is ONE request. Here a sector is four and the flush ~1600, and
     the later steps are issued from states that never consult `valid`.
     `sd_ack` is per SLOT, so once the loader starts streaming the new image
     its acks walk the writer's FSM forward until it raises `sd_wr` against
     the loader's LBA — the old sector, or the old header block with a
     garbage checksum, written into the NEW image. Reproduced in Icarus in
     both forms (mid-RMW and mid-scan) and pinned by bench sections 10-11.
     Fix: the mount pulse now ABORTS the FSM (safe because Main is single-
     threaded and finishes any captured transfer before it can send a mount),
     and `MacLC.sv` masks the slot's `sd_wr` while the loader owns it. Two
     smaller trigger defects fixed alongside: the flush was gated on the
     toggle's CURRENT state (write, switch off, eject → stale checksum) and on
     `dirty`, which is set when a block lands, not when a sector is queued
     (eject racing the session's only write → no flush). Sections 12-14.
     ⚠ **Lesson for stage 2 and for the MacPlus port-back (§10):** an
     interlock inherited from a one-request design must be re-derived for a
     multi-request one. "Theirs unchanged" is a claim about the text, not
     about the invariant.

     ★ Why NOT (d), normalise-the-file, on reflection: it needs a forked Main
     for truncate, which would be a SECOND Main dependency after ethernet — a
     stock-Main user would silently get no DC42 write — and it rewrites the
     user's archived DiskCopy file into a raw image, which is a surprising
     thing to do to it.

  5. ★ **HOW is explicitly NOT DECIDED (owner, 2026-09-15).** Only *that* DC42
     becomes writable is settled. Everything in items 3-4 is the cost of ONE
     approach — writing back in place, in the container — and a different
     approach may not pay it at all. The owner's own suggestion:

     - **(d) Normalise the FILE on first write: strip the header and leave a
       plain raw image.** Sector N then lands at N*512, so there is no RMW, no
       torn-write window, and no checksum problem — all of items 3-4 evaporate.
       The load path already normalises into SDRAM (item 1), so the core
       already holds exactly the bytes such a file needs.
       Open question that decides its feasibility: **the file has to get 84
       bytes shorter** (19284 for an 800K image with tags), and `hps_io`'s block
       interface writes blocks — it has no truncate, and no create. So this
       likely needs Main-side support, which is a different kind of cost, not a
       smaller one. Check before choosing it. A variant that avoids truncation —
       rewriting in place and leaving a stale tail — makes the file's size stop
       matching its content, which is its own trap given how much of this core's
       geometry logic keys off size.

     Decide between (a)-(d) at the start of Phase 4, not before: Phase 4 is the
     first phase that touches the user's file, and by then the write path will
     have been proven on hardware.
     - *Tags*: the guest's GCR stream carries the 12 tag bytes per sector and the
       decoder currently drops them. A DC42 with a tag section has somewhere to
       put them. Writing them is optional; NOT writing them leaves the tag
       section stale, which is another reason (b) above must recompute the tag
       checksum too, or leave both stale consistently.

  ★ Consequence for Phase 3: `flp_int_wp` in `MacLC.sv` currently reads
  `~status[14] || flp_int_ro || !flp_int_raw`. **The `!flp_int_raw` term comes
  out** — it is the reversed decision, and it is the only code implementing it.
  Left alone until the in-flight Phase 3a fit finishes (no edits during a
  build); it lands with Phase 3b. `raw_img` stays plumbed, because Phase 4 needs
  to know which layout to write.
- **The media-change machinery is all keyed off download start/end** —
  `DSK_EMPTY_CY` (`MacLC.sv:2434`), CSTIN, `disk_switched`, and the `.dsk`/
  `.img` index-nibble compare — and must be re-derived from
  `img_mounted`/`img_size`. That machinery is hardware-validated and was
  expensive to get right (the 2026-08-06 System 6.0.8 install gate). Treat any
  change to it as a regression risk in its own right and re-run
  `verilator/tb_disk_swap.v`.

### 6.3 SDRAM plumbing is EASIER here — use the right pattern

MacPlus lost two hardware gates to `sdram.v`'s two-phase RAS/CAS sampling: a
combinational or pulsed handshake tore down after RAS committed but before CAS
latched column and data (once on the address mux, once on the data mux — where
drive 1 "worked" only by being the ternary's default branch).

This core already has the correct pattern in two proven requesters: the download
port (`rtl/sdram.v:106`) and the ethernet DMA (`rtl/sdram.v:129`), both
documented as LEVEL, not pulse. **Copy one of those. Do not build a new
extra-slot requester** — and note that the floppy read window and the download
slot are already the SAME slot (`flp_ok = !dio_download && flp_present`,
`rtl/addrController_top.v:357`), a hazard that has bitten this core before.

### 6.4 The failure mode is harsher

See §2.1. On MacPlus a bad handshake meant a failed write; here it hangs the
machine. Hence: handshake first, OSD write-enable defaulting Off, and test only
against copies of images.

---

## 7. Inherited defects to pre-empt (MacPlus Phase 5 review)

All six were real, found in one review pass, and every one is a class this port
can reproduce:

1. **Async reset assigned a live signal** → latch inside a combinational loop,
   untimed, feeding the decoder's reset. A glitch abandons a field in progress
   and the write path signals no error, so the guest believes a sector landed
   that never did. *Diff the Quartus warning count against the previous compile
   every time* — this one sat in the log as 57 → 65 and was never examined.
2. **SD-writer ack timeout retired the queue entry.** `hps_io` captures `sd_lba`
   in one command and raises `sd_ack` in a later one, gap unbounded from the
   core's side. Re-present, never retire; retries must be idempotent.
3. **Writes accepted during an image reload.** CSTIN still reads "disk present"
   across a swap, so a field completing then commits the departing disk's sector
   into the newly mounted image — in SDRAM and then into the file.
4. **Bounds check and the address it protects evaluated a field apart.**
   Validate-and-commit must be atomic in one state.
5. **No LBA bounds check against the mounted image size.**
6. **One wire used as an async reset in one module and a sync reset in the
   next.**

Plus the testbench hazard that appeared four separate times: driving `ready = 0`
at zero delay after `@(posedge clk)` lets simulator process ordering decide what
the DUT sees. Use the `#1` discipline throughout, and pulse `ready` SPARSELY — a
continuously-asserted `ready` starves the encoder's address settle time and
silently produces a self-consistent but wrong byte stream.

---

## 8. Stage 2 — MFM/ISM writes

Design starting point is §6.1, from UK101. **The anchoring design question is
answered.** What remains is implementation against this core's structures, plus
two pieces UK101 never had to build:

- an **MFM decoder**, the algebraic inverse of `rtl/mfm_track_encoder.v` — a
  second decoder, not a parameterisation of the GCR one. ★ 2026-09-15: this is
  a BYTE-stream parser plus CRC-16-CCITT, not a flux decoder — see §1, which
  also brings MFM formatting into scope and re-rates this work downward;
- an **ISM write engine, which does not exist at all today**: `rtl/swim.v:376`
  gates `ism_arm` with WRITE explicitly off, so Mode b4 is a no-op (§2.4).

Plus the ISM's inverted write handshake, still to be ground-truthed against
MAME (below). If the Phase 3 carve-outs (§1) landed, the ring already carries
sector identity and the committer already accepts the tuple, so stage 2 is
decoder + engine + handshake rather than a re-plumb.

**Other MiSTer cores with IBM 1.44MB write do not help.** Surveyed 2026-09-07.
`u765.sv` (Amstrad CPC, ZX +3, ao486) and `fdc1772.v` (Atari ST, BBC — a copy is
local at `../BBCMicro_MiSTer/rtl/fdc1772/`) are **controller** models: the guest
issues WRITE SECTOR with C/H/R/N as explicit command parameters and the model
writes to a sector image. `fdc1772.v:1028` is literally `sector <= cpu_din`, and
`sd_lba` is arithmetic on track/side/sector (`:108`). Neither ever decodes an MFM
bitstream.

The SWIM ISM is not a controller in that sense — bytes go wherever the head is,
and nobody tells the hardware which sector that is. The one hard problem is
precisely the problem those cores never have to solve, so their code cannot
donate an answer. UK101's can, because UK101's drive is dumb in the same way.

What *would* transfer from them (CRC-CCITT, gap/sync/address-mark layout) we
already own in `rtl/mfm_track_encoder.v`, MAME-grounded and validated against a
real capture. The decoder wants to be the algebraic inverse of OUR encoder
anyway — the method that worked on MacPlus. Lifting GPL RTL would also set the
licence of the combined work, for no gain.

**The remaining prior art is MAME's `swim1.cpp`/`swim2.cpp`** for the ISM's
write-mode semantics (what Mode b4 does to the engine, how the handshake
inverts, where the write splice falls) — already this project's ground truth via
`docs/swim_ism_read_reference.md` and the `verilator/mame/` toolchain.

---

## 9. Effort

| Stage | Estimate |
|---|---|
| Stage 1 — GCR write (phases 0–5) | ~3 weeks |
| Stage 2 — MFM/ISM write | +1–3 weeks |
| Formatting, GCR | +2–4 days — port of `7712c0e`'s floppy half (§1.1) |
| Formatting, MFM | +3–5 days — decoder extension + ISM format sequencing |
| DC42 write-back (Phase 4) | +2–3 days — the fixed 428/84 two-block RMW, the torn-write guard, and a checksum policy (§6.2 item 4). Added 2026-09-15 when DC42 writes came into scope. |

★ The release gate (§1) means the deliverable is the SUM of those rows, not the
first of them. Formatting entered the table on 2026-09-15; it was previously
listed as out of scope, on a false reading of MacPlus (§1).

Stage 1 is below MacPlus's 3–4 weeks because the decoder, committer and
SD-writer port over and the validation matrix is smaller (§3); it is not lower
still because Phase 1's media-change rework (§6.2) is new work MacPlus never had
to do. Stage 2's range narrowed once UK101's anchoring work was found, but only
the design question closed: the MFM decoder, the absent ISM write engine and the
handshake are all still ahead (§8). The **bottom** of that range assumes the
Phase 3 carve-outs (§1) landed; without them, add the read-path rework back.

---

## 10. Worth porting BACK to MacPlus

Noted while scoping; owner asked.

- **DiskCopy 4.2 support** — MacPlus has **no DC42 handling at all**: the only
  mention in its tree is `readme.md:34` telling users to convert externally,
  with a link to a converter and `releases/bin2dsk.sh` shipped for the purpose.
  This core reads DC42 natively (`MacLC.sv:2529`, and from Phase 1 in
  `rtl/floppy_loader.v`).

  Transfers essentially unchanged, being file-format logic rather than machine
  logic: detection on the RAW delivered word (name length `d[7:0]` at word 0 in
  1..63; magic `d == 16'h0001` at word 41 — NOT the byte-swapped word, see the
  2026-09-14 bug), the reason raw images cannot false-trigger (byte 0 of a
  bootable HFS floppy is `'L'` = 76 > 63, or `$00` blank), the 42-word strip,
  and the format byte at word 40 as the geometry discriminator — **with its
  reason: tags trail the sector data, so payload size lies** (an 800K DC42 is
  838400 payload bytes, not 819200, and matches no size test).

  Does NOT transfer: our SDRAM download-port choice (MacPlus drains via the
  extra slot), the 13-bit `sd_buff_addr` (theirs is 8-bit), and DC42 formats
  2/3 — a Plus is 400K/800K GCR only, so only formats 0 and 1 are meaningful.

  ★ **SAFETY: on MacPlus the DC42 read support and the "DC42 presents
  write-protected" gate MUST land in the SAME commit.** Here the two are
  comfortably sequential because no write path exists yet. MacPlus already
  SHIPS floppy writes, so DC42 detection landing alone means the first write to
  a mounted DC42 image is placed 84 bytes off — corrupting the user's file, and
  doing it silently, because a read back through the same wrong offset looks
  self-consistent. Port `raw_img` (or an equivalent) at the same time.
- **The MAME comparison toolchain** — MacPlus has none.
- **The MAME-grounded `SWITCHED` semantics**, implemented and hardware-validated
  here, which answer the exact open risk MacPlus's own Phase 5 flagged as
  untested.
