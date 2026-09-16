#!/bin/sh
# Drive tools/check-grok-bots.sh on the real path: live tree must pass,
# a copy that drops a required token or overlay must fail closed.
#
# This is the unit for the shipped check, not a reimplementation of it.
# Exit 0 only if every assertion below holds.

set -u
cd "$(dirname "$0")/../.." || exit 2
repo_dir=$(pwd)
check=$repo_dir/tools/check-grok-bots.sh
[ -f "$check" ] || { echo "test-grok-bots: no $check"; exit 2; }

test_tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$test_tmp"' EXIT
fails=0

fail() {
    echo "FAIL $*"
    fails=$((fails + 1))
}

pass() {
    echo "ok    $*"
}

# Prove the harness itself fails closed before trusting later assertions.
if sh -ec 'false; printf "unreachable\n"'; then
    echo "assertion harness did not stop on failure" >&2
    exit 1
fi

# 1. Live tree: the shipped check against this checkout.
live_log=$test_tmp/live.log
sh "$check" > "$live_log" 2>&1
live_status=$?
if [ "$live_status" -eq 0 ]; then
    pass "live tools/check-grok-bots.sh exits 0"
else
    fail "live check exited $live_status (want 0); $(tail -3 "$live_log")"
fi
grep -q 'scanning:' "$live_log" || fail "live log does not name scanning"
grep -qF '.grok/agents/implementer.md' "$live_log" || fail "live log does not name .grok/agents/implementer.md"
grep -qF '.grok/personas/implementer.toml' "$live_log" || fail "live log does not name .grok/personas/implementer.toml"
grep -qF '.grok/skills/cell-lang/SKILL.md' "$live_log" || fail "live log does not name .grok/skills/cell-lang/SKILL.md"
grep -qF -- '-Dswift=false' "$live_log" || fail "live log has no -Dswift=false hit"
grep -qF -- 'tools/check.sh' "$live_log" || fail "live log has no tools/check.sh hit"
grep -qF -- '--test-filter' "$live_log" || fail "live log has no --test-filter hit"
grep -qF -- 'refAllDecls' "$live_log" || fail "live log has no refAllDecls hit"
grep -qF -- 'worktree' "$live_log" || fail "live log has no worktree hit"

# Fixture tree: copy the live .grok overlays so mutations hit the same
# files the check actually reads, not a re-typed stand-in.
fixture=$test_tmp/tree
mkdir -p "$fixture"
cp -R "$repo_dir/.grok" "$fixture/.grok"

# 2. Drop -Dswift=false from the implementer agent.
agent=$fixture/.grok/agents/implementer.md
cp "$repo_dir/.grok/agents/implementer.md" "$agent"
# BSD sed: rewrite the token so grep -F cannot see it.
sed 's/-Dswift=false/-Dswift=true/' "$repo_dir/.grok/agents/implementer.md" > "$agent"
drop_log=$test_tmp/drop-swift.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT .grok/agents/implementer.md: missing -Dswift=false' "$drop_log"; then
    pass "dropping -Dswift=false from implementer.md exits 1"
else
    fail "drop -Dswift=false: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi
cp "$repo_dir/.grok/agents/implementer.md" "$agent"

# 3. Drop tools/check.sh from the persona.
persona=$fixture/.grok/personas/implementer.toml
sed 's|tools/check.sh|tools/not-the-gate.sh|' "$repo_dir/.grok/personas/implementer.toml" > "$persona"
drop_log=$test_tmp/drop-gate.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT .grok/personas/implementer.toml: missing tools/check.sh' "$drop_log"; then
    pass "dropping tools/check.sh from implementer.toml exits 1"
else
    fail "drop tools/check.sh: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi
cp "$repo_dir/.grok/personas/implementer.toml" "$persona"

# 4. Drop --test-filter from the skill.
skill=$fixture/.grok/skills/cell-lang/SKILL.md
sed 's/--test-filter/--not-a-filter/' "$repo_dir/.grok/skills/cell-lang/SKILL.md" > "$skill"
drop_log=$test_tmp/drop-filter.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT .grok/skills/cell-lang/SKILL.md: missing --test-filter' "$drop_log"; then
    pass "dropping --test-filter from SKILL.md exits 1"
else
    fail "drop --test-filter: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi
cp "$repo_dir/.grok/skills/cell-lang/SKILL.md" "$skill"

# 4b. Drop refAllDecls from the always-on rule.
rule=$fixture/.grok/rules/cell-gate.md
sed 's/refAllDecls/notAllDecls/' "$repo_dir/.grok/rules/cell-gate.md" > "$rule"
drop_log=$test_tmp/drop-ref.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT .grok/rules/cell-gate.md: missing refAllDecls' "$drop_log"; then
    pass "dropping refAllDecls from cell-gate.md exits 1"
else
    fail "drop refAllDecls: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi
cp "$repo_dir/.grok/rules/cell-gate.md" "$rule"

# 4c. Drop worktree from the implementer agent.
sed 's/worktree/scratch-copy/g' "$repo_dir/.grok/agents/implementer.md" > "$agent"
drop_log=$test_tmp/drop-worktree.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT .grok/agents/implementer.md: missing worktree' "$drop_log"; then
    pass "dropping worktree from implementer.md exits 1"
else
    fail "drop worktree: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi
cp "$repo_dir/.grok/agents/implementer.md" "$agent"

# 5. Delete the required implementer overlay.
rm -f "$fixture/.grok/agents/implementer.md"
drop_log=$test_tmp/drop-overlay.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -qF 'DRIFT missing required overlay: .grok/agents/implementer.md' "$drop_log"; then
    pass "deleting implementer.md exits 1"
else
    fail "delete implementer.md: exit $drop_status, $(grep DRIFT "$drop_log" | tr '\n' ';')"
fi

# 6. Empty .grok tree.
rm -rf "$fixture/.grok"
mkdir -p "$fixture/.grok"
drop_log=$test_tmp/empty.log
CELL_GROK_BOTS_ROOT=$fixture sh "$check" > "$drop_log" 2>&1
drop_status=$?
if [ "$drop_status" -eq 1 ] && grep -q 'DRIFT' "$drop_log"; then
    pass "empty .grok tree exits 1"
else
    fail "empty tree: exit $drop_status, log=$(cat "$drop_log")"
fi

if [ "$fails" -ne 0 ]; then
    echo "$fails FAILURE(S)"
    exit 1
fi
echo "ok    tools/check-grok-bots.sh fails closed on the real script"
exit 0
