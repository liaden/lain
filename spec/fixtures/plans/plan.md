# A tiny CLI feature, planned in four steps

The author has placed two seams: after `s1` and after `s3`. That makes three
chunks -- `[s1]`, `[s2, s3]`, `[s4]` -- the "author-thinned" density the sweep
runs as-authored. The sweep DERIVES the other two densities from this one plan
by editing seams (P1's `insert_seam`/`remove_seam`), so a single fixture plan
drives all three densities and no arm changes plan content.

## Plan

- [ ] `s1` (S) parse the command-line flags
---
- [ ] `s2` (M) build the request handler
- [ ] `s3` (S) register the subcommand
---
- [ ] `s4` (M) document the usage
