# Zig master parity inventory

Status: Partial. Cell does not yet match all Zig language, standard-library,
compiler-command, or target capabilities. This inventory establishes a reproducible
baseline, not feature parity or strict self-hosting.

[Capability qualification contracts](ZIG-CAPABILITY-CONTRACTS.md) map the pinned
discovery inventory to language, builtin, stdlib, command, target and tooling
proof requirements. The [curated coverage map](zig-parity-contracts.json)
accounts for every extracted heading, builtin, std root export and command;
coverage accounting does not establish implementation or semantic reachability.

Run from this checkout:

```sh
zig version
zig env
python3 tools/zig-parity.py > /private/tmp/cell-zig-parity.json
zig test tools/zig-stdlib-inventory.zig
python3 -m unittest discover -s tools/tests -p test_zig_parity.py
```

`zig std` opens local standard-library documentation in a browser. The inventory
reads the installed sources instead, without starting a documentation server.
`--zig /absolute/path/to/zig` selects another installed toolchain.

The JSON has a versioned schema and deterministic ordering. It records the exact
Zig version, executable SHA-256, hashes of every `.zig` file under the selected
standard-library directory, an aggregate manifest hash, the local language
reference hash and headings, compiler help commands, and the verbatim `zig targets`
ZON with its hash. There are no timestamps or absolute source paths in the output.
The extractor source hash identifies the declaration extraction implementation.
Run twice against an unchanged installation to verify byte-for-byte reproducibility.
Missing language-reference files, parser errors, and failed commands abort rather
than producing a plausible incomplete inventory. Output appears only after the
whole inventory succeeds.

Public declarations are extracted with Zig's AST parser, including nested
functions, constants, variables, and quoted identifiers. Comments and string
contents cannot invent declarations. `root` distinguishes root declarations from
nested source declarations; lines and byte offsets locate each declaration in the
hashed file. The collection deliberately includes test-only and otherwise
unreachable declarations. It does **not** resolve reexports, aliases, imports,
compile-time branches, generated types, or semantic reachability. Language-reference
headings likewise are a discovery aid, not an exhaustive list of language features
or builtins. Listed targets are compiler capabilities, not native qualification.

The Zig/Python programs are bootstrap development tooling. They do not satisfy the
requirement that the eventual compiler analysis, LSP, editor, and library algorithms
are implemented in Cell. Each inventory entry still needs a Cell capability mapping,
executable acceptance evidence, and applicable platform qualification before it can
be marked Current. Full parity and self-hosting remain unverified.
