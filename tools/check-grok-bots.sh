#!/bin/sh
# Verify that project-scoped Grok bot definitions keep Cell's gate, not
# the bundled implementer's "run fmt and clippy".
#
# WHY THIS EXISTS. Grok's bundled implementer persona says "Run fmt and
# clippy before declaring done". This repository is a Zig compiler. A
# project overlay that forgets -Dswift=false, tools/check.sh, or the
# --test-filter false-green trap sends every implementer session back to
# that generic bar. The overlay lives in four files under .grok/; nothing
# else keeps those words in those files.
#
# WHAT THIS CHECKS. Every live file under the Grok project discovery
# roots (.grok/agents, .grok/personas, .grok/skills, .grok/rules) must
# mention -Dswift=false, tools/check.sh, --test-filter, refAllDecls, and
# worktree. The first three are the gate; the last two are the operational
# traps (false-green filter, canonical checkout). The named implementer
# overlays and at least one skill must exist; an empty tree is a failure,
# because silence is what an unenumerated form produces and silence here
# would mean "the generic bar still applies".
#
# FALSIFIED BEFORE BEING TRUSTED, in both directions: deleting
# .grok/agents/implementer.md exits 1; stripping any required token from
# any scanned file exits 1; an unmodified tree exits 0. The first version
# of a check that grepped AGENTS.md instead of the live bot files would
# have been green while the overlay was missing.
#
# Exit 0 clean, 1 on drift, 2 on a setup problem.

cd "$(dirname "$0")/.." || exit 2
ROOT=${CELL_GROK_BOTS_ROOT:-.}
cd "$ROOT" || { echo "check-grok-bots: cannot cd to $ROOT"; exit 2; }

required=".grok/agents/implementer.md
.grok/personas/implementer.toml"

# Criterion 4's three tokens, plus criterion 2's two traps so dropping
# either trap is loud the same way dropping the gate is.
TOKENS="-Dswift=false
tools/check.sh
--test-filter
refAllDecls
worktree"

status=0
nfiles=0

missing_required=""
for f in $required; do
    if [ ! -f "$f" ]; then
        missing_required="$missing_required $f"
    fi
done
if [ -n "$missing_required" ]; then
    echo "DRIFT missing required overlay:$missing_required"
    status=1
fi

skill_count=0
for f in .grok/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    skill_count=$((skill_count + 1))
done
if [ "$skill_count" -eq 0 ]; then
    echo "DRIFT missing required overlay: .grok/skills/*/SKILL.md"
    status=1
fi

collect() {
    for f in .grok/agents/*.md \
             .grok/personas/*.toml \
             .grok/rules/*.md \
             .grok/skills/*/SKILL.md; do
        [ -f "$f" ] || continue
        printf '%s\n' "$f"
    done
}

files=$(collect)
if [ -z "$files" ]; then
    echo "DRIFT no project Grok bot files under .grok/{agents,personas,skills,rules}"
    exit 1
fi

echo "scanning:"
IFS='
'
for f in $files; do
    echo "  $f"
    nfiles=$((nfiles + 1))
    missing=""
    for tok in $TOKENS; do
        if ! grep -qF -- "$tok" "$f"; then
            missing="$missing $tok"
        fi
    done
    if [ -n "$missing" ]; then
        echo "DRIFT $f: missing$missing"
        status=1
    fi
done

echo "hits:"
for tok in $TOKENS; do
    hits=0
    hit_files=""
    for f in $files; do
        if grep -qF -- "$tok" "$f"; then
            hits=$((hits + 1))
            hit_files="$hit_files $f"
        fi
    done
    echo "  $tok  ($hits/$nfiles)$hit_files"
    if [ "$hits" -eq 0 ]; then
        echo "DRIFT no file mentions $tok"
        status=1
    fi
done

[ $status -eq 0 ] && echo "ok    every project Grok bot names -Dswift=false, tools/check.sh, --test-filter, refAllDecls, and worktree"
exit $status
