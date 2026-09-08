#!/bin/sh
# Verify that every documented "enforced rules" list agrees with the ONE
# authority: src/cell/borrowck.zig's module header.
#
# WHY THIS EXISTS. On 2026-09-08 the enforced-rule list was found stale in SIX
# places in a single session: AGENTS.md, CLAUDE.md, three separate lists inside
# docs/SPEC.md that disagreed with each other, and README.md, whose version
# advertised itself as "read off src/cell/borrowck.zig's own header rather than
# from memory" while omitting four rules and contradicting itself ten lines
# later. Each was corrected by hand, and two went stale AGAIN within the hour
# because a rule landed in between. Six is not six accidents; it is a copy of a
# fact kept in seven places with nothing keeping them equal.
#
# Understating what the borrow checker enforces is not a harmless direction: it
# invites re-implementing a rule that already exists, and it undersells the one
# claim this project is careful about.
#
# WHAT THIS CHECKS, and what it deliberately does not. It asks, per FILE,
# whether every rule the header names is mentioned ANYWHERE in that document.
# It does not check that a specific list is complete, does not check order, and
# does not object to a document naming MORE rules than the header does, since a
# document may legitimately discuss a designed-but-unimplemented rule beside the
# enforced ones.
#
# That is weaker than checking each list, and the weakness is deliberate: rule
# lists WRAP across lines in Markdown, so a line-scoped check reported drift on
# correct lists and on prose that merely mentioned several rules. A check that
# cries wolf gets disabled. This one catches the failure that actually happened
# six times in one session, a rule landing in borrowck.zig and being documented
# nowhere, and it is honest that a rule mentioned only in prose will satisfy it.
#
# FALSIFIED BEFORE BEING TRUSTED, in both directions, because a check that
# cannot fail is worth nothing: deleting R18 from README.md reports drift and
# exits 1, and adding a rule to the header that no document mentions reports
# drift in all four and exits 1. An unmodified tree exits 0. The first version
# of this script was WORSE than useless: `<(...)` is a bashism, every
# comparison errored under `#!/bin/sh`, and it printed "ok" and exited 0 anyway.
# It manufactured exactly the false green this repository keeps recording.
#
# Exit 0 clean, 1 on drift, 2 on a setup problem.

cd "$(dirname "$0")/.." || exit 2
HEADER=src/cell/borrowck.zig
[ -f "$HEADER" ] || { echo "check-rule-lists: no $HEADER"; exit 2; }

# The authority: R-tokens inside borrowck.zig's leading `//!` block.
canon=$(sed -n '/^\/\/!/p' "$HEADER" \
  | sed -n '1,/plus ONE clause/p' \
  | grep -oE 'R[0-9]+(\.[a-z]|[a-z])?' | sort -u)

[ -n "$canon" ] || { echo "check-rule-lists: parsed no rules from $HEADER"; exit 2; }
canon=$(printf '%s' "$canon" | tr '\n' ' ')
echo "authority ($HEADER): $canon"

status=0
for doc in README.md AGENTS.md CLAUDE.md docs/SPEC.md; do
    [ -f "$doc" ] || continue
    have=" $(grep -oE 'R[0-9]+(\.[a-z]|[a-z])?' "$doc" | sort -u | tr '\n' ' ')"
    missing=""
    for r in $canon; do
        case "$have" in
            *" $r "*) ;;
            *) missing="$missing $r" ;;
        esac
    done
    if [ -n "$(printf '%s' "$missing" | tr -d ' ')" ]; then
        echo "DRIFT $doc: never mentions:$missing"
        status=1
    fi
done

[ $status -eq 0 ] && echo "ok    every document mentions every enforced rule"
exit $status
