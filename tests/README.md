# tests/

Programs `cell test` runs (`cell test` with no argument reads this
directory). Each is a whole program with its own `main`; `<stem>_host.c`
beside one is its hand-written host. A `// EXPECT-OUTPUT:` line pins its
stdout. Gate stage 14 runs this directory and expects every program to pass.
