# lain's own spec mirror: drift notes (optional)

**About lain's own repo only.** Local development rules are in `CLAUDE.md` ("one spec file per
code file at the mirrored path"; seams tagged, not moved). Nothing here is planned work. It is
what the 2026-08-04 draft of `planning/specs/spec-naming-guard.md` measured about our tree,
refreshed 2026-09-11, so it is not lost now that that spec is about target projects.

## Quick fix, standalone

Five specs describe a constant whose mirror is a different file:

- `spec/lain/context_spec.rb` describes `Lain::Workspace`
- `spec/lain/approval_spec.rb` describes `Lain::Approval::Queue`
- `spec/lain/friction_spec.rb` describes `Lain::Friction::Report`
- `spec/lain/oracle_spec.rb` describes `Lain::Oracle::Definition`
- `spec/lain/plan_spec.rb` describes `Lain::Plan::Document`

Each wants a move to its constant's mirror path, or a real subject at the path it holds.

## Measured 2026-09-11

| Measure | Count |
|---|---|
| Spec files | 652 (487 on 2026-08-04) |
| `lib/**/*.rb` files | 690 |
| lib files with a spec at the mirrored path | 517 (173 without) |
| Specs with no lib file at the mirrored path | 135 |
| Files carrying `:seam` | 80, of which 32 mix unit and seam examples |
| String `describe` | 103 |

The 135 break down as:
- 21 top-level guard and meta specs
- 24 in `spec/lain/seams/`
- 13 in `spec/lain/rust/`
- 3 in `spec/spikes/`, 3 in `spec/integration/provider/`, 2 in `spec/plugin/`
- 69 inside `spec/lain/**`, of which 36 are one-suffix siblings of an existing lib file

43 of the 135 were added after 2026-08-04.

Nothing in the tree checks the mirror today. `spec/spec_discipline_spec.rb` and
`spec/repo_as_fixture_spec.rb` guard other things.
