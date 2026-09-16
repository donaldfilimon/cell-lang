# Todo

## Close residuals after the 2026-09-16 four-plan landing

- [x] Docs honesty: README gate stage count, SPEC 12 optional/Result rows, FEATURES inspected revision, `examples/future/result.cell` header, leaks README fixture count
- [x] TYPE-02: refuse unknown type names (`examples/rejected/unknown_type.cell` currently-rejected)
- [x] `cell test`/`cell run`: aborting child does not pop Crash Reporter; exit 134 / SIGABRT kept
- [x] R16 outer-while-var leak via `after_loop` (`loop_cross.cell` LIVE=0)
- [x] TYPE-05: `()` in type position as a return type
- [x] LEX-02: decode `\n \t \r \\ \" \0`
- [x] R16 nested partial-field sibling drop
- [x] R16 field moved on only one branch
- [x] Int8/Int16/UInt8/UInt16/UInt32 primitives
- [x] Gate `tools/check.sh` verdict clean on merged HEAD (`a26f8b8`): clean, 559 tests
