# Debugging notes: nvim ↔ lain interface work

Running log of editor/terminal debugging for the interface integration
(`planning/interface-integration.md`). Newest entries at the bottom; keep the symptom →
diagnosis → fix shape so future sessions can grep by symptom.

## 2026-07-11 — inline mermaid not rendering; snacks "errors" on markdown open

**Symptom.** nvim (0.12.3) freshly restarted inside kitty at `~/dev/lain`; opening
`README.md` shows error notices; mermaid blocks don't render.

**How it was debugged remotely.** The new per-project socket convention paid off
immediately: attached to the running instance from another terminal and pulled state
without touching the session —

```sh
S=$XDG_RUNTIME_DIR/lain/nvim-$(python3 -c "import hashlib;print(hashlib.sha256(b'/home/joel/dev/lain').hexdigest()[:12])").sock
nvim --server $S --remote-expr 'execute("messages")'
nvim --server $S --remote-expr 'luaeval("vim.inspect(require(\"snacks.image.terminal\").env())")'
```

**Diagnosis 1 — the errors are NOT snacks.** `:messages` shows nvim-treesitter crashing:
`attempt to call method 'range' (a nil value)` in `treesitter.lua:197 get_range`, reached
from `nvim-treesitter/query_predicates.lua:141` via markdown injection parsing
(render-markdown triggers the parse; snacks.image would hit the same wall — it *finds*
```mermaid``` fences via the same treesitter injections). Root cause: nvim-treesitter was
pinned to the **frozen `master` branch** (deliberately, to avoid the tree-sitter CLI
dependency — see the old comment in `plugins/treesitter.lua`), and master's query
directive handlers are incompatible with **nvim 0.12's** treesitter internals. Master
worked on 0.11; the 0.11→0.12 upgrade broke it. Nothing about this is
markdown-specific — markdown is just the first filetype whose *injections* exercise the
broken directive path.

**Diagnosis 2 — TERM is clobbered.** Inside kitty, `$TERM` was `xterm-256color` because
`.zshrc` line 10 exports `TERM="xterm-256color" # for tmux` — a legacy line that
overrides every terminal's own TERM (kitty wants `xterm-kitty`; alacritty.toml even sets
`TERM=alacritty` only to have zshrc stomp it). snacks *still* detected kitty
(`KITTY_WINDOW_ID` env survives; `snacks.image.terminal.env()` → `name=kitty,
placeholders=true, supported=true`), so this wasn't the rendering blocker — but
terminfo-dependent behavior is wrong everywhere and tmux sets its own TERM anyway.
Fix: remove the export from `.zshrc`.

**Fix for 1 (the real blocker): migrate nvim-treesitter `master` → `main`.**
Prerequisite `tree-sitter-cli` installed globally via npm (0.26.10) — the original
reason for pinning master is gone now that npm globals are in play (mmdc joined today).
Knock-ons handled in the migration:

- `main` has **no module system**: `require('nvim-treesitter.configs').setup` is gone.
  Parsers install via `require('nvim-treesitter').install(...)`; highlight starts
  per-buffer with `vim.treesitter.start()` from a `FileType` autocmd; indent is
  `indentexpr = v:lua.require'nvim-treesitter'.indentexpr()`.
- `nvim-treesitter-textobjects` also moves to its `main` branch: keymaps become explicit
  `vim.keymap.set` calls into `…textobjects.select/move/swap` functions.
- `nvim-treesitter-endwise` is **master-module-only** → dropped for now (loss: auto
  `end` insertion in Ruby/Lua). Revisit alternatives later.
- Stale `parser/*.so` from the master era live untracked inside the plugin dir and would
  shadow newly installed parsers on the runtimepath — delete them after the branch
  switch.
- nvim 0.12 bundles markdown/markdown_inline/lua/vim/vimdoc/c/query parsers; the
  ensure-list still installs the rest (ruby, rust, …).

**Verified before restart-and-eyeball:** headless open of README.md parses markdown +
injections without error (see below for the exact check).

**Resolution — verified end-to-end, twice.** After the migration (dotfiles `9a352d2`) and
the TERM fix (`1ccf613`): headless README.md parses with injections, no crash; then a
real render check — spawn kitty with nvim at the mermaid block, screenshot the window,
and *look*:

```sh
kitty --detach --title lain-mermaid-test nvim "+86" README.md
sleep 12   # lazy-load + mmdc's chromium spin-up on first render
maim -i $(xdotool search --name lain-mermaid-test | head -1) /tmp/shot.png
```

The README topology diagram renders inline. Joel confirmed the same visually in his own
session. This spawn-screenshot-look loop is the reusable verification for anything
graphics-protocol-shaped that headless nvim can't exercise — keep using it.

**Still open (minor):** a `vim.tbl_flatten is deprecated` notice fires once when opening
markdown. A dozen plugins still reference it (lualine, plenary, neotest, nvim-dap, mason,
orgmode, …) — mostly in compat guards, and most have removed it upstream since the
0.11-era plugin pins. Cosmetic on 0.12; a general `:Lazy update` at leisure clears it.
Same "pinned plugin vs. moving nvim" smell that broke treesitter — don't let the pins age
past the next nvim major.

## 2026-07-11 — regression after `:Lazy update`: mermaid back to raw text

**Symptom.** Immediately after the full plugin update, the same README render check
showed raw fences again. No errors anywhere — `convert.notify = false` by default, so
conversion failures and placement no-ops are both silent.

**Bisect trail** (each step against a fresh spawned kitty+nvim with `--listen`):
1. snacks' image module had **zero commits** between the working pin and post-update
   HEAD — not the suspect, despite being the visible victim.
2. Cache showed the extracted `.chart.mmd` **without** a PNG → conversion never ran on
   attach; retriggering attach converted fine → not mmdc, not config.
3. `:lua require('render-markdown').disable()` → **images appear**. Re-enable → gone.
   Reproducible both directions.
4. Pinning render-markdown back to the "known good" commit did **not** fix it — the
   morning's successful render had simply won a load-order race. The conflict is
   version-independent.

**Mechanism.** snacks.image draws inline images in kitty via **unicode placeholders**,
which encode the image id in the placeholder cells' **foreground color**. Any decoration
another plugin paints over the fence region (render-markdown's code-block background/
conceal extmarks) clobbers that encoding and the image silently vanishes. render-markdown
8.13.0 even ships a health-check acknowledging snacks.image as a conflict (`dcb7751`,
latex case) — the runtime interference just isn't limited to latex.

**Fix (dotfiles `0e23863`).** Stay on latest render-markdown and hand the contested
region over: `opts.code.disable = { 'mermaid' }` (a `string[]` option that exists from
8.13.0; older versions only had `disable_background`, which is not enough). Verified in a
fresh instance: styled headers/tables *and* both README diagrams rendering inline.

**Division of labor now:** render-markdown owns markdown decorations; snacks.image owns
```mermaid``` fences (and image/latex rendering); markdown-preview stays the full-page
browser surface. If a future render-markdown update regresses this again, re-run step 3
above first — it's the 30-second differential.

**Screenshot-driving tip** that made this debuggable: `xdotool key --window $WID z t`
scrolls a spawned nvim without focus games, and `maim -i $WID` captures just that window
— the whole verify loop is scriptable.

**Unrelated find while `ps`-spelunking:** the first RPC probe run (the one that died on
`Dir.tmpdir`) leaked a `nvim --headless --clean --listen /tmp/lain-probe-*.sock` process
parented to PID 1 — its `ensure`-style cleanup lines never ran because the error
propagated before them. Killed. Lesson for probe scripts: wrap spawn/teardown in a real
`begin/ensure`, not top-level statements after the happy path.
