## Conventions this plan must honour

This is the Lain repo. Its CLAUDE.md holds the binding rules; a plan must not ask a card to break them.

Plans live in `planning/` (or `planning/specs/` for a design), named `<slug>.md`. The default `commit-mode` is commits directly on `main`, in logical chunks, with terse messages and no trailers.

The review panel is the Ruby roster: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman and Aaron Patterson. Add the Rust roster for a card that touches `ext/` or `crates/`.

House rules a card author must not violate:

- A new lib file and its spec land in the same commit, so the card that adds one names both in its Files.
- Cards that edit the same shared file must be sequenced, not parallel.
- Comments explain WHY only. No ticket or card ids in comments or commit messages.
- Only the frontend writes to `$stdout` or `$stderr`.
