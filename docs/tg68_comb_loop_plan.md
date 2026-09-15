# TG68 combinational loop — assessment and execution plan

Written 2026-09-15 on branch `tg68-break-comb-loop`. Fork-local staging
document (pr_guidelines §3b: does not travel in a PR).

---

## 0. Verdict

**Concept approved.** The loop is real, it is now named node-by-node, it
entered this core through a MacLC-specific kernel fix (it is not in upstream
TG68K / MacPlus), and it can be removed with a
change that deletes exactly one dependency edge and adds none, so its
functional equivalence can be argued by inspection and checked mechanically.

**But the fix on its own does not move slack.** Breaking the loop makes STA
*exact* for the kernel; it does not make the regfile cone shorter or its
placement less variable. What ends seed roulette is the second step that
exactness makes legitimate: restoring the genuine two-period budget the SDC
withdrew *because of* the loop. So this is two phases with separate gates:

| Phase | Change | What it proves |
|---|---|---|
| A | remove the loop edge in the kernel; SDC untouched | STA reports the kernel honestly; no functional change |
| B | restore the two-period credit on the loop-free kernel | whether the SDC's causal story was right (hardware decides) |

Phase B is a hypothesis test, not a foregone conclusion. Its failure mode is
informative and is written down in §4 before the experiment runs.

---

## 1. What the loop actually is

Source: the Sep 12 build's `output_files/MacLC.sta.rpt` lines 972-1104, which
lists all 132 nodes under `Warning (332125)`. `scripts/report_loops.tcl` was
written to obtain this list; the fit and STA reports already contain it, so the
script was not needed (keep it — it is the tool for a *future* loop).

Distinct signals in the 132 nodes (node counts): `setstate` 35, `Mux355` 28,
`Mux356` 12, `setexecOPC` 11, `Mux45` 8, `Mux241` 7, `Mux314` 5, `set` 4,
`Mux46` 4, `Mux313` 4, `process_16` 3, `Mux240` 3, `datatype` 2, `Selector9`
2, `Selector83` 2, `Mux202` 2. **No** `RDindex`, regfile, bypass, `OP1out` or
`addr` nodes: the loop is entirely inside the decode process plus the
`setexecOPC` term.

The cycle, in `rtl/tg68k/TG68KdotC_Kernel.vhd` (current line numbers; the
report's "line 1656" is the same `#data` test before later commits shifted it
to 1645):

1. **`setexecOPC` → `datatype`.** Line 2973-2976, MULU/MULS only:
   ```vhdl
   datatype <= "01";
   IF setexecOPC='1' THEN
       datatype <= "10";
   END IF;
   ```
   This is the **only** one of the 15 `setexecOPC` guard sites that assigns
   `datatype`. The other 14 assign `dest_hbits`, `dest_areg`,
   `source_lowbits`, `source_areg`, `source_2ndHbits`, `dest_2ndHbits`
   (→ the RDindex processes at 630/666 → the registered regfile read),
   `set(OP1out_zero)` / `set(OP2out_one)` (consumed only as `exec(...)`,
   registered at 1269/1275), and `set(changeMode)` (line 1562 → 1575:
   `to_USP`/`from_USP`/`setstackaddr`, never `setstate`). None reach
   `setstate`, which is what the node list says too.
2. **`datatype` → `setstate` / `next_micro_state`.** The EA-build block
   (`(ea_build_now AND decodeOPC) OR exec(ea_build)`, lines 1591-1656):
   - line 1600: `IF opcode(5 downto 3)="010" AND datatype="10" THEN
     setstate <= "01"; next_micro_state <= ld_An1; ELSE set(get_ea_now) <= '1'
     ...` and line 1581 turns `set(get_ea_now)` into `setstate <= "10"`.
   - line 1645 (`#data`): `IF datatype="10" THEN set(longaktion)` — this one
     only reaches registers (memmask at 1190, `memaddr_a` at 934) and is not a
     loop edge; it is in the node set because the mux trees are shared.
3. **`setstate` / `next_micro_state` → `setexecOPC`.** Line 1052:
   `setexecOPC <= '1' when setstate="00" AND next_micro_state=idle AND
   set_direct_data='0' AND ...`.

Every read of `datatype` in the file, for the record: 936 (`memaddr_a`,
tests `="00"`), 1600, 1645, 1869 (ANDI/ORI/EORI, `set(longaktion)` only), plus
the two sensitivity lists. `set_datatype` is `datatype` by default (1497) and
is consumed at 1110 (`exe_datatype`, registered), 1195 (memmask, registered)
and 1587 (`set(longaktion)`, registers only).

**The SDC's description was wrong on mechanism.** It is not "the setstate mux
trees use setexecOPC as a select"; the edge is through `datatype`, and only
for one instruction. Its "not a functional oscillator" conclusion was right,
for the reason in §2.

**History.** The `AND datatype="10"` test at line 1600 was added on
2026-06-02 in `42ae7a6` by Dani Sarfati (danifunker), the core's maintainer:
"tg68k: fix cmp.l (An) flag-commit-vs-branch race (video-bank probe)". That is
in the MacLC_MiSTer history long before this fork existed (owner's first
commit: `4e55694`, 2026-09-12), so the loop is **danifunker's, not ours, and
not TG68K's**: the upstream TG68K kernel has the MUL override at 2974 but no
`datatype`-dependent `setstate` in the EA block, so it has no loop. The first
`332081` mention in the repo history is 2026-06-04; the multicycle SDC
(`29e1f69`) followed on 2026-06-07. The loop predates every
hardware-instability episode the SDC lists. Consequence for the PR: the fix
touches the maintainer's own kernel change, so the PR body should say so and
keep his cmp.l fix intact (§2 keeps the 1600 test; only the 2974 override
target moves).

---

## 2. The fix

At line 2973-2976 replace the override target:

```vhdl
datatype <= "01";
IF setexecOPC='1' THEN
    set_datatype <= "10";      -- was: datatype <= "10"
END IF;
```

with a dated comment block above it (pr_guidelines §3a: keep the why):
what the loop was, why `set_datatype` and not `datatype`, and that the EA-build
block must keep reading the decode-phase `datatype`.

### Why this is exact

- `set_datatype` defaults to `datatype` at 1497 and the later assignment
  wins, so `set_datatype` takes the **same value as before in every state**.
  Its three consumers (1110, 1195, 1587) are unchanged.
- `datatype` itself now differs from the old design only when
  (MUL/MULS) AND (`setexecOPC`='1'): old "10", new "01". Its reads:
  - **1600**: for this branch to see the old "10" it needs `setexecOPC`='1'
    while the EA block is active for a `(An)` source; the branch then forces
    `setstate`="01", which forces `setexecOPC`='0' — a contradiction. So the
    old design's only *stable* state for `MULx (An)` already had
    `setexecOPC`='0' and `datatype`="01", i.e. the ELSE branch (`get_ea_now`
    → `setstate`="10"). The new design computes that state without iteration.
  - **1645**: sits inside the `#data` branch, which sets `set_direct_data`='1'
    and therefore `setexecOPC`='0' unconditionally; identical values.
  - **1869**: ANDI/ORI/EORI, never MUL.
  - **936**: tests `datatype="00"`; false for "01" and "10" alike.
- The new design's dependency graph is a **strict subgraph** of the old:
  the only edge removed is `setexecOPC → datatype`, and `set_datatype`
  already depended on `setexecOPC` through `datatype`. The change cannot add
  a loop or a timing path; it can only remove.

### Alternatives considered and rejected

- Reverting the 1600 test: loses the cmp.l (An) fix (`42ae7a6`, video-bank
  probe).
- Replacing the 2974 guard with a state condition (`nextpass` /
  `decodeOPC`): changes edge cases (a pending `exec_write_back`) and is not
  provable by inspection.
- Raising the 32 ns cap, or LogicLock: forbidden by the SDC / unavailable in
  Quartus Lite (see the memory note).

---

## 3. Phase A — break the loop, SDC untouched

Rule for the whole phase: **no repo edits while a Quartus build runs**
(the `.sdc` is read after the fit). Sequence the edit, then the builds.

### A0. Validate the VHDL → Verilog toolchain before touching the VHDL

Quartus compiles the `.vhd` directly (`rtl/tg68k/TG68K.qip`); Verilator
compiles the generated `TG68KdotC_Kernel.v`. Both must carry the fix.

- WSL has Verilator 5.052 and **no ghdl**. Install: `sudo apt install ghdl`
  (or build GHDL 6.0.0, the version the committed `.v` came from).
- Regenerate from the **unchanged** VHDL. Two scripts exist and disagree on
  generics: `scripts/regen_tg68k.sh` passes `-g` overrides
  (`BarrelShifter=2`); `rtl/tg68k/convert_to_verilog.sh` uses entity defaults
  and says GHDL 6.0.0 rejects `-g`. Try `regen_tg68k.sh` first; fall back to
  `convert_to_verilog.sh` if ghdl rejects the flags.
- **Gate:** `git diff --stat rtl/tg68k/TG68KdotC_Kernel.v` is empty
  (toolchain reproduces the committed file byte-for-byte), **or**, if the
  ghdl version differs textually, build the sim from the regenerated file and
  require `cpu_trace.log` identical to a run from the committed file over the
  same frame count. Do not proceed until one holds. Keep that trace as the
  Phase A reference (`scratch/tg68loop/ref_cpu_trace.log`).

### A1. Apply the fix

The `.vhd` edit from §2 plus its comment block. Regenerate the `.v`. Commit
both together (the two must never diverge; `docs/verilator_differences.md`).

### A2. Prove the loop is gone — Analysis & Synthesis only (minutes)

`quartus_map` (or `build_only.sh` stopped after mapping). Gates:
- `output_files/MacLC.map.rpt` "Number of logic cells representing
  combinational loops" = **0** (was 17).
- No `332125` / `332126` in the map report.
If a loop remains, its node list is in the report: **stop and reassess**; do
not cut anything else on a guess.

### A3. Prove nothing changed functionally — Verilator trace diff

`cd verilator && make clean && make`, run the same frame count as A0's
reference (400 frames; boot reaches the desktop at ~360 and the ROM's RAM
sizing / init code exercises MULU), card-absent.
- **Gate:** `diff ref_cpu_trace.log cpu_trace.log` empty.
- Record whether the trace contains a MUL with an `(An)` source (the one case
  where old and new `datatype` differ transiently): `grep -c -i 'mul' ` and
  inspect the operand column. If absent, the equivalence for that case rests
  on the §2 argument alone; say so in the commit message.

### A4. Full fit, SEED 4 (the committed value), SDC unchanged

`bash scripts/build_only.sh`. Record against the Phase 3b seed-4 report
(worst setup -1.024 ns, TNS -8.055, six paths in the regfile cone):
- `332081` absent from `.fit.rpt` and `.sta.rpt`.
- Warning count diffed against the parent compile and **explained**
  (pr_guidelines §2). The 132 `332126` sub-warnings vanish; anything else
  that moves needs a reason.
- Worst kernel setup slack and the failing-path set.

State the expectation honestly before looking: STA can now time paths it
previously *estimated*. Slack may be worse on paper. A fit that fails the cap
here was failing invisibly before; that is the constraint doing its job, not a
regression of the fix. If seed 4 fails the cap, fit seeds 7 and 5 as well and
record the three slacks: the spread is Phase B's baseline, not something to
"solve" here.

### A5. Hardware gate on the Phase A RBF

On whichever seed met the cap (`scripts/deploy_screenshot.sh`):
- Two boots to the Finder (one boot is never a verdict; CD attach stays
  attached).
- QuarkXPress typing — the known reproducer of the kernel-timing class.
- Speedometer 3.23 CPU run, compared to the PR #5 numbers in
  `docs/Speedometer_3-23_Benchmarks.md`. Identical function ⇒ identical
  score; a cheap hardware witness that MUL-heavy code is untouched.
- Restart soak as in E1.

### A6. Record

- `MacLC.sdc`: rewrite the loop paragraph of the kernel-cap block. It
  currently states a wrong mechanism and, after A2, a stale fact. **Keep the
  cap** in Phase A; say the loop is gone and that the cap is now a *policy*
  choice pending Phase B, not a workaround.
- `CLAUDE.md` Key Technical Details: one line — the kernel has no
  combinational loop as of this commit; do not re-introduce a `setexecOPC`
  → `datatype` edge (or any `setexecOPC`-guarded assignment that reaches
  `setstate`).
- Memory note (`tg68-comb-loop-plan`): status → Phase A done, with the seed
  slacks.
- PR branch per pr_guidelines §3b when it is time: the design-file diff
  against this dev branch must be empty; the gated RBF is the one that ships.

### Cost

ghdl install + A0 ~1 h (two 400-frame sims can run concurrently in WSL);
A2 ~5 min; A3 ~30 min; A4 ~35 min per seed; A5 ~30 min.

---

## 4. Phase B — the two-period credit, as a hypothesis test

**Hypothesis (the SDC's):** credit fits failed on hardware because the loop
hid part of the kernel's delay from STA, so "met at 61.5 ns" was not a
statement about the real paths. **Prediction:** on the loop-free kernel, a
credit fit that STA reports met is genuinely ≤ 61.5 ns on every kernel path
and is stable on hardware regardless of seed.

- **B1.** On the Phase A RTL, replace the cap with
  `set_multicycle_path -setup -end 2` / `-hold -end 1` (kernel-internal, as
  `29e1f69`). Keep the cap's history text; mark it "under test".
- **B2.** Fit **seeds 4, 5 and 7** — the 2026-09-12 trio where one RTL gave
  clean / desktop hang / desktop freeze. Record worst kernel path per seed
  (expect 32-38 ns, as the SDC observed) and the placement spread.
- **B3.** Hardware, all three RBFs, each: two boots, desktop soak, Quark
  typing, restarts.
- **Decision rule, fixed now:**
  - **3/3 pass** → hypothesis confirmed. Credit restored, SDC rewritten
    around the loop-free kernel, seed roulette over (≥ 23 ns real margin).
  - **Any fail** → the loop was not the whole cause. Keep the cap. The failing
    seed is a new, reproducible fact about *some other* untimed path, and the
    existing tooling applies (`scripts/loop_disasm.py`, the fetch-corruption
    fingerprints in `docs/CPU_Perf_Log.md`, JTAG probes — the chain is live).
- **Never** ship a credit fit on the strength of STA alone (seed-8 precedent:
  STA met, clean boot, video garbage under load).

### Cost

Three fits ≈ 2 h; hardware ≈ 1 h.

---

## 5. Independent hedges (not part of this work; can run in parallel)

From the memory note, untried and cheap: `PLACEMENT_EFFORT_MULTIPLIER` 2.0
(build time only) and `ALM_REGISTER_PACKING_EFFORT` (direction unknown, one
build). Neither changes the design; neither is a substitute for Phase A.

---

## 6. Phase A results (2026-09-15, evening)

Every automated gate passed. Hardware (A5) is outstanding and needs the owner:
this machine has no MiSTer ssh key and `scripts/local.env` is the untouched
sample.

| Step | Result |
|---|---|
| A0 toolchain | GHDL 6.0.0 (Windows mingw64 build, kept in the session scratchpad, nothing installed) + `rtl/tg68k/convert_to_verilog.sh` reproduces the committed `.v` **byte-for-byte** after stripping the CRs the Windows build emits. `scripts/regen_tg68k.sh` does NOT: its `-gBarrelShifter=2` override yields a different netlist (`tg68k_alu_Blogic_2_1_2_2` vs the committed `_2_1_2_1`). Ubuntu 22.04's apt `ghdl` 1.0.0 cannot emit Verilog at all (`--out=verilog` unknown). |
| A1 fix | One non-comment line: `datatype <= "10"` → `set_datatype <= "10"` at the MUL site, plus the comment block. `.v` regenerated. |
| A2 loop gone | **No 332081 / 332125 / 332126 in `.fit.rpt` or `.sta.rpt`.** ★ The map report's "logic cells representing combinational loops" went 17 → **16**, not 0 — that counter is NOT a loop gate; it counts something else. The fitter/STA warnings are the gate. `report_loops` is not a TimeQuest command in 17.0 (script rewritten to say so). |
| A3 trace diff | 400-frame boot (392 frame markers in both), **16,482,713 lines byte-identical**, MD5 `43018cee…` both, stderr identical. Coverage: `muls.w D5,D0` ×36,277, `mulu.w #imm` ×160, `mulu.w (d16,An)` ×52, `mulu.w Dn` ×6 — **no `(An)`, `(An)+` or `-(An)` source**, hence the directed bench below. |
| A3b directed bench | NEW `verilator/tb_mul_modes.v`: bare kernel, 1-cycle bus, every word and long multiply addressing mode incl. `(An)`, `(An)+`, `-(An)`, the 64-bit `(An)` form, a signed case setting N, and a `cmp.l (An)`+`beq` right after (the 42ae7a6 path). Old vs new kernel: **2,070 bus-cycle lines identical**; products hand-checked (21, 35, 49, $1234, 42, 15, 20, 35; -6 with N; $0015000F, $00F500AF, $015700F5, $12340, $03720276, $004B002D); CPU ends in the intended spin loop, no trap. |
| A4 fit, SEED 4 | 19m21s. Setup and hold met on every clock. Core PLL domains +2.276 / +2.774 ns; chip worst +0.575 ns is the framework HDMI clock. **Kernel-internal worst path: 24.815 ns data delay, slack +6.858 ns against the 32 ns cap** (`exec[1]` → `ALU|Flags[2]`). Parent seed-4 fit (19:09, same RTL minus the fix): **-1.024 ns**. Warning-ID diff parent→new: −1 Critical 332081, −1 Critical 332148 (timing not met), −1 332125, −132 332126; map warnings 214 → 214; nothing else moved. |
| Artifact | `scratch/tg68loop/MacLC_fix_seed4.rbf`, 4,289,012 bytes, MD5 `76a13d6a`, with both report sets, the bench logs and the TimeQuest kernel-path report beside it. |

**Correction to the earlier record.** The "seed 7: -0.028 ns, still VIOLATED"
fit (19:32) failed on **hold** (`Hold 'general[1]'` -0.028) with all setup
slacks positive; it was never a kernel-cap failure. Seed 4 at -1.024 ns was.

**What the 7 ns swing does and does not say.** One seed, one design. It says
the fitter no longer had to hedge around an estimated loop, and that STA's
view of the kernel is now honest; it does not measure the placement spread
across seeds, which is Phase B's baseline (B2) and still to be taken.

### A5 — hardware gate, for the owner

Load `scratch/tg68loop/MacLC_fix_seed4.rbf` and run the plan's A5 list: two
boots to the Finder (CD attach stays attached), QuarkXPress typing, a
Speedometer 3.23 CPU run compared to the PR #5 numbers (identical function ⇒
identical score), and a restart soak. Record the outcome here before Phase B.

### A5 result (owner, 2026-09-15 evening) — PASS with one noted intermittent

RBF `scratch/tg68loop/MacLC_fix_seed4.rbf` on the DE10-Nano:
- Boots to the Finder; QuarkXPress ran (the known reproducer of the
  kernel-timing class); the core was reported "quite stable".
- **Speedometer 4.02** (Quadra 605 = 1.0, same image/System as the PR #5
  A/B): CPU **0.202**, Graphics 0.199, Math **0.662**, Disk 0.434, PR 0.244.
  Baseline 20260827 / PR #5: CPU 0.203 / 0.203, Graphics 0.202 / 0.207, Math
  0.662 / 0.662, Disk 0.480 / n.r., PR 0.248 / 0.250. **CPU and Math — the
  kernel-sensitive figures — are identical**, the hardware-side equivalence
  witness. Disk −9%: run with a CD mounted; the memory records a mounted
  floppy costing ~13% on both builds, so mount state is the first
  explanation — re-run with only the boot disk mounted before reading it as
  a core change. (Earlier text in this doc said "Speedometer 3.23"; the A/B
  tool is 4.02.)
- **Restart:** the first Special ▸ Restart with a CD mounted hung at a frozen
  desktop with a live mouse (a driver call never returning, not a CPU
  freeze). Two further restarts, one with the CD mounted and one without,
  both came up clean. That is the intermittent CD-attach class CLAUDE.md
  documents ("fires on ANY build, retry the boot rather than blaming the
  build"), so it is recorded, not charged to the fix. If it recurs: a debug
  fit with `USE_DBG_OBSERVER` was built for it
  (`scratch/tg68loop/MacLC_fix_seed4_dbg_observer.rbf`); load it, reproduce,
  `bash scripts/read_probes.sh` — PIFA/PADR name the spinning driver loop,
  PSC2/PSC3/PSCS the SCSI phase and last polled register. The JTAG chain is
  live from this machine (checked 2026-09-15: DE-SoC [USB-1], 5CSEBA6).
  Note the release fit has NO probe instances, so nothing can be read from it.

**Phase A is closed.** Phase B (§4) is the next decision.
