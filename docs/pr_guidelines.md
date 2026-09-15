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
- [ ] ★ **No FORK-LOCAL POLICY in an upstream PR.** We work in
      `danielb0/MacLC_MiSTer`, which is ours — we can adopt any policy we like
      *here*. What must not travel upstream to `MiSTer-devel/MacLC_MiSTer` is
      our working practice: the boot-gate policy above, this file's own §1-2
      (reviewer role, merge discipline), and anything else that reads as
      instructions to the maintainer rather than facts about the core. **The
      line is the PR boundary, not the repo boundary.** Check the diff for
      `CLAUDE.md` and `docs/` before opening one; a PR is the moment those
      commits stop being ours.
- [ ] **The debug macros are commented** in `MacLC.qsf` — `USE_DBG_PROBES`,
      `USE_DBG_OBSERVER`, `USE_DBG_HUD`, `USE_ADB_ISSP`, `USE_AUDIO_ISSP`.
      `USE_DBG_HUD` especially: it paints debug rows over the guest's screen.

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

## 3a. CODE comments: the MacPlus style does NOT transfer

★ Owner's ruling, 2026-09-15. Section 3 adopts MacPlus's style for the **PR
body**. It does not adopt its style for **comments in the code**, and the
distinction matters enough to state plainly, because "use the MacPlus
guidelines" reads like it covers both.

MacPlus `2abe000` ("Same comment style for the merged code in the files this PR
touches") deliberately *cut* explanation out of seventeen files — "one-line
comments on signals and steps, tables for reference data, **no explanatory
paragraphs, no dated notes**" — turning six-line rationales into two-line
statements of fact. That was right **there**: the code was going into a foreign
repo with an established hand, and a PR that reads as two different authors is a
reason for a reviewer to push back.

**None of that applies here.** This repo is developed by danifunker and by
Claude. Long comments are not clutter to be trimmed before shipping — they are
the working documentation, and for an AI-assisted codebase they are what makes a
cold start possible. So:

- **Keep the paragraphs.** The "why", the alternative that was tried and failed,
  the hardware finding behind a constant.
- **Keep the dated notes.** `★ 2026-08-06`, `FIXED 2026-09-15`, `REFUTED` —
  these carry the provenance that stops a settled question being reopened, and
  they are exactly what `2abe000` removed.
- **Keep the never-do-this laws.** The anchor blocks' "never remove, ifdef, or
  XOR-fold", `via6522.sv`'s SR edge-detection history, the floppy write path's
  declaration-order note. Each of those is a comment that exists because
  somebody already lost time to the thing it warns about.
- **Do not "tidy" a comment block to match surrounding terseness.** In this repo
  the verbose block is the correct register and the terse neighbour is the
  legacy one.

The test is not "is this comment long" but **"would deleting it cost someone a
day"**. CLAUDE.md is largely a distillation of comments like these; where a
finding is big enough it goes in both.

If code ever *is* sent upstream to another repo, do the `2abe000` trim on that
branch only, as its own comment-only commit, and verify it decomments identically
to the original — never on `master` here.

---

## 3b. The PR branch

Adopted from MacPlus, where the dev branches (`floppy-write`, `scsi-upgrade`,
`mac128k`, `cd-*`) were never what got PR'd — `upstream-pr` and `upstream-pr-2`
were. **Work on a dev branch; PR from a branch built for the purpose.**

What the PR branch does:
- **Only the relevant files.** For us that means the RTL, the testbenches the PR
  body cites (a reviewer must be able to re-run the counts), the scripts needed
  to use or verify the feature, and the `releases/` RBF. It does NOT mean
  `CLAUDE.md`, `docs/pr_guidelines.md`, or `docs/floppy_write_plan.md` — the
  first two are fork-local policy (§2) and the third carries our internal
  staging, which §1 says not to describe outside this repo.
- **Probe decks off.** `USE_DBG_*` commented in `MacLC.qsf`. They already are;
  the point is to check rather than assume, because flipping them is
  working-tree-only and easy to leave behind.
- ~~Comments stripped.~~ **NOT here** — see §3a. MacPlus stripped them because
  the code was entering Sorgelig's repo with its own established hand. This core
  is danifunker's and he works with Claude Code too, so the comments stay.

### Code-synchronised, and that is CHECKABLE

MacPlus kept the PR branch code-synchronised with dev and *proved* it: commit
`2abe000` states "all seventeen files decomment identically to e9d0c8f" — strip
the comments from both sides, diff, require empty. That is what made a
comment-only commit demonstrably comment-only.

**Because we are not stripping comments, our version of that check is stronger
and trivial to run:**

```bash
git diff <dev-branch> <pr-branch> -- rtl/ MacLC.sv MacLC.qsf MacLC.sdc files.qip
```

**It must be EMPTY.** Not "reviewed and looks equivalent" — empty.

★ **Why this matters more than tidiness: it is what makes the hardware gate
transfer.** We gate an RBF built from a dev-branch commit. If the design files
are byte-identical on the PR branch, that gate is evidence for what we are
actually proposing to merge. If they differ by so much as a line, the PR ships a
design nobody has ever run, and the testing paragraph in the PR body becomes a
claim about a different binary.

Run it again after every rebase or cherry-pick, not once at the start. "Always
kept code-synchronised" is a continuous property; the moment dev moves, the PR
branch is stale and its gate no longer applies.

---

## 4. What not to write

- Anything the testing does not support. "Should work", "in theory", "probably
  fixes" — either test it or leave the claim out.
- Internal staging. The phase numbers in `docs/floppy_write_plan.md` are how we
  sequence the build; the maintainer has been given the finished format list,
  not the stages (plan §1). Do not describe stages outside this repo.
- Session narrative. What was tried and abandoned belongs in the commit message
  or the plan doc, not the PR body.
