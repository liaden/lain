# Lua tooling: linting, formatting, and where the nvim test story goes

> ⚠️ **LLM-generated synthesis** (Claude, 2026-08-04). The measurements in §2 and §3 were run on
> this machine against this repo and the output is pasted verbatim. The ecosystem survey in §4 is
> from upstream docs and issue trackers, cited inline. The recommendations are Claude's.

Split out of `planning/specs/chunk-review-surface.md`, where this began as one card (T27) and was
deferred: the review chunk is already 28 cards, and lua tooling is repo hygiene riding on it rather
than part of it.

**This is expected to grow.** The nvim frontend is where the UI/UX work lands, and each surface
added (review, status, whatever follows) widens the lua and widens what needs testing. Treating it
as a one-off install would be wrong; the point of this doc is that the lua surface gets its own
quality story, sized to what it is becoming rather than what it is today.

## 1. The gap, measured

```
lib/lain/frontend/neovim/runtime.lua   1359 lines
plugin/nvim/lua/lain/init.lua           265
plugin/nvim/lua/lain/config.lua          56
plugin/nvim/plugin/lain.lua              14
                                       ----
                                       1694 lines
```

Shell gets `shellcheck`. Rust gets `cargo-fmt`, `cargo-clippy`, `cargo-test`, `cargo-deny`. Ruby
gets `ruby-checks` and `yard-lint`. **Lua gets nothing**, in `.pre-commit-config.yaml` or anywhere
else.

Testing is better than that reads. 55 examples across `spec/lain/frontend/neovim_runtime_spec.rb`
and `spec/plugin/nvim_plugin_spec.rb` drive a real headless nvim, and the full `:nvim` set is 97
examples. What is missing is any check that a *new* entry point acquires a test, and any lint at all.

## 2. Linter: selene, not luacheck

Both installed and run against the real tree on 2026-08-04.

**selene 0.31.0** installed as a single static Rust binary, `cargo install selene`, first try. Out
of the box it reports 200 errors, all of them `vim` being undefined. Seven lines of config fixes
that:

```toml
# neovim.toml
[selene]
base = "lua51"
name = "neovim"

[vim]
any = true

[jit]
any = true
```

```
# selene lib/lain/frontend/neovim/runtime.lua
Results:
0 errors
13 warnings
0 parse errors
```

Twelve of the 13 are `global_usage` on the deliberate `_G.__lain` namespace (silence via config);
one is `multiple_statements`, a style nit at `runtime.lua:856`. **The `plugin/` tree is completely
clean: 0 errors, 0 warnings.**

**luacheck 1.2.0 failed three ways on this machine.**

1. Under the default `lua` (Homebrew, 5.5.0): `attempt to assign to const variable 'field_name'` in
   `luacheck/standards.lua:134`. Lua 5.5 introduced `const` and luacheck assigns to one.
2. Homebrew's `lua@5.4` formula ships `lua-5.5`, `lua5.5`, `luac-5.5` in its `bin/`. There is no
   real 5.4 to fall back to.
3. Under luajit (5.1): cannot load `lfs.so`. LuaFileSystem's native module was not built for it.

luacheck needs a working lua, luarocks, and native modules. selene needs none of that. On this
machine it is not a close call.

### What selene actually buys

Nothing on the code that exists today, and that matters to say plainly. Its value is preventing a
specific class of regression, which a probe measured directly. Two modules each declaring
`named_buf`, concatenated into one chunk (the shape
`planning/specs/chunk-review-surface.md` T6 introduces):

```
1 error[undefined_variable]: `typo_call` is not defined
1 warning[shadowing]: shadowing variable `named_buf`
1 warning[unused_variable]: named_buf is defined, but never used
1 warning[unused_variable]: unused_helper is assigned a value, but never used
```

A lost reference is an **error**, not a warning. Silent shadowing and a lost reference are exactly
the two failures a "pure refactor, no behavior change" contract cannot detect on its own.

**Caveat that must not be lost:** the probe used top-level locals. If modules are wrapped in
`do … end` to scope their locals, the shadowing lint goes quiet and the hazard does not. Confirm
which shape the runtime split chose before relying on this.

## 3. Formatter: stylua, and the config is not optional

`stylua` 2.5.2, also `cargo install`, also first try. Its defaults are wrong for this repo:

| | changed lines | of |
|---|---|---|
| `runtime.lua`, stylua defaults | **979** | 1359 |
| `runtime.lua`, `indent_type = "Spaces"`, `indent_width = 2` | **133** | 1359 |
| `plugin/nvim/lua/lain/init.lua`, defaults | 292 | 265 |

Stylua indents with tabs by default and this repo's lua uses 2 spaces. Running it unconfigured
produces a 72%-of-file diff that is a formatting disagreement, not a defect. **Write `stylua.toml`
before running it once.**

Sequencing note: a format pass must be its own commit, and must not land under a refactor whose
contract is "no behavior change" — the diff would make that claim unverifiable.

## 4. Testing: the ecosystem, and why lain does not need it yet

Three real options, none installed here.

- [**plenary.nvim**](https://github.com/nvim-lua/plenary.nvim/blob/master/TESTS_README.md) —
  the de-facto standard. Busted-style BDD syntax, runs in-process, supports coroutine tests for
  async nvim APIs.
- [**mini.test**](https://github.com/nvim-mini/mini.test) — deliberately more program-like than
  plenary's DSL. Its distinguishing feature is `MiniTest.new_child_neovim()`: a fresh child nvim per
  test, with helpers for start/stop/restart, emulating typed keys, and **asserting screen state**.
- **vusted** — runs busted inside nvim headlessly, aimed at CI. octo.nvim has an open issue
  ([#1542](https://github.com/pwntester/octo.nvim/issues/1542)) migrating to it from plenary.

**lain already does what mini.test's headline feature does, and slightly better.** Both nvim spec
files spawn a real headless nvim per example and assert through a *second, independent*
`Neovim.attach_unix` connection. That is stronger isolation than plenary's in-process model and
equivalent to mini.test's child-process one, and it keeps the whole suite in one runner.

Adding a lua-native framework today would split the suite in two and duplicate the harness, to buy
fast unit tests for pure lua functions — of which the runtime has very few, since nearly all of it
is buffer manipulation that needs a real editor.

### The one thing lain cannot do

`mini.test`'s **screen-state and screenshot assertions** have no equivalent here. For a surface
built on folds, virtual text, diff alignment and gutter signs, "does it look right" is a real
property and currently only a human can check it. As the UI grows this is the gap most likely to
start hurting, and it is the reason to revisit rather than close this doc.

## 5. Recommended sequence

1. **`selene` + a `neovim.toml` std**, as a `language: system` pre-commit hook scoped `files: \.lua$`.
   Cheapest, and it guards the runtime split specifically.
2. **`stylua.toml` written first, then one format commit**, alone, not under a refactor.
3. **An entry-point coverage sweep**, in the repo's own idiom rather than a percentage: assert every
   `_G.__lain.*` function and every `define(...)` command is named by at least one example, the way
   `spec/plugin/nvim_plugin_spec.rb:293-310` already asserts every command is documented. This is the
   check that makes the lua surface's growth visible.
4. **Revisit `mini.test` when a UI regression ships that a screen assertion would have caught.**
   Not before; the cost is a second test runner.

## 6. Decisions recorded elsewhere, so they are not re-litigated

- **The `:nvim` specs stay in the default suite.** `spec/support/tags.rb:82-87` records that they
  were once opt-in and it hid **97 examples from every pre-commit and CI run**. Measured here: the 2
  review-relevant files are 55 examples in 3.36s, and 3.6s of 104.9s in
  `tmp/parallel_runtime_rspec.log`, well under the 14.7s `worktree_handback_spec.rb` floor that
  actually sets the wall. A lighter inner loop already exists as `--tag '~seam'` and `LAIN_NVIM=0`.
- **A separate `lain-nvim` gem is deferred.** The `frontend/neovim` tree references only 8 lain
  constants outbound, but **13 files outside `frontend/` reach into it**, so the split would be
  circular and would fragment `lib/lain.rb`. `Review::Surface` in the review chunk is the
  port-and-adapter inversion that would make extraction mechanical; judge the gem question on
  whether that port survives its second and third adapters.
