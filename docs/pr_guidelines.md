# PR guidelines

Adopted 2026-09-15 from the MacPlus upstream PRs (`../MacPlus_MiSTer/
UPSTREAM_PR_BODY.md`, `UPSTREAM_PR2_BODY.md`), which set the house style for
this work. **What changes here is who reviews.**

---

## 1. We are the reviewers

On MacPlus the PR goes to Sorgelig, and his review is the gate: the bar is
upstream acceptance, and a PR that is not ready simply does not land.

On this core there is no such gate. The user owns the repo, danifunker
maintains it and can cut releases that feed **update_all**, and in practice
nothing gets stripped back out. So:

> **Treat "merged" as "shipped".**

That is the whole difference, and it inverts where the care goes. On MacPlus the
PR body's job is to persuade a reviewer. Here its job is to be the record we
review *ourselves* against — because after it merges, the next pair of eyes on
it may be an end user's.

Consequences that follow, and they are not negotiable by convenience:

- **A half-finished user-visible feature does not merge.** Either finish it, or
  gate its CONF_STR row behind a build macro the way the probe decks are gated
  (`USE_DBG_*` in `MacLC.qsf`, kept commented for release, flipped
  working-tree-only). The RTL may land; the OSD row may not advertise it.
- **A feature that looks like it works but is not durable is the worst case**,
  worse than one that plainly fails. Phase 3b of the floppy-write plan is the
  live example: writes that reach SDRAM but not the file survive an eject and
  reinsert within a session and vanish at reset. A user cannot tell that from
  working persistence until they lose something.
- **Staged plans are a MERGE discipline, not just a release one.** The
  floppy-write plan's §1 gate ("nothing is released until every format is
  covered — one PR, one release") only holds if the intermediate phases also
  stay unmerged. danifunker has offered to take the floppy work as incremental
  PRs; accepting that would defeat the gate.
- **Debug macros off.** `USE_DBG_PROBES`, `USE_DBG_OBSERVER`, `USE_DBG_HUD`,
  `USE_ADB_ISSP`, `USE_AUDIO_ISSP` all commented in `MacLC.qsf`. `USE_DBG_HUD`
  especially — it paints debug rows over the guest's screen. This is now a
  release-correctness item, not a tidiness one.

---

## 2. Before merging — the reviewer's checklist

Nobody else is going to run these.

- [ ] **Hardware-tested**, on the actual DE10-Nano, on the build being merged —
      not on an ancestor and not on a rebuild. A rebuild is a different fit.
- [ ] **The RBF in `releases/` is the binary that was gated**, copied, not
      recompiled (the build ID alone perturbs the fit).
- [ ] **Quartus clean**: 0 errors, timing met, and the **warning count diffed
      against the parent compile**. An unexamined jump is how MacPlus shipped a
      latch inside a combinational loop feeding its decoder's reset — it sat in
      the log as 57 → 65 and nobody looked.
- [ ] **Every testbench named in the PR actually re-run** against the merge
      commit, not remembered from when it was written.
- [ ] **Regression gates for the areas touched** — the ones CLAUDE.md lists per
      subsystem (`tb_disk_swap` for media change, `tb_pds_enet` +
      `tb_icache_seam` for SDRAM/ethernet, `tb_scc_midi` for serial, the boot
      gate for anything top-level).
- [ ] **A second boot.** One boot is never a verdict on this core; the CD
      boot-attach hang fires intermittently on known-good builds.
- [ ] **Nothing from `scratch/` committed**, and no probe/experiment RBFs in
      `releases/`.

---

## 3. House style for the PR body

Taken from the MacPlus PRs, which are the model. The register is plain and
factual; no superlatives, no "comprehensive", no emoji, no claims of
completeness that the testing does not support.

**Title** — a bare list of what is in it, not a slogan:
> `Floppy write support, SCSI rework, CD-ROM drive with CD audio`

**If it is one PR covering several pieces, say why in one line.** MacPlus:
*"One PR: the three pieces share the SCSI/HPS plumbing and were tested as one
build."*

**A bold section per feature**, then bullets. Lead each bullet with the
**user-visible behaviour**, and give the mechanism only where it explains a fix:

> * Images are writable, gated by a new **Floppy Write** OSD option that
>   defaults to Off. An image marked read-only on the SD card stays
>   write-protected. Writes commit back to the `.dsk` and survive eject/remount
>   and a power cycle.

**Describe a defect as cause → effect, in one breath.** This is the single most
characteristic move in the MacPlus bodies and it is worth copying exactly:

> * Floppies are readable at 16 MHz. The IWM's read-data latch was cleared on a
>   fixed wall-clock interval while the driver's polling loop scales with the
>   CPU, so every disk byte was read twice. The interval now scales with CPU
>   speed.

**List new files, and say what is untouched.** *"New files: `rtl/mac_model.v`,
… `MacPlus.qsf` is untouched."* On this core, saying `sys/` is untouched is
worth a line of its own — it is a standing rule (CLAUDE.md), so its absence
from the diff is a claim a reviewer can check.

**A Dependency section when something external is needed**, with the honest
consequence spelled out rather than softened:

> **Dependency.** The CD-ROM feature needs the MacPlus CD slot in Main_MiSTer
> (#1295) — merged, but not yet in any *released* Main binary. A MacPlus
> release cut before the next Main release would ship a CD-ROM option that does
> nothing on a stock install.

For this core the recurring one is the **forked Main** for ethernet
(`releases/MiSTer`): a card-ON boot hangs on an older Main, and the RBF alone
cannot fix it.

**A Testing section, last, and specific.** Counts, what was exercised on
hardware, what was verified offline, and the toolchain:

> **Testing.** 163 testbench assertions across the NCR5380 seam, the SCSI and
> CD-ROM targets and the audio mixer. Hardware-tested on a DE10-Nano with the
> build in `releases/`: boots with a disc mounted, CD-ROM read and a byte-exact
> CD → disk copy, CD audio, and floppy writes checked by whole-volume hash
> diff. Compiles clean in Quartus 17.0 Lite, timing met.

Note what that paragraph does: it names the **artifact** (the build in
`releases/`), the **machine**, the **operations**, and an **offline byte-level
check** that does not depend on the core being right. "It still boots" is not
testing; a byte diff against a pre-change copy is.

---

## 4. What not to write

- Anything the testing does not support. "Should work", "in theory", "probably
  fixes" — either test it or leave the claim out.
- Internal staging. The phase numbers in `docs/floppy_write_plan.md` are how we
  sequence the build; the maintainer has been given the finished format list,
  not the stages (plan §1). Do not describe stages outside this repo.
- Session narrative. What was tried and abandoned belongs in the commit message
  or the plan doc, not the PR body.
