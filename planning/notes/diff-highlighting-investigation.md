# Investigation: language highlighting inside `lain://diff`

Card: C9, chunk "survey dogfood cleanup". Investigation only — ships no code, no spec.

## The recorded decision under test

`lib/lain/frontend/neovim/runtime/00_constants.lua:33-39` (`READONLY_FILETYPES`):

> `lain://diff` reuses nvim's own "diff" filetype so whatever treesitter/syntax a human's
> config attaches to it just works -- no grammar shipped. The other read-only buffers are not
> an existing filetype's shape ... so they share ONE small namespaced regex syntax ... the
> recorded default: a single lain filetype, never per-view filetypes.

The request this card investigates: can code inside a diff hunk (e.g. Ruby keywords on a `+`
line) get language-aware highlighting, not just diff-level coloring (added/removed/header)?
That's a genuinely different feature from what the decision above was defending — per-view
*filetypes* were rejected because the other buffers (journal, timeline, inbox) have no existing
filetype to borrow. `diff` does have one to borrow, and the decision explicitly leans on "just
works." This note checks whether that's actually true for hunk-content injection specifically,
not just for line-type coloring.

## Method

Driven empirically, headless, on this box (`nvim v0.12.4`, `/usr/bin/nvim`). Two configurations:

1. `nvim --headless -u NONE` — stock, zero plugins, isolates what nvim's own bundled runtime
   provides.
2. This machine's real dogfood config (`~/.config/nvim/init.lua`, lazy.nvim, and — notably —
   `~/.config/nvim/lua/plugins/lain.lua`, which is this very project's real nvim wiring), which
   runs `nvim-treesitter` on the `main` branch with `diff` explicitly added to
   `ensure_installed`. This is not a minimal config; it's a config that already goes out of its
   way to ask for diff highlighting, which makes it a fair upper bound on what "a human's
   config" plausibly provides.

Checked via `:set ft=diff` on a synthetic unified diff, then `:syntax` (legacy) and
`vim.treesitter` (Lua) introspection: `synID`/`synIDattr`, `vim.treesitter.get_parser`,
`vim.treesitter.query.get`, and reading the actual installed query files.

## Finding 1 — diff-level coloring already works with zero plugins

`nvim --headless -u NONE` still ships `syntax/diff.vim` and `ftplugin/diff.vim` in
`$VIMRUNTIME` (part of nvim core, not a plugin). With no user config at all:

```
:set ft=diff | syntax on
synIDattr(synID(line, col, 1), "name") →
  diffFile, diffIndexLine, diffOldFile, diffNewFile, diffLine, diffRemoved, diffAdded
```

So the recorded decision's premise — "whatever syntax a human's config attaches just works" —
is true, and true unconditionally, for line-type coloring (added/removed/header/hunk). This
part needs no config at all, let alone treesitter. **This is a non-issue already covered by the
existing design**, confirming (a) for line-level diff coloring.

## Finding 2 — the "diff" treesitter parser is third-party and opt-in, not bundled

nvim core's own bundled treesitter parsers are `markdown`, `markdown_inline`, `lua`, `vim`,
`vimdoc`, `c`, `query` (confirmed via this box's own config comment, which enumerates them for
exactly this reason). `diff` is not among them. A treesitter-based diff parser only exists via
the third-party `nvim-treesitter` plugin, where it is registered `tier = 2` in
`nvim-treesitter/lua/nvim-treesitter/parsers.lua:370-372` — not part of the tier-1/default set,
explicitly requested. On this box it's only present because
`~/.config/nvim/lua/plugins/treesitter.lua` lists `'diff'` in `ensure_installed` by hand.

So a genuinely "normal" user config — one that hasn't specifically thought about diffs — likely
has **no treesitter parser for `diff` at all**, and falls back to Finding 1's legacy syntax.

## Finding 3 — even where the diff parser IS installed, its own query does not inject hunk language

This is the load-bearing finding. Using this box's real config (which does install the `diff`
parser), the installed query set is:

`~/.local/share/nvim/lazy/nvim-treesitter/runtime/queries/diff/injections.scm` (full file, 2 lines):

```scheme
((comment) @injection.content
  (#set! injection.language "comment"))
```

That is the *entire* injection query the upstream grammar (`tree-sitter-grammars/tree-sitter-diff`,
via nvim-treesitter) ships. It injects the `comment` parser into `(comment)` nodes (e.g. diff
metadata comments) and does nothing else. `highlights.scm` (58 lines, also read in full) captures
structural nodes only — `@diff.plus`, `@diff.minus`, `@diff.delta`, `@constant`, `@attribute`,
`@string.special.path`, punctuation — the same category of information the legacy `syntax/diff.vim`
already provides, just via treesitter instead of regex. **Neither query file makes any attempt to
inject the changed file's own language (Ruby, Lua, etc.) into the hunk body.** There is no
extension-to-language mapping anywhere in the shipped grammar or its queries.

So the recorded decision's "just works" claim holds for line-type coloring under treesitter too,
but does **not** extend to hunk-content language injection — and this isn't a config gap on this
box, it's upstream: the grammar most "normal" nvim-treesitter users would reach for doesn't do it
either, because doing it requires knowing the hunk's source language from the diff header text,
which is exactly the kind of thing a static treesitter injection query can't derive without a
predicate keyed on file-path text captured from a sibling node — a nontrivial query even to author,
and not one this grammar's maintainers chose to write.

## Finding 4 — observed fragility, as a secondary data point

Attempting to force the query onto this box's installed `diff.so` parser directly (bypassing the
plugin's own attach path) hit a version mismatch: `Query error ... Invalid node type "change"` —
the currently-compiled parser binary predates a grammar revision the current query file assumes.
This is an artifact of this box's package state (parser installed before a `:TSUpdate`), not a
finding about the design question, but it's worth recording as a live example of the operational
fragility that comes with depending on a third-party grammar's version pairing — exactly the kind
of thing "no grammar shipped" avoids.

## Answering the three outcomes

**(a) Does a normal user config already provide diff injection, making this a non-issue?**
No, not for hunk-content language injection. Line-type diff coloring (add/remove/header) is
already free and universal (Finding 1) — that part of the ask is already satisfied and needs no
work. But the specific enhancement (Ruby-inside-a-diff-hunk highlighting) is not provided by any
config observed here, stock or with treesitter installed and explicitly configured for diffs
(Findings 2-3). A user would need a config that (a) installs a nonstandard tier-2 parser, and
even then (b) gets nothing extra, because the upstream query doesn't do it.

**(b) Does injection require shipping a query file, reversing the recorded decision?**
Yes, for the treesitter route. Since neither nvim core nor the upstream `tree-sitter-diff`
grammar's own queries perform hunk-language injection, the only way to get it via treesitter is
for lain to ship its own override — an `after/queries/diff/injections.scm` in the runtime,
computing the injected language from each hunk's file path. That is a query file shipped by lain,
which is the same category of asset (`00_constants.lua`'s "no grammar shipped") the recorded
decision rejected, even though it's a query rather than a full grammar. It would also create a
hard runtime dependency on the third-party `diff` treesitter parser being installed at all
(Finding 2), which most configs won't have — so shipping the query alone wouldn't even reliably
produce the effect; lain would additionally be telling users to `:TSInstall diff`.

**(c) Can it be done without shipping one?**
Yes, in principle, by not using treesitter's injection system at all: a legacy Vimscript route —
parse the diff header lines lain already writes into the buffer (`diff --git a/lib/foo.rb
b/lib/foo.rb`) at attach time, map the extension to a filetype, and use `:syntax include` /
`:syntax region` to embed that language's *own* existing syntax file inside each hunk's line
range. This reuses "whatever a human's config attaches" the same way the recorded decision
already relies on for the outer `diff` filetype, and ships no grammar and no query file.

But this is real implementation surface, not a small patch: it needs hunk-boundary detection
(multiple hunks per buffer, multiple files per patch), an extension→filetype table (or reuse of
nvim's own `vim.filetype.match`), and — the part most likely to bite — coexistence with
treesitter. Any config that already runs `vim.treesitter.start()` on `FileType diff` (as this
box's dogfood config does, per `~/.config/nvim/lua/plugins/treesitter.lua`) has treesitter
highlighting active on the buffer already; legacy `:syntax region` marks and an active treesitter
highlighter on the same buffer are known to conflict/fight over precedence rather than layer
cleanly. Getting this right without regressing the "just works" case that Finding 1 already
delivers for free is nontrivial design work, not a one-line change.

## Testing constraint

`spec/support/tags.rb:140-150`: the `:nvim` tag set is excluded wholesale
(`config.filter_run_excluding(:nvim) unless NVIM_ENABLED`) whenever `nvim` is not found on
`PATH` (`LAIN_NVIM=0` also disables it explicitly). This is a **filter**, not a per-example
skip — the comment there explains why it has to be (spec-level `around` hooks spawn the editor
before a `before(:each)` skip could fire). The practical consequence for this investigation: any
future spec asserting on diff-hunk highlighting would pass or fail **by machine** — green on a
box with nvim on PATH, silently not-run (not "skipped" in a visible sense beyond the pending
count) on one without. `NVIM_ENABLED` is `false` only when nvim is absent or `LAIN_NVIM=0`; this
box has nvim, so the exclusion wasn't observed directly here, but the mechanism means a reviewer
merging any follow-up work must check the example **count**, not just failures, exactly as
`docs/toolchain-traps.md` already warns for the wider suite.

## Recommendation: defer

Not implement, not close-as-already-available.

- Not close-as-already-available: the specific ask (hunk-content language highlighting) is
  genuinely absent everywhere tested, so this isn't "nothing to do here" — see Finding 1 vs.
  Finding 3 for the distinction between what's already free and what isn't.
- Not implement here: the only path that doesn't reverse the recorded no-grammar-shipped
  decision is (c), the legacy-syntax-region route, and per this card's escalation trigger — "the
  answer is (c) and the implementation looks small, it still does not happen here" — this is
  exactly that case. It does not, on inspection, even look small once hunk-boundary parsing and
  treesitter/legacy-syntax coexistence are accounted for (see the "(c)" analysis above), which is
  further reason for a real card with its own ACs and review rather than a drive-by patch.
- Defer: write a follow-up task card scoped narrowly to route (c) only — legacy
  `:syntax include`/`:syntax region` embedding driven from the diff header lain already writes,
  never a treesitter query file, never a new dependency on the third-party `diff` parser. That
  follow-up card should account for, and test against, the coexistence risk with
  `vim.treesitter.start()` on `FileType diff` in configs (like this box's) that already attach
  treesitter to the buffer, and should treat `spec/support/tags.rb`'s silent `:nvim` exclusion as
  a first-class constraint on its own AC design (e.g. an explicit count assertion, or a
  CI-visible guard that nvim was actually on PATH for the run that claims green), not something
  discovered after the fact.
