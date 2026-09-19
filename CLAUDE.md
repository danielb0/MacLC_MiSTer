# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Macintosh LC emulation core for the MiSTer FPGA platform. It's based on the MacPlus core by Sorgelig, which originated from the Plus Too project. The core emulates the Motorola 68000 CPU and various Macintosh peripherals.

## Build Commands

**See [BUILD.md](BUILD.md) for the full scripted CLI build/deploy flow** (setup,
`scripts/build_only.sh` modes, status output, running multiple builds on one host,
and porting the toolchain to other cores).

### FPGA Build (Quartus)
The project uses Intel Quartus 17.0.2 Lite Edition.

**GUI:**
- Open `MacLC.qpf` in Quartus
- Compile to generate RBF output in `output_files/`
- Deploy RBF to MiSTer SD card root

**CLI (see [BUILD.md](BUILD.md)):**
```bash
bash scripts/setup_env.sh     # first time: create scripts/local.env, then set QUARTUS_BIN
bash scripts/build_only.sh    # full compile -> output_files/MacLC.rbf + status summary
bash scripts/deploy_screenshot.sh   # optional: push + launch on the MiSTer
```

### Verilator Simulation
```bash
cd verilator
make        # Build simulator
make clean  # Clean build artifacts
./obj_dir/Vemu  # Run interactive simulator (requires SDL2, OpenGL)
```

#### Simulator Command Line Options
```bash
./obj_dir/Vemu --help                    # Show all options
./obj_dir/Vemu --screenshot 360          # Take screenshot at frame 360
./obj_dir/Vemu --stop-at-frame 400       # Exit after frame 400
./obj_dir/Vemu --screenshot 360 --stop-at-frame 361  # screenshot
```

Key options:
- `--screenshot <frame>` - Save PNG screenshot at specified frame number
- `--stop-at-frame <frame>` - Exit simulation after reaching frame count
- `--trace` - Enable FST waveform tracing (outputs to `trace.fst`)

Note: Boot takes approximately 360 frames to reach the Mac desktop.
Note: No hard drive is configured in the simulator, so the desktop won't fully load.

#### Boot Verification
```bash
cd verilator
./check_boot.sh              # Analyze existing cpu_trace.log
./check_boot.sh --run        # Run 30 frames + analyze
./check_boot.sh --run 100    # Run N frames + analyze
```
Exit codes: 0=PASS, 1=FAIL, 2=missing log. Suitable for pre-commit hooks.

#### Simulation Logs
- **CPU trace log:** `verilator/cpu_trace.log` - Contains 68K CPU instruction trace
- **Console output (stderr):** Contains HC05 (Egret) traces, VIA/peripheral debug messages
- **Important:** Do NOT re-run the simulator multiple times when diagnosing. Run once, then analyze the log files.

#### Comparing against MAME (ground truth)
When the core misbehaves, diff it against MAME's `maclc` running the same ROM.
Tooling: `verilator/mame/` (`run_mame.sh`, `tap.lua`, `snap.lua`, `trace.dbg`).
Full process + gotchas: **`docs/mame_compare.md`** (memory tap, maincpu trace,
PC-stream divergence diff; macOS has no `timeout`, debugger defaults to the Egret
HC05 not the 68020, MAME PCs are 8-digit `00Axxxxx`, etc.).

## The Verilator boot gate is NOT a routine gate (our policy, 2026-09-15)

★ **Fork-local policy.** This lives in `danielb0/MacLC_MiSTer` and is ours to
set; it must NOT travel upstream in a PR — see the PR section below.

**Do not run the 450-frame boot gate as a matter of course.** It costs ~35
minutes (build + ~4.7 s/frame) and the evidence does not justify that on every
change: across this repo's whole history it is reported as PASS **16 times and
has never once caught a regression** — the only commit mentioning it in that
context says *"The sim never caught it."* None of the MacPlus floppy-write,
SCSI, CD-ROM, HD20 or formatting work used it at all; that core was developed
against hardware with JTAG probes.

**What to do instead**, in order:
1. **The fast unit benches** (Icarus, seconds to a couple of minutes) — these DO
   catch things, and byte-exactly. `tb_floppy_commit`, `tb_floppy_write`,
   `tb_floppy_track_decoder`, `tb_disk_swap`, `tb_pds_enet`, `tb_scc_midi`, …
2. **Quartus analysis & synthesis** as the elaboration check. It is on the path
   to an RBF anyway, reaches the same conclusion in its first few minutes, and
   catches strictly MORE than Verilator — notably Error 10028, multiple constant
   drivers, which Verilator tolerates silently (see the compatibility section).
3. **Hardware, then JTAG probes** for anything that actually breaks. The chain
   is live; an empty probe read means a probes-off release fit, not a dead hub.

**When the boot gate IS still worth its 35 minutes:**
- After ANY change to the **VIA shift register** (`rtl/via6522.sv`) — the
  Egret section below mandates it, and that failure mode is a silent boot stall
  rather than something a probe finds quickly.
- When something has already broken and a **CPU instruction trace** would
  localise it: `check_boot.sh` names the boot stage reached and says whether the
  CPU is ADVANCING or spinning, which no screenshot can tell you.
- Once before a release fit, as a cheap sanity check on the final binary.

★ Note what it never covered anyway: `sim.v` hardwires `writeProtect(2'b11)`, so
the floppy WRITE path is inert there, and `sim.v` is its own top — it does not
include `MacLC.sv`. A boot-gate PASS means "the existing machine still boots in
sim", never "the feature works".

## PRs and releases — WE are the reviewers

**Treat "merged" as "shipped".** danifunker can cut releases that feed
update_all, so merged dev code reaches end users with no further gate. This is
NOT the MacPlus/Sorgelig model (an external reviewer is the bar); it is the
UK101 model, where the repo owner publishes directly.

House style, the reviewer's pre-merge checklist, and the consequences (no
half-finished OSD rows; staged plans are a MERGE discipline, not just a release
one; `USE_DBG_*` macros commented) live in **[docs/pr_guidelines.md](docs/pr_guidelines.md)**.
Read it before opening or merging a PR.

## Framework Files Are OFF-LIMITS (`sys/`)

**NEVER modify files under `sys/` (the MiSTer framework: sys_top.v, ascal.vhd,
osd.v, hps_io, pll_hdmi, .sdc files, etc.).** The only permitted change is a
wholesale update of framework files taken directly from the upstream MiSTer
template repo. If a fit, timing, or resource problem traces into the framework,
reconcile it from OUR side — `rtl/`, `MacLC.sv`, `MacLC.qsf`, `MacLC.sdc` —
never by patching the framework in place.

Why (learned 2026-07-17): a night of framework edits (RAM attributes in
ascal.vhd/osd.v, a PALETTE generic in sys_top.v) produced STA-met builds with
dead video and confounded every hardware A/B for hours. Framework internals
(scaler pipeline, clock-domain handoffs) have invariants that are not visible
from this repo; local edits there create failure modes that pass STA and only
show up on hardware.

## Architecture

### Top-Level Module
- `MacLC.sv` - Main system module (module name: `emu`)
- Entry point for the MiSTer framework via `sys/sys_top.v`

### RTL Structure (`/rtl`)

**CPU Core:**
- `tg68k/` - TG68K CPU core (68000)

**Memory & Storage:**
- `sdram.v` - SDRAM controller
- `scsi.v`, `ncr5380.sv` - SCSI hard drive interface
- `floppy.v`, `floppy_track_encoder.v` - Floppy drive emulation

**I/O Peripherals:**
- `via6522.sv` - Versatile Interface Adapter (parallel I/O, timers)
- `pseudovia.sv` - VIA emulation for LC models
- `swim.v` - SWIM floppy controller (IWM + ISM personalities)
- `scc.v` - Serial Communication Controller
- `adb.sv` - Apple Desktop Bus
- `ps2_kbd.sv`, `ps2_mouse.v` - Keyboard/mouse input
- `egret/` - Egret system controller (68HC05 + 341S0851 firmware): ADB, RTC, PRAM
- `uart/` - UART TX/RX modules

**Video Subsystem:**
- `maclc_v8_video.sv` - Mac LC Video Engine (V8)
- `ariel_ramdac.sv` - Video DAC
- `addrController_top.v`, `addrDecoder.v` - Address generation
- `dataController_top.sv` - Data control

### System Framework (`/sys`)
Standard MiSTer framework files (video scaling, HPS I/O, audio output). Generally should not need modification for core-specific work.

## Key Technical Details

- **Target FPGA:** Cyclone V (MiSTer DE10-Nano)
- **System clock:** Generated via `rtl/pll.v`
- **Memory:** 1MB/4MB RAM configurations, DDR3 SDRAM interface
- **Video modes:** 1/2/4/8/16 bpp
- **CPU clock:** **fixed 16.25 MHz** 68020 — `clk_sys` is 32.5 MHz
  (`rtl/pll.v` outclk_1) and `clk16_en_p/n` alternate every cycle
  (`rtl/addrController_top.v:115`), so a phi1/phi2 pair is 2 clk_sys cycles.
  **There is no speed selector**: `status_cpu` is a `localparam` (`MacLC.sv:170`)
  and the CONF_STR has no speed row. The 8.125 MHz `clk8_en_p/n` off the same
  divider is the **peripheral** bus enable, not an alternate CPU speed — that
  is most likely where the old "8 MHz or 16 MHz" line came from.
- **TG68 kernel combinational loop: GONE as of 2026-09-15** (branch
  `tg68-break-comb-loop`; full write-up `docs/tg68_comb_loop_plan.md`). It was
  `setexecOPC -> datatype` (the MULU/MULS execute-phase "long" override, the
  only `setexecOPC`-guarded `datatype` write) `-> EA-build (An) test ->
  setstate -> setexecOPC`, introduced by the 2026-06-02 cmp.l (An) fix
  (42ae7a6, danifunker) — not inherited from TG68K. The override now targets
  `set_datatype`. **LAW: never assign `datatype` under a `setexecOPC` guard in
  the decode process.** Gates for any kernel edit: no 332081/332125 in
  `MacLC.fit.rpt`/`.sta.rpt` (the map report's "logic cells representing
  combinational loops" is NOT a gate — it went 17 -> 16, it counts something
  else), `verilator/tb_mul_modes.v` old-vs-new bus-log diff (build cmd in its
  header), and the 400-frame boot CPU-trace diff. `report_loops` is not a
  TimeQuest command in 17.0; the loop node list, when one exists, is printed
  under Warning 332125 in the STA report. **Phase B (same day): the kernel's
  genuine two-period SDC credit is RESTORED** (`set_multicycle_path -setup
  -end 2` kernel-internal), passed 3/3 on hardware at seeds 4/5/7 — the seed
  roulette is over (kernel worst 29.7–32.1 ns vs 61.5 ns). The 32 ns cap line
  stays commented in `MacLC.sdc` as the one-line revert. Do not re-cap
  "because the kernel is tight": it is not, any more.

## File Locations

- `files.qip` - Lists all RTL source files for Quartus
- `MacLC.qsf` - Quartus project settings
- `releases/` - Pre-built RBF files and ROM images. Only release-quality and
  provenance artifacts belong here (dated `MacLC_YYYYMMDD.rbf` releases and the
  hash-named build they were copied from) — probe/A-B/experiment RBFs do not.
- `scratch/` - **(gitignored) ALL session scratch goes here**: screenshots,
  build/launch logs, probe RBFs, captures, analysis dumps. Never leave scratch
  work in the repo root and never commit it.
  **Retention rule (2026-09-15):** when an experiment's result is written up,
  it keeps its reports and `RESULT*.md`, and only those RBFs that were
  hardware-gated or are cited by a doc or memory - normally one. Every other
  RBF from the experiment (STA-rejected seeds, superseded variants, probe
  fits) is deleted then, not later. Never archive a build tree
  (`db/`, `incremental_db/`, `output_files/`) under `scratch/`; release RBFs
  are in git history (`git show <commit>:releases/<file>`), so never keep
  copies of those either. Loose probe dumps in the scratch root go when the
  experiment closes. (Context: 32 RBFs / 520 MB accumulated over one week of
  timing work, most from experiments already refuted.)

## CPU Conversion Notes

When working with CPU cores, see `how-to-convert-cpu.txt` for GHDL-based VHDL to Verilog conversion process using:
```bash
ghdl synth -fsynopsys -fexplicit --latches --out=verilog
```

## Verilator vs Quartus Compatibility

**Critical:** Verilator allows multiple `always` blocks to drive the same `reg`, but Quartus does not (Error 10028: "Can't resolve multiple constant drivers"). When writing or modifying RTL:

- Each `reg` must be driven from exactly **one** `always` block for Quartus synthesis
- If timer logic, PRAM loading, or other hardware needs to write the same register as a CPU write path, **merge them into a single `always` block**
- Use `if/else if` priority within the block to handle the different write sources
- Verilator builds (`make` in `verilator/`) will succeed even with multiple drivers — always verify the design is Quartus-clean before targeting FPGA

**Conditional compilation:** `SIMULATION` is defined in `verilator/Makefile`. Guard simulation-only code (`$display`, debug counters) with `` `ifdef SIMULATION ``. (`USE_EGRET_CPU` is gone — the real HC05 Egret is unconditional as of 2026-08-09; `EGRET_BEHAVIORAL` remains as an opt-in debug fallback.)

**Top-level split:** the Verilator top is `verilator/sim.v` (`module emu`), NOT `MacLC.sv`. It has its **own** CPU instantiation and bus glue (VPA/DTACK/BERR/overlay); peripheral RTL is shared via `dataController_top`. CPU-glue/top-level fixes must go in **both** files or sim and FPGA silently diverge. Tracked differences (and a maintenance checklist) live in **`docs/verilator_differences.md`** — update it when you add a top-level signal or hardwire a sim config.

## VIA Shift Register — Simulation Sensitivity

**Critical:** Changes to the VIA SR logic in `rtl/via6522.sv` can break Egret communication and stall the boot. After any SR change, verify simulation still boots:

```bash
cd verilator && make clean && make
./obj_dir/Vemu --screenshot 450 --stop-at-frame 451 2>/dev/null 1>/dev/null
```

Check `screenshot_frame_0450.png` — it must show the **50% dither grey desktop
with the arrow cursor top-left** (boot reached cursor-visible state). A uniform
flat grey at 450 means the boot stalled — Egret communication is the first
suspect. Corroborate with `bash check_boot.sh` (stages + ADVANCING).
(Re-calibrated 2026-08-05: the old criterion was the memory-test line pattern
at frame 350, timed against VIA timers that counted 2× slow — the via6522.sv
timer fix moved every timer-paced boot delay earlier, so the pattern now
passes before frame 180 and 350 lands in a featureless VRAM-fill phase.)

**SR edge-detection patterns (history + FPGA caveat):**
- `cb2_latched` (shift-in: capturing CB2 at the CB1 rising edge) — **removed; do not re-introduce.** Shift-in uses live `cb2_i`. Re-introducing it hung the 4th Egret SR transfer in Verilator (CPU stuck polling IFR bit 2 at `0xA14E5E`).
- `ext_fall_edge_pending` (shift-out: latching CB1 falling edges in external-clock mode) — **currently IN USE in `via6522.sv`.** It was reverted in `a8f9f33`, then deliberately re-added in `e067857` ("switching to fake egret"). It boots in Verilator only because the behavioral Egret drives CB1 slowly, so edges never coalesce. It is the **suspected cause of the FPGA overlay-stuck bug**: the real HC05 toggles CB1 far faster than the VIA's E-rate (only one pending edge is consumed per E-falling phase), so edges coalesce, SR bytes corrupt, the boot ROM's Egret handshake never completes, and the ROM overlay never clears. Do NOT assume it is FPGA-safe — prefer rate-limiting CB1 in `egret_wrapper` over re-touching this SR path.

Re-verify boot (the screenshot check above) after ANY SR change.

## Known Limitations

- **Floppies are WRITABLE as of 2026-09-19** — GCR 400K/800K and MFM
  720K/1.44MB, raw and DC42, including guest formatting (Mac 800K and 1.44MB,
  DOS 720K and 1.44MB, 400K MFS). Writes commit back to the user's file and
  survive eject, remount and a power cycle.
  ★ **The `OE` Floppy Write OSD option DEFAULTS TO OFF AND MUST STAY THAT
  WAY.** The ROM's write primitive polls the IWM handshake b7 in an UNBOUNDED
  loop, so the failure mode of a write bug is a HUNG MACHINE, not a failed
  write. That is the same fact the old "read-only" bullet here called
  load-bearing — it did not go away, it became the reason for the default.
  `flp_int_wp` gates further: an image mounted read-only from the SD card
  stays write-protected whatever the OSD says; a DC42 container does NOT
  (owner's ruling 2026-09-15, plan §6.2).
  **Floppies are BLOCK DEVICES now** — slot `S6`, loaded by
  `rtl/floppy_loader.v` at mount — not ioctl downloads, and that is what gives
  a write a path back to the user's file at all.
  **There is ONE drive.** The LC has no external floppy port, so the core was
  mounting the internal one twice (`410a064`); removing the phantom drops
  VDNUM to 7 and with it the forked-Main requirement — see the hps_io SLOT
  RULE above for why past slot 6 is hostile.
  Plan, gate matrix and hardware results: `docs/floppy_write_plan.md`.
- **BOOTING FROM FLOPPY WORKS** (user-confirmed on hardware 2026-08-05,
  bench build `78a46cf2`). The old "Welcome to Macintosh" retry loop and the
  ~39 KB-then-UNDERRUN freeze are gone. Several fixes contributed and no
  single one was isolated: the constant-300-RPM MFM tach (`62aee5c`, which
  targeted the Welcome loop directly), the ISM drive-select fix, the INDEX
  pulse, VIA1 PA7, and the VIA timer half-rate fix (`33ebdd1` — the driver's
  install-time drive-speed check is timer-paced, so a 2x timer error would
  also have corrupted it).
- **800K GCR disks WORK END-TO-END as of 2026-08-05** — mount, catalog, and
  **file reads**: on a cold boot a 482K application was launched off an 800K
  GCR floppy and copied to a SCSI disk with zero driver errors (head seeking,
  `step_cnt` 1 -> 311). Two fixes got here:
  1. `2804d02` — "This disk is unreadable" (`-69 badCksmErr`). The IWM
     read-data latch clear was retriggered from the LEVEL `iwmRead` instead of
     firing once at the END of the access: the LC's E-paced VPA accesses (~1.23
     us) plus the ROM's ~2.5 us GCR poll loop left less gap than the 13-cen
     reload, so the latch never cleared and the CPU re-read each disk byte ~6
     times — duplicates shift a field and break its checksum.
  2. **MEDIA CHANGES — FIXED AND HW-VALIDATED 2026-08-06** (`887ebba` +
     `dbb736e`; MISSION COMPLETE: a full System 6.0.8 install from its two
     1.44 MB floppies ran end to end — installer ejects, both OSD disk swaps,
     install onto a fresh SCSI vhd, installed system boots). The ghost-volume
     class ("mounts and lists but every call fails with NO driver error and
     zero disk I/O") was the guest never being told the medium changed. Three
     inseparable pieces, all MAME-runtime-grounded (tap_swapB/tap_qscreen):
     - **SWITCHED sense reg** (read reg 6 = MAME DiskChg = `!m_dskchg`):
       reset 0, SET on any media removal (fall of `insertDisk`), survives the
       next insert, cleared ONLY by the guest's DskchgClear strobe
       (`strobeCmd == 4'hC`). The Sony driver polls NoDiskInPl+DiskChg as a
       PAIR every ~0.8 s and strobes the clear itself — watched live on HW
       (HUD w7 `dskchg_clears` increments). Landing the CSTIN transition
       WITHOUT this register was the reverted-`ebbdac6` regression.
     - **CSTIN reports `~insertDisk`** + the MacLC.sv/sim.v empty-hold (drop
       media at download START, hold 2.06 s past the end).
     - **ISM eject re-enabled** under `(!ism_active || ism_sel)` — the MAME
       devsel-forwarding condition. The old blanket `!ism_active` gate made an
       MFM installer structurally unable to eject; the phases-walk phantom
       ejects it guarded against all run with Mode b7 CLEAR, so the qualifier
       blocks them and passes genuine ejects (installer ejects seen on HW).
     ALSO fixed en route (`dbb736e`): **Main packs the matched extension of a
     multi-extension F entry into the upper `ioctl_index` bits** (.dsk = 8'h01,
     .img = 8'h41); the flag latches compared the full byte, so every `.img`
     mount was a silent no-op (downloaded, never presented) since day one —
     compare `dio_index[5:0]` only. `verilator/tb_disk_swap.v` covers the full
     protocol (incl. walk-must-not-eject and the 8'h41-index mount) — run it
     after any `insertDisk`/`CSTIN`/eject edit. HUD row 7 = the media witness
     (`floppy.v` dbg_media; decode in `scripts/parse_hud.py`).
     ★ Swap-under-a-live-volume (no eject) is HOSTILE ON A REAL MAC TOO —
     MAME 6.0.8 bombs ("Disk Initialization package not present") when the
     boot floppy is yanked: drives only eject under software control, so the
     OS has no graceful path. The Mac-authentic flow is guest-eject-first
     (or the installer's own eject), THEN mount the next image.
     ★ OSD/bench lore from the validation (ops crib additions): the in-core
     OSD opens with the cursor ON "Mount Pri Floppy" after a FRESH CORE LOAD
     but remembers its row and browser position across opens within a
     session; the screenshot-filename oracle names the LAST file downloaded
     this core session — it proves a pick happened, NOT which slot took it.
  ★ `byte_cnt` frozen + `$142` all-benign means **no read was attempted** — do
  not read it as "reads returned bad data". (And `byte_cnt` alone is NOT proof
  of internal-drive reads — the GCR delivery counter also churns on garbage
  with no disk in; corroborate with w7 `insertDisk`/`CSTIN`.)
  The old 2026-07-07 floppy-controller park is RESOLVED (doc removed); its
  "SDRAM region != image" theory was never confirmed and its JTAG chain no
  longer works (dead hub). Offline instruments that settled all of this in
  minutes: `verilator/tb_gcr_read.v` (`+track/+side/+ncap`, seeks via the real
  drive-register protocol; **always pass `+acclen=40 +pollgap=40`** or the
  stream is garbage), `scripts/gcr_census.py` (address fields),
  `scripts/gcr_data_census.py` (DATA fields verified against the standard 800K
  layout offset — every zone boundary clean, refuting the `soff` suspicion) and
  `scripts/hfs_check.py` (walks an image's catalog/extents trees offline so a
  broken source image can't fake an RTL bug).
- **1.44 MB MFM read works, and the Finder whole-disk COPY was FIXED
  2026-08-05** (`33ebdd1`): the real defect was **`rtl/via6522.sv` counting
  T1/T2 at half rate** — a `/2` prescaler stacked on enables that were already
  at VIA phi2 rate (`E_div=1'b1`), so every guest VIA-timer interval ran 2.0×
  long since June. That doubled the Sony driver's Time-Manager sleep between
  read attempts and phase-locked its re-arm one sector late (stride-2 over 18
  sectors ⇒ a closed 9-sector cycle ⇒ `-81 sectNFErr`). HW: 5 dialogs → **0,
  twice**, copy ~2 min → ~55 s. Full write-up + the SCAN-WITNESS evidence in
  **`docs/sony_driver_mfm_read_reference.md`** — read it before any floppy or
  VIA-timer work; it also decodes every Sony error code (`-65` is benign
  polling of the absent second drive) and lists **seven theories tested and
  refuted**, several of which were built before that page existed.
  Instruments: `USE_DBG_HUD` + `scripts/parse_hud.py` (rows 7/8 = SCAN-WITNESS),
  `verilator/mame/floppy/sonyvars_watch.lua` (driver retry budgets from MAME),
  `verilator/tb_mfm_idcensus.v` (full-disk ID census), `tb_ism_sony +postgap=N`.
  ★ `USE_DBG_HUD` is currently OFF (commented out) in `MacLC.qsf` — flip it
  on for debug fits only; it must be OFF in release fits.
- SCSI writes validated 2026-07-29 (word-pairing fix f38c06f/ceaec45; 14.5 MB
  in-guest duplicate byte-identical). SCSI/CD reads validated same day
  (look-ahead boundary fix 082dcc4; CD copies byte-identical to ISO
  reference). Release fits no longer carry the JTAG probe decks — an
  always-on anchor in MacLC.sv (4dfb463, extended 2026-08-03 with per-disk
  read-ring words after the 11-word anchor proved insufficient on the
  post-floppy netlist) pins the SCSI capture + ring-serve cones; do
  not remove it (comment block explains), and gate every new fit in the
  FINDER on colour icons — `scripts/icon_gate.py` on frames captured with
  `scripts/grab_fresh.sh` (stock grab.sh serves STALE frames when video is
  dead), plus a >=2-boot Finder soak (see the probes-off anchor comment in
  MacLC.sv).
- ~~Floppy won't read at 16 MHz CPU speed~~ **NOT A LIMITATION OF THIS CORE**
  (corrected 2026-09-14): inherited MacPlus text, where `O5,Speed,8MHz,16MHz`
  fans `status_turbo` into the CPU enables, both VIAs' `E_div` and the disk
  logic. The LC has no such option — one fixed 16.25 MHz rate, see CPU clock
  above. Do not re-add it from MacPlus, and do not reach for it as an
  explanation when floppy timing misbehaves: there is no other speed to be in.
- Bus retry via HALT signal not implemented
- ~~"Original" aspect was 256:171~~ FIXED 2026-08-08: that was the Mac Plus
  512x342 screen, inherited at import — it drew ~12% wide and OVERFLOWED
  integer scaling on 1280x1024 panels (V-Integer requested 1437 px → blank
  screen). Now true 4:3 (both LC monitor modes are 4:3). Offline gate:
  `scripts/aspect_check.py` (faithful model of sys/video_freak.sv
  `video_scale_int`; also demos the old failures with `--show-broken`).
- CD-ROM (SCSI ID 3, OSD slot `SC4`): data, mixed-mode, and audio CDs.
  CD audio + the AppleCD Audio Player (listing, transport, FF/RW scan)
  fully working as of 2026-07-20 (standard SCSI-2 dialect on the
  CDU-8004 identity; BlueSCSI + Snow are the byte oracles; command gaps
  logged in docs/SCSI_CMD_GAPS.md). The **volume slider** works as of
  2026-07-29 (MODE SELECT/SENSE page 0x0E scales the CD-DA PCM),
  alongside 0x42 sub-channel formats 2/3, 0x44 READ HEADER, 0x45 PLAY
  AUDIO, 0xBB SET CD SPEED and mode page 0x2A — see
  the CD command notes in rtl/scsi.v.
- **★ The CD boot-attach stays ATTACHED during gates — never detach
  `MACLC.s4` as a gating step (user ruling 2026-08-09).** The open
  CUE/CHD-at-boot-attach hang fires intermittently on ANY build —
  including known-good ones — and has repeatedly been misread as "this
  build fails the hardware gate". Two boots of the same RBF can differ,
  so one boot is never a verdict: on a load hang, retry the boot rather
  than blaming the build (or detaching the CD). Flat 2048-byte images (ISO/TOAST)
  work on a stock Main_MiSTer; CUE/BIN (2352) and CHD need the Main
  fork's `support/maclc/maclc_cd` layer (branch
  `add-bluescsi-toolbox-for-MacLC`) — the validated binary ships in
  `releases/MiSTer`. The guest System needs the Apple CD-ROM extension
  (or a third-party CD driver) to mount discs. Serving law for any new
  DataIn command: transfer EXACTLY what the initiator arms (see
  docs/SCSI_CMD_GAPS.md).
- **Ethernet (Apple Ethernet LC Twisted Pair card, 820-0532, LC PDS slot $E):
  HW-VALIDATED + RELEASED 2026-08-22 — `releases/MacLC_20260822.rbf`
  (md5 4f31e0dd) + `releases/MiSTer` (md5 932ed605, the REQUIRED ethernet
  host).** The guest boots to the Finder desktop with the card On and FTP
  works (connect, login, transfer). Three defects fixed on the way (all the
  same class — the guest-RAM DMA engine moves 16-bit WORDS at EVEN addresses
  but the SONIC uses ODD ones): (1) odd end-of-list descriptor addr aborted
  transmit_chain leaving CR.TXP set → fixed host-side (mac_sonic.cpp DA()
  word-align + TX_ABORT); (2) odd RX-buffer pointer failed the packet store →
  PKTRX never set → fixed host-side (mac_eth.cpp rpc_read/write word-align +
  RMW); (3) a ~120x interrupt-ack livelock → fixed in RTL with an irq
  SUPPRESSION TIMER (pds_enet.sv: after a guest ISR write, hold irq low for
  IRQ_SUPP ~1.85ms then follow Main's INT word — only DELAYS irq, never masks
  a bit, so it can't deadlock; the earlier per-bit mask overlay DID deadlock/
  wedge and was replaced). For latency-sensitive gaming, IRQ_SUPP is the lever
  to tune DOWN (untested). The card is a RAM-less bus-master SONIC (DP83934).
  **2026-08-26 — TX-dead-on-24-bit + the 2 KB/s FTP class FIXED; the old
  "Fetch saturates the CPU" slowness theory is REFUTED.** Three fixes, all
  Main-side (RTL untouched), fork branch `mac-ethernet`
  `4f7717f`+`492a48b`+`fc87d1b`:
  (1) **24-bit-mode DMA pointers**: a fresh System 7 runs 24-bit addressing
  and stores Memory-Manager flags in pointer top bytes (bit31=locked — and
  DMA buffers ARE locked); the LC PDS has only 24 address lines so the real
  card never sees that byte. The model now masks EA() to [23:0] (registers /
  published pointers keep full width like real silicon) and dma_rpc()
  enforces the mailbox's 24-bit addr field (a dirty top byte overlapped the
  COUNT field, bits 47:40 — a 64-byte read became a ~33KB grind → 50ms RPC
  timeout → silent TX_ABORT: the "arp tx 33, ip tx 0" fingerprint, ARP
  passing because driver NewPtr buffers have clean top bytes). `ea_strip` in
  /tmp/mac_eth_stats witnesses it live. (2) **RX elasticity queue**: frames
  the model refuses BEFORE touching guest state (RDE/RBE latched, no free
  descriptor — sonic_rx_frame now returns -1 busy/0 dropped/1 delivered) are
  held in order (64-deep, 2s age cap, guest-unicast only) and redelivered
  when the ring frees: a burst tail costs ms, not a TCP RTO. `rx_held`/
  `max_depth` witness. (3) **THE throughput killer: kernel GRO** coalesced
  back-to-back TCP segments into >1518-byte super-frames before the
  AF_PACKET tap; the model refuses jumbos, so every data burst toward the
  guest silently vanished while solitary retransmits/ACKs/ARP/ping passed —
  ping RTT was 3.7ms DURING the 796 B/s crawl, the measurement that finally
  separated the layers. Linux TCP answered the burst loss with RTO backoff
  (measured rto 111s, backoff 9, cwnd 2, 55% bytes retransmitted).
  iface_gro_off() now runs at raw-socket open (named iface + /sys
  `lower_*` parents — macvlan children ride the parent's RX path where GRO
  actually runs); `rx_jumbo` + a one-time log line witness any recurrence.
  HW result: the same Fetch download went 796 B/s → **58 KB/s end-to-end
  average (3MB complete), 70-80 KB/s sustained mid-transfer** —
  era-appropriate for a real LC. Diagnosis tool kept for the next TCP
  mystery: `Main_MiSTer/support/mac/test/tcpsnoop.c` (static AF_PACKET TCP
  tracer, build cmd in header) — run on BOTH endpoints and compare.
  mac_sonic_test now 70 checks (24-bit dirty pointers, rx return contract).
  FPGA side = `rtl/pds/pds_enet.sv`: register doorbell + read shadows, MAC
  PROM (word-wide reads return the $0028 probe magic), flat 32K declROM at
  $FEFF'8000 served from DDR3, and a guest-RAM DMA engine that enters
  `rtl/sdram.v` as a 4th requester (idle-edges-only, level handshake, NEVER
  touches cpu_done — the download-port pattern). Host side lives in the
  Main_MiSTer fork (branch `mac-ethernet`, `support/mac/mac_eth*` +
  `mac_sonic*` — SONIC model ported from MAME dp83932c flows); **the
  modified Main is REQUIRED** (the old standalone `hps/maclc_eth` daemon is
  retired). declROM source of truth = `releases/341-0740_AppleLCTwistedPair
  .BIN` (sha1 447ce683…); `scripts/gen_enet_declrom.py` generates both the
  sim hex and Main's embedded header — never hand-edit those. Guest needs
  Apple's Network Software (no driver in ROM).
  **Settings are OSD options, NOT MiSTer.ini** (MiSTer.ini is parsed by Main
  for itself; the ONE thing it can do for us is pick the binary — see
  `main=` below): `OJ` Ethernet On/Off is a real core bit,
  while `o45` Net interface and `o03` MAC suffix live in the EXTENDED status
  range (32+) that this core's `wire [31:0] status` cannot read — the right
  home for host-only settings, and it keeps the low bits free (note 15:17 =
  video mode and bit 11 = the I-cache enable trick are USED but declare no
  CONF_STR entry, so grep `status[` before claiming a bit is free).
  Guest MAC = `08:00:07:4D:4C:0N` — fixed base + the OSD nibble, byte 4
  identifying the core. Do NOT "improve" this by deriving it from the box:
  the DE10-Nano has no MAC EEPROM, so u-boot gives every MiSTer
  `02:03:04:05:06:07` unless the owner wrote `linux/u-boot.txt`, and every
  hostname is `MiSTer` — both "unique" sources are identical across stock
  boxes. `/media/fat/games/MacLC/eth.cfg` (`iface=`, `mac=`) still overrides
  both, read at card start only.
  **2026-08-27 — BULK GUEST UPLOADS FIXED (the last open eth item): 3 MB
  Fetch PUT completes in ~34 s (~90-106 KB/s) on BOTH boxes; downloads
  re-gated 58-71 KB/s.** Four stacked defects, found by DISASSEMBLING THE
  ACTUAL GUEST DRIVER (the declROM has NO driver — content ends at 0x138;
  the live one is 'enet' 43 "Sonic 32 Ethernet Driver v1.1.1" in the guest
  System file, extracted with scratchpad hfs_extract.py + capstone) and by
  per-exit TX witnesses in /tmp/mac_eth_stats (`sonic_tx` line):
  (1) Main `fb3a191` — the CRDA reload never released the parked RX
  descriptor (in_use=0); the driver defers frees with in_use!=0 to a list
  drained only on PKTRX, so upload cadence starved the ring permanently.
  Rev>3 silicon releases it itself — the driver's TC chip-reset workaround
  is gated `SR<=3` and we report SR 6 (same gate in both driver versions).
  (2) Main `6bfd50d` — drain_ring was unbounded and shadows pushed only at
  poll end: a stale-shadow ISR dispatch loop flooded the doorbell at 80 kHz
  (watched via devmem), starving ALL of Main — both earlier "video capture
  died" wedges were this. Now DRAIN_BUDGET 256 + push_state per applied
  entry (+ drain_full witness). (3) RTL `7e7ff1a` — timed per-bit ISR
  clear-mask in pds_enet.sv: an ack reads back clear IMMEDIATELY (dispatch
  loops assume real-silicon write visibility); expires one IRQ_SUPP after
  the last ack — time-based, unlike the removed 08-22 value-reconcile
  overlay that wedged RX. tb_pds_enet 50 checks. (4) Main `b308dbf` — TX
  ring-walk discipline: ack clamp (only PUSHED ISR bits clearable — a
  TXDN set between the guest's read and its ack's apply must survive),
  ring-lap guard (one kick never revisits a descriptor), and the status
  gate + TX_PARK (descriptor status==0 <=> queued-and-unsent is the
  driver's own convention; nonzero parks like EOL, and EVERY abnormal
  exit now parks on the descriptor start instead of leaving CTDA
  mid-descriptor — the old abort-advance was the permanent post-stall
  death). `busy=` parks fire ~1,300/transfer and all recover.
  mac_sonic_test = 104 checks. Release: `releases/MacLC_20260827.rbf`
  (= e4e22e7b, SEED 4, STA +0.151 — the ISR-mask netlist re-rolled seeds;
  seed 8 was a corrupted-fetch fit: clean boot, video garbage under load)
  + `releases/MiSTer` (= 508786f0). ★ WT deadman lore: the driver arms
  0x02FAF080 = 50M counts = 5.0 s at 10 counts/us (20 MHz crystal); its
  TC handler is stats-only on SR 6.
  ★ **A card-ON boot hang means an OLD MAIN, not an old core.** Two of the
  three fixes were host-side (`f2679bf`), so the first published ethernet
  Main (`34b8994`) pairs happily and then hangs; the RBF alone cannot fix it.
  `md5sum /media/fat/MiSTer` must match `releases/MiSTer`. ★ Since Main
  `e61b111` (2024-03) MiSTer.ini can launch a DIFFERENT Main per core:
  `[MacLC]` + `main=MacLC_MiSTer` makes the stock Main re-exec into that
  file after loading the core (user_io.cpp `cfg.main`), so the fork can ship
  as its own file at the SD root and the stock `/media/fat/MiSTer` stays
  untouched (the earlier "inittab hardcodes the binary" claim here was
  wrong). The file must not be named `MiSTer` — the check is by name.
  ★ hps_io SLOT RULE (2026-09-14): Main sends a mount as ONE word,
  `(1<<slot)|0x80` when read-only, and hps_io takes img_mounted from
  `io_din[VDNUM-1:0]` and img_readonly from `io_din[7]` — so slot 7 is the
  read-only bit and MUST stay a hole (the Phase 1 floppy fit put the ext
  floppy there and hung after the chime: every read-only mount started its
  loader on an empty slot, zeros wrapped over RAM). Slots 0..6 need nothing
  special; 8..9 need the fork Main's 16-bit send (`spi_uio_cmd16`, branch
  `mount-notify-16bit`) — an 8-bit send truncates `1<<8` to 0 = slot 0.
  A MISSING or stock
  Main cannot hang anything — presence latches at guest reset, so no MAGIC
  means slot $E stays open-bus and the machine boots as with no card. Regression gates for ANY
  ethernet/SDRAM edit: `verilator/tb_pds_enet.v` (43 checks, build cmd in
  header), the Main fork's `support/mac/test/mac_sonic_test.cpp` (36),
  `verilator/tb_icache_seam.v` normal AND negative control after any
  sdram.v handshake edit, and the boot gate card-absent AND card-present
  (`+pds_magic +pds_rom=pds_declrom.hex`; card-present shifts the ?-icon
  past frame ~500 — the 32K ROM scan delays it, that is normal).
- **Serial (SCC, modem port): MIDI OUT + MIDI IN + PPP all work, HW-validated**
  (OUT 2026-08-12 cozyMIDI → MidiLink/MT32-pi; PPP 2026-08-13 LCP+IPCP on
  7.5.5 incl. guest FTP; IN 2026-08-14). MIDI IN sources: HPS UART (MidiLink
  USB, always wired) and the user-port MIDI-in line (MT32-pi TX pin) — the
  latter joins guest RX ONLY in OSD UART mode = MIDI (`uart_mode==3` AND-merge
  in MacLC.sv), so PPP/console guest-receive can never be hijacked by the user
  port (the 2026-08-13 serialIn-mux lesson). v1 is channel A only; printer-port
  TX (`txd_b_out`) still dangles at dataController. Regression gate for ANY SCC
  serial/baud/FIFO edit: `verilator/tb_scc_midi.v` (build cmd in its header;
  §3 = MIDI-in RX at 31250; keep the ROM-style loopback prelude).
