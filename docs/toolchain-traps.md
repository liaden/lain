# Toolchain traps

Verified, not remembered. Every entry cost real debugging, and most share one shape: **a
failure that is not what it looks like.** Before believing a red suite, a missing constant or
a clean green, check the conditions here.

`CLAUDE.md` keeps the headline of each rule; this file keeps the evidence.

## The interpreter, and why a wrong one lies to you

**Do NOT use `~/.rubies/ruby-4.0.6`.** It was built against a home-directory prefix that no longer
exists, so its compiled-in `$LOAD_PATH` is dead and every gem binstub shebang points at nothing:
`bundle` cannot start, and `rake pspec` cannot spawn a worker. Three separate agents lost hours to
this in one chunk, and — the part worth recording — **the obvious workaround is worse than the
breakage**. Forcing it up with `RUBYLIB` puts the stdlib *ahead* of the gems, which shadows the real
`cgi` gem with Ruby 4.0's stripped one and fails the vendored-SDK specs on `CGI.parse`. Two agents
then reported that as a Ruby 4.0 incompatibility and a third as a locked-gem problem. It was none of
those; it was the workaround. If the suite shows failures you did not cause, **check the interpreter
before believing them**.

**TMPDIR must be on the same filesystem as the repo.** `review/deletability_spec.rb` copies a
fixture tree with `cp -al`, and a hard link cannot cross a device. The default `/tmp` is tmpfs here
while `$HOME` is ext4, so all seven of its `BootWithout` examples fail in fixture setup with a bare
`Command failed with exit 1: cp` — which reads like a defect and is not one.

That one fixed path is also **shared mutable state between concurrent agents**, which is a newer
hazard now that an orchestrated chunk routinely has several worktrees running at once. The
isolation, forge, review and frontend specs drive real `git` and real `tmux` against fixture trees
under `$TMPDIR`, so two concurrent full-suite runs collide by construction. The shape is a
`.git/objects/maintenance.lock` ENOENT, a tmux cwd `realpath` miss, **a different example failing
each run**, and green the moment the other process exits. So: **a red `pspec` is not evidence until no other
`parallel_rspec` is live.** Same lesson as the two traps below about scratch filenames and reading
the tree mid-run — check the conditions before believing the failure.

**Ask that question with `pgrep`, not with `ps | grep`.** The obvious spelling over-counts and, worse,
never reaches zero when several agents poll at once: `ps aux | grep '[p]arallel_rspec'` also matches
the *shell command lines* of sibling agents running the same check, so two waiters block each other
forever. Measured: it reported 2 against 1 real run, the extra being a `zsh -c` wrapper. Match the
binary instead, which no wrapper's argv contains:

```bash
pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'   # 0 means genuinely quiet
```

Note a live `nvim`/`ollama` cockpit contends for the same fixtures without being a `parallel_rspec`
process at all, so a zero here is necessary and not sufficient.

**Wait on `pre-commit` too, and for a sharper reason than contention.** The hook **autostashes**
unstaged tracked changes before running the suite against the staged tree, and that stash is
repo-wide: a concurrent reader in another worktree sees its own unstaged edits vanish and reappear,
`git status` disagree with what it just wrote, and untracked-file visibility change under it. Two
agents hit this as a bare `NameError` on a constant they had just added. It is the "do not read the
tree while a suite run is in flight" trap one layer deeper -- it reaches `git status`, not only file
reads. `pgrep -f '[p]re-commit'` before believing a tree that looks wrong, and re-check once quiet.

**`rake compile` needs `clang`** (bindgen wants `libclang`). Switching interpreters invalidates
`rb-sys`'s build fingerprint and forces a rebuild, which is usually when its absence surfaces.

**4.0.6 is a floor, not a preference.** 4.0.5 crashes the VM intermittently under
`rake pspec` — [Bug #22072](https://bugs.ruby-lang.org/issues/22072), `[BUG] should have cvar
cache entry`: `rb_cvar_set` builds a new `RCLASS_CVC_TBL` without copying the old contents, so
in a multi-Ractor process a later class-variable READ finds no cache entry and aborts. Our one
`Ractor.new` (`spec/lain/rust/fuzzy_spec.rb`) is enough to arm it. It surfaces at whatever cvar
gets read first — for us `i18n/config.rb:176`, which is a victim, not the cause. Fixed in 4.0.6,
along with two more Ractor crashes (#22075, #22084).

## OpenSSL

The installed 4.0.6 was configured against Homebrew's OpenSSL (3.6) but has no
RPATH, so at runtime it resolves the system `libcrypto.so.3` (3.0.13) and dies with
`version OPENSSL_3.4.0 not found`. The `LD_LIBRARY_PATH` export in `CLAUDE.md`'s toolchain block is the workaround. The fix is to
rebuild against the system OpenSSL, which is what the runtime linker picks anyway:

```bash
rm -rf ~/.rubies/ruby-4.0.6
ruby-install ruby 4.0.6 -- --with-openssl-dir=/usr    # then: bundle install && rake compile
```

`bundle install` and `gem` write outside the repo, so they need the sandbox disabled.
`ruby-4.0.1` is also installed and is **unusable** for native gems — its `RbConfig` points at
a deleted Homebrew `gmkdir`/`ginstall`. Both it and the OpenSSL breakage above are the same
lesson: keep Homebrew out of the Ruby build.

## RuboCop: `-a` is safe, `-A` is not

Use `rubocop -a`. Do **not** reach for `-A` without reading the diff.

`-a` applies only cops marked `Safe: true`. `-A` also applies unsafe ones, and at least one of
those is actively dangerous here: `Style/RedundantSelfAssignment` (`Safe: false`) flagged
`@timeline = @timeline.append(...)` on the assumption that `append` mutates its receiver, as
`Array#append` does. Ours was pure. The "correction" would have discarded every turn with no
test failure. The method is now `Timeline#commit`, which both reads correctly and sidesteps
the cop.


## Known traps


- Anthropic's stream accumulator is `accumulated_message`, **not** `get_final_message`. The
  stream is single-pass and `accumulated_message` mutates its snapshot.
- On the **streaming** path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
  **String**. `Provider::Anthropic` parses it; nothing above the Provider may see it.
- The system keyword is `system_:` (trailing underscore). Content-block `.type` is a **Symbol**.
- `:model_context_window_exceeded` and `:compaction` are **Beta-only** stop reasons. The
  non-beta enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it
  is non-exhaustive — always have an `else`.
- Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not
  cache, with no error.
- `require "active_support/core_ext"` fails unless `require "active_support"` comes first.
- Constants and nested classes defined **inside a `Data.define(...) do ... end` block** are
  lexically scoped to the enclosing module, not the Data class. Reopen the class after the
  block instead (see `Request::SYSTEM_PREFIX`).
- **A reopened class gets exactly ONE docstring, and it goes on the REOPEN.** The
  `Data.define` assignment above it stays bare. YARD keeps one docstring per namespace and
  **silently discards the rest**, so documenting both loses content with no warning at write
  time; `yard-lint`'s `Documentation/DuplicateNamespaceComment` is what catches it, at commit.
  RuboCop's `Style/Documentation` pulls the other way but does not conflict in practice: it
  fires on the `class` keyword, which the reopen satisfies, and never on the assignment. Two
  shapes both pass, so pick by whether the reopen carries behavior:

  ```ruby
  Anchor = Data.define(:path, :side) do   # bare: no comment above this line
    include Telemetry::Journalable
  end

  # One reviewable position: ... <- the docstring lives HERE
  class Anchor
    SIDES = Review::SIDES.map(&:to_sym).freeze
  end
  ```

  A reopen holding *only* a constant (`JOURNAL_TYPE` and nothing else) is a pure namespace, and
  `Style/Documentation` does not fire on it, so that shape may instead keep its docstring above
  the `Data.define` — but then any explanation of the reopen goes **inside** the class body,
  never above the `class` keyword, or it becomes the second docstring again.
  `lib/lain/review/records.rb` is the pure-namespace case, `lib/lain/review/anchor.rb` and
  `lib/lain/review/hunk.rb` the behavior-carrying one; both shapes are clean under
  `rubocop --only Style/Documentation` and under `yard-lint`, which is the pair to check when
  in doubt.
- **YARD reads `@word` at the start of a comment line as a tag**, so a prose reference to a
  keyword argument wraps into `Warnings/UnknownTag` and fails the commit. Write it inline
  (`the `compose:` note on {Neovim#initialize}`), not as the first token of a wrapped line.
- **`rm .git` before running anything in a COPY of a linked worktree.** A linked worktree's `.git`
  is not a directory, it is a one-line pointer file (`gitdir: /path/to/lain/.git/worktrees/<name>`).
  So `cp -a` of a worktree gives you a copy whose git admin data is still the **original's**, and the
  isolation and forge specs — which drive real `git` against the repo they find — then operate on the
  linked worktree's admin directory rather than the copy's. Observed 2026-08-04: one full-suite run
  from such a copy **deleted the entire copy**. Nothing warns you; the pointer file looks inert.
  Copying a worktree for mutation, bisect or spike work is otherwise reasonable, so the rule is just:
  delete the pointer first, or copy from a real clone.
- **A class named for a top-level constant SHADOWS it for everything lexically inside the
  enclosing namespace.** Defining `Effect::Handler::Sensitivity` made `gate.rb`'s bare
  `Sensitivity::Policy` resolve to `Handler::Sensitivity::Policy` and die — for every caller
  omitting the keyword, i.e. most of them. `Module.nesting` order is not something anyone reasons
  about until it bites; root-qualify (`::Lain::Sensitivity`) at such a site.
- **`pre-commit` exports `GIT_INDEX_FILE` into every hook**, so a spec fixture that shells to
  `git` without scrubbing builds against *lain's* index. It passes in every normal run and fails
  only at commit time. Thirteen examples in one card were exposed; only the one that *commits*
  failed loudly. Scrub the wider set, not just `GIT_DIR` — a command-line `--git-dir` already
  beats that one, while `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_CONFIG_*`
  are the ones that actually redirect git.
- **Mutation harnesses lie by default here, and same-size mutants are the NORM.** `20`→`10`,
  `<=`→`<` and `min_by`→`max_by` are all byte-identical in length, so they collide with
  bootsnap's `(mtime-seconds, size)` iseq key and run against **stale bytecode** while `git diff`
  reads clean. Stamp a unique mtime per write (`File.utime`); assert each mutant applied exactly
  once and still parses; score on the failure COUNT, never a string prefix (`start_with?("4")`
  relabels everything once the example count crosses a digit boundary); use literal fixtures and
  exclude the subject from any corpus that scans it. **Wrap the run in `ensure`** — two agents in
  one chunk died mid-run leaving a live mutant in the tree, caught by re-reading the file rather
  than by any test. And **never park the harness in `spec/support/`**: `spec_helper.rb` globs
  `support/**/*.rb`, so it loads in every worker of every run — one defined `Object#run` globally
  and called `Dir.chdir` at load.

  **And make the harness refuse to score when it measured nothing — refusing a MISSING count is
  only half of it.** Learned twice in one day, 2026-08-19. First half: a run invoked outside its
  toolchain wrapper printed every structural line it was built to print — "mutant applied",
  "restored", "identical: yes" — while every `rspec` line came back EMPTY, because the interpreter
  was wrong. Structure without measurements reads as a pass at a glance, and the blank `examples`
  fields were the only tell. Second half, found when that very guard let its own author through: a
  mutant that broke class *definition* made rspec load nothing and print a perfectly real
  `0 examples, 0 failures`, which satisfies "a count line was produced" and still measures nothing.
  **A mutant that does not load is not a surviving mutant, it is an unrun one**, and it scores as a
  kill unless the harness says otherwise. Third door, and it subsumes the other two: a count line
  that is real, non-zero and **SHORT**. A `SystemExit` or a load-order truncation yields
  `22 examples, 0 failures` where the baseline was 32, which reads as *"the mutant survived"* rather
  than *"half the file never ran"* — the same truncation trap recorded above, wearing a mutation
  harness. **So the rule is not "a count was produced" but "the count EQUALS the baseline count"**;
  capture the baseline once before mutating and compare against it every run. This is the stale-bytecode
  confident-green above, arriving through two more doors — and the same shape as a script that
  asserts its anchor EXISTS without asserting its edit APPLIED, which is how this very paragraph
  failed to land the first time it was written.
- **A generic filename in a shared scratchpad is shared mutable state between concurrent agents.**
  One agent's `run.sh` toolchain wrapper was overwritten by another and silently repointed at a
  *different worktree*; commands kept running and kept passing, against someone else's checkout.
  The measurement it produced — four mutants all "caught" — was taken against unedited files and
  proved nothing, and it surfaced only when a substring replacement failed on a file that had just
  been read. Name scratch files uniquely, and have a runner refuse to start unless a file it owns is
  present (`test -f .handback-T<id>.md || exit 1`). The failure mode is not a crash; it is a
  confident green from the wrong tree.
- **Do not read the tree while a suite run is in flight.** Under `rake pspec` a read can return
  content without edits that are already on disk. Twice in one task this looked exactly like the
  live-mutant signature above; `git status` and a re-read after the run exited confirmed disk was
  correct both times. Re-check after the run, not during.
- **`ls-files` truncates against the PROCESS directory**, so a home-repo surface read from a
  subdirectory is both short and rejoins to the wrong file. `-C <dir>` is the fix; `--full-name`
  is not sufficient.
- **A `SystemExit` inside an example truncates the run and still reports "0 failures".** Thor
  turns a refusal into `exit(1)` and RSpec does not rescue `SystemExit` inside an example — one
  regression took a file from 32 examples to 22 while reporting a clean pass, and the truncation
  point moved with the seed. Under `parallel_rspec` that is indistinguishable from the OOM-kill
  shape above. Pass `debug: true` to any Thor `.start` in a spec, and check the example COUNT.
- **The known load-induced flakes, by name** (2026-08-18; all pass in isolation, all driven by real
  `git`/`tmux`/`nvim` under a loaded box — see the TMPDIR note above before believing any of them):
  `Lain::Frontend::Neovim ... re-attach is idempotent: no duplicate commands, and
  motions/syntax still work`; `Lain::Frontend::Neovim the review thread pane following the cursor
  does not re-place the diff on every further move once it is back`; and
  `isolation/worktree_handback_spec`'s `Dir.mktmpdir` teardown racing git maintenance.

  Added 2026-08-19, and it is a SECOND example in that same file rather than the teardown shape
  above -- which is why the entry above was not enough to recognise it:
  `Lain::Isolation::Worktree::Handback a conflicted path git would otherwise quote names
  "we\nird.txt" as it is on disk, and can conclude it`. Reproduced deliberately (2 of 2 full
  `rake pspec` runs at 14490 examples, 11 `nvim` processes live from other worktrees; run 2 red,
  green in isolation). It surfaced during a chunk that never touched isolation, and cost a card an
  unexplained red it recorded rather than smoothed over -- the cheapest possible outcome, but only
  because the count reconciled (+5, exactly the examples that card added) so truncation was ruled
  out first.

  **The `up_spec` entries are RETIRED as of 2026-08-18 -- both had real causes and both are fixed.**
  Recording that here because a stale "known flake" is worse than none: it reads "not a regression"
  to the next person who sees them red. `threads -- chat args ...` and `leaves the global theme
  untouched ...` were **independent witnesses** of one production defect -- `keep_failed_pane` wrote
  `remain-on-exit` as the LAST thing `configure_session` did, four tmux calls after the pane was
  already running chat, so the fastest crashes died into a window with no option yet and took the
  server with them (9 losses in 20 forced repeats; 0 after). They failed as a RAISE with
  distinguishable messages, `no server running` and `no such session: lain`, which is how the two
  were told apart. `--nvim cockpit splits ...` was a *different* defect: a lossy `split` that made a
  dead pane's cwd read back as the pane's own command string. `leaves the global theme untouched`
  additionally had a second cause -- a scratch `-L` server still sources the user's `tmux.conf`,
  whose background `tpm` rewrites global `status-right` at 300-500ms -- now pinned with
  `-f File::NULL`.

  A live demonstration of why this list is by NAME rather than by line: `buffers_spec.rb:329` was
  recorded by line in an earlier chunk, and one card in this one moved that same example to `:417`
  by adding 88 lines above it.

- **Record a flaky spec by NAME, never by line number.** The four first recorded as
  `cli/up_spec.rb:115`/`:175` drifted within days — one chunk grew that file by 454 lines and the
  live failure moved to `:166`. A stale line number is worse than no list: it reads as "not a
  known flake" and sends the next reader hunting a regression that is not there.
- **Never name a `.toml` explicitly on a `rubocop` command line.** `rubocop -a lib/lain/prompt/default.toml`
  parses it as Ruby and "corrects" it — it silently stripped `format = ` from the prompt format.
  A bare `bundle exec rubocop` (and so `pre-commit run --all-files`) is safe: the default
  `Include` patterns do not match `.toml`. **An `Exclude` entry does not save you** — verified:
  `AllCops: Exclude` governs RuboCop's own file *discovery*, not a path a human hands it
  directly, so the file is still parsed when named. The only defence is not naming it.
