#!/usr/bin/env bash
# Archive the freshly built bitstream under the commit it came from.
#
#   bash scripts/archive_build.sh <label> [build-sha]
#
# Produces output_files/MacLC_<sha>_<label>.rbf (and .sof if present), leaving
# the originals alone. Ported from MacPlus_MiSTer scripts/archive_build.ps1
# (commit 1a91070); rewritten in bash because every other script in this repo is
# bash or python, and PowerShell would be the odd one out.
#
# Why archive at all: output_files/MacLC.rbf is ONE file that every compile
# overwrites. On MacPlus, 2026-08-22, two builds produced byte-identical
# hardware captures and answering "which build was that?" cost a JTAG session
# enumerating ISSP instances.
#
# ★ ONE REAL DIFFERENCE FROM THE MACPLUS ORIGINAL, AND IT WEAKENS THE
#   GUARANTEE. MacPlus reads the sha from rtl/build_tag.v -- the tag COMPILED
#   INTO the bitstream -- so the filename and what the board reports can never
#   disagree. **This core has no build_tag.v.** Its only compiled-in identity is
#   BUILD_DATE ("260915") in the OSD version string, which is a DATE and cannot
#   distinguish two builds made the same day.
#
#   So here the sha is an ASSERTION BY THE CALLER (defaulting to HEAD), not
#   something read out of the artifact. The design-moved and dirty checks below
#   are what is left of the safety, and they are worth keeping: they catch the
#   common case of archiving a bitstream that no longer matches the tree.
#   Restoring the full guarantee means adding a build_tag.v to this core and
#   stamping it pre-compile -- worth doing, not done here.
#
# Exit non-zero and archive NOTHING if the design moved since that build.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

LABEL="${1:-}"
[ -n "$LABEL" ] || die "usage: bash scripts/archive_build.sh <label> [build-sha]"
case "$LABEL" in
	*[!A-Za-z0-9._-]*) die "label must be alphanumeric/._- : '$LABEL'" ;;
esac

cd "$(dirname "$0")/.."

SHA_IN="${2:-HEAD}"
SHA="$(git rev-parse --short=8 "$SHA_IN" 2>/dev/null)" || die "not a valid commit: $SHA_IN"

# What matters is whether the DESIGN moved since that build, not whether any
# commit did. Doc-only commits after a compile are normal and harmless; an RTL
# commit means the bitstream no longer represents the tree.
DESIGN=(rtl sys MacLC.sv MacLC.qsf MacLC.sdc files.qip)
MOVED="$(git diff --name-only "$SHA" HEAD -- "${DESIGN[@]}")" \
	|| die "cannot diff $SHA against HEAD"
if [ -n "$MOVED" ]; then
	echo "design files changed since the build at $SHA:" >&2
	echo "$MOVED" >&2
	die "re-compile rather than archiving a stale bitstream"
fi

HEAD_SHA="$(git rev-parse --short=8 HEAD)"
if [ "$HEAD_SHA" != "$SHA" ]; then
	echo "note: HEAD is $HEAD_SHA; the build is $SHA, design unchanged between them."
fi

# Uncommitted design edits are the other way to build something untracked.
DIRTY="$(git status --porcelain -- "${DESIGN[@]}")"
if [ -n "$DIRTY" ]; then
	echo "WARNING: design files are dirty; the archive may not match any commit:" >&2
	echo "$DIRTY" | sed 's/^/  /' >&2
fi

archived=0
for ext in rbf sof; do
	src="output_files/MacLC.$ext"
	[ -f "$src" ] || { echo "no $src, skipping"; continue; }
	dst="output_files/MacLC_${SHA}_${LABEL}.$ext"
	[ -e "$dst" ] && die "$dst already exists; pick another label"
	cp "$src" "$dst"
	echo "archived $dst  ($(stat -c%s "$dst") bytes, md5 $(md5sum "$dst" | cut -d' ' -f1))"
	archived=$((archived + 1))
done
[ "$archived" -gt 0 ] || die "nothing archived"
