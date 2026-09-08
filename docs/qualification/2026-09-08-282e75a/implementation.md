# Qualification wrapper follow-up

Starting commit: e4c41e56ac36bc08770a21a98028ce5c9edb35ab.
Scope: tools/qualify.py, tools/tests/test_qualify.py, qualification-report plan.

Outside artifact paths now skip only Git pathname lookup; inode checks apply
to tracked-source aliases and pairwise artifact aliases everywhere.
Local reports expose qualification_scope and local_gate_ready, and cannot
assert release_ready until the separate global evaluator exists.

Verification: python3 -m unittest discover -s tools/tests -p test_qualify.py
exited 0; 19 integration tests passed. Negative control ran new outside-path
and clean-release tests against e4c41e5 implementation in a disposable repository:
exit 1, with all three outside-artifact subcases failing and missing local
scope metadata detected. No actual checkout source was used for destructive
fault injection. git diff --check passed.

Independent review approved; committed as 282e75a. Full compiler gate is required separately for the
HIR task; this wrapper-only test run makes no new compiler qualification claim.
