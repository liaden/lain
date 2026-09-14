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
reads. Check for a live hook before believing a tree that looks wrong, and re-check once quiet --
with the precise pattern:

```bash
pgrep -cf '[p]re-commit (hook-impl|run)'   # a real hook runs as `pre-commit hook-impl ...`
```

**The bare `pgrep -f '[p]re-commit'` false-matches.** The bracket trick hides only the pattern's own
spelling; any process whose command text holds the plain word matches it. A sibling agent's
background waiter whose echo said "waiting for pre-commit" read as a live hook to every other agent,
and left several reading "busy" for the length of a run (2026-09-11). Match the hook's real argv, and
never put the unbracketed word in a long-running command of your own.

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
- **The same trap sits one layer down, in a copied SUBMODULE checkout.** A submodule's `.git` is a
  pointer file too (`gitdir: ../.git/modules/<name>`), and that admin directory names its checkout
  back in `core.worktree` — which a `cp -a` does not change. So git run in the copy reads the
  original's admin data *and* writes into the original's working tree: the entry above, with a
  second door into it. A legitimate submodule and a copied one differ in exactly one thing, which
  is whether the admin directory names THIS checkout back — a linked worktree says so in its
  `gitdir` file, a submodule in `core.worktree`, and a copy of either answers with somebody else's
  path. `spec/worktree_identity.rb` asks that at suite boot and refuses to run when the answer is
  no; the remedy for a copy you made on purpose is the one above.
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
- **Under starvation the example COUNT can go UP, not just down — and an inflated count is itself
  the tell.** The count rule elsewhere warns that a dead worker, an OOM kill or a `SystemExit`
  reports FEWER examples with zero failures. 2026-08-23 produced the opposite shape twice, from two
  independent agents on a box at load 82-214 with rival `parallel_rspec` runs in flight: a tree
  whose true count was 15209 reported **15217 examples, 28 failures**, and one whose true count was
  15229 reported **15233 examples, 17 failures**. Neither number is evidence; the *movement* of the
  count away from the true one is what says so.
  **`bundle exec rspec --dry-run` is the ground truth for the count.** It collects every example
  without executing any, takes seconds, and is immune to load — so it answers "did a worker die, or
  did the packer double-count?" without paying for a run. Take a dry-run count first, and only then
  read a `pspec` line against it.
- **`rake pspec` can exit 0 while printing `rake aborted!`.** Observed 2026-08-23: the task printed
  `15172 examples, 2 failures` followed by `rake aborted! Command failed with status (1)`, and the
  calling shell still saw exit status **0**. So the exit code is not a gate. **Score a suite run on
  the printed `N examples, M failures` line and nothing else** -- together with the example-COUNT
  rule in CLAUDE.md that is two independent ways a red suite reads green.
- **A forked or out-of-band RSpec runner that never renames `$PROGRAM_NAME` loads zero spec files
  and reports a confident green.** `Configuration#files_or_directories_to_run=` appends the `spec`
  default path only when `$PROGRAM_NAME` basenames to `rspec` -- a `Kernel#fork` of a preloaded
  process, or anything else that drives RSpec's API instead of going through the `rspec`
  executable, keeps whatever argv-zero its parent had. Without the rename the run collects and
  executes nothing and still exits 0: a third way (alongside the two above) that a red suite reads
  green, from a runner that never got as far as loading a single example. The fix goes deeper than
  the file list, though: `CLI::Up::PreFlight` expands a relative executable to an absolute path,
  while `up_spec`'s spy compares the raw `$PROGRAM_NAME` -- so renaming the process to a bare
  `rspec` (needed for the file-loading trick above) broke that comparison and produced 10 examples
  failing in every run, from the rename itself rather than from the suite. A runner built this way
  also wants its own `TMPDIR`/XDG tree per run, for the shared-mutable-state reason given above
  (`:21-29`). Surfaced by `bin/spec-flakes`, a forked whole-suite runner retired 2026-09-12 for an
  unrelated collision (below) -- the script is gone but the mechanism binds any future one built the
  same way.
- **This box's shell is zsh, and `cmd 2>&1 1>/dev/null | sed` does NOT swap descriptors there.**
  zsh's MULTIOS **tees** instead, so a probe written to isolate stderr silently reports stdout's
  content as if it were stderr. Measured 2026-08-23 while checking that a renderer prints its
  "never blank" sentence to stdout: the idiom said stderr, plain file redirection said 0 bytes on
  stderr, and the second answer was the true one. Use file redirection (`cmd >out 2>err`) when the
  question is WHICH stream a thing came out of -- the pipeline idiom is a bash habit and it lies
  here.
- **The interactive shell's `grep` is a function onto `ugrep`, which SKIPS a file it heuristically
  calls binary** — no error, no warning, zero matches. `grep -m1 '^status:'` over every
  `planning/specs/chunk-*.md` reported `chunk-skills-roles-tools.md` as having no status line, and
  line 3 of that file reads `status: done`. The document is valid UTF-8, but `file -b` calls it
  `data` and ugrep 7.8.4 takes that as a reason not to search it; a document was nearly left out of
  an archival move over it. Same family as the zsh idiom above: a confident answer, not an error.
  Pass `-a` whenever a grep's EMPTINESS is what you are about to act on.
- **A `SystemExit` inside an example truncates the run and still reports "0 failures".** Thor
  turns a refusal into `exit(1)` and RSpec does not rescue `SystemExit` inside an example — one
  regression took a file from 32 examples to 22 while reporting a clean pass, and the truncation
  point moved with the seed. Under `parallel_rspec` that is indistinguishable from the OOM-kill
  shape above. Pass `debug: true` to any Thor `.start` in a spec, and check the example COUNT.
- **The known load-induced flakes, by name** (2026-08-18; all pass in isolation, all driven by real
  `git`/`tmux`/`nvim` under a loaded box — see the TMPDIR note above before believing any of them):
  `Lain::Frontend::Neovim the review thread pane following the cursor
  does not re-place the diff on every further move once it is back`; and
  `isolation/worktree_handback_spec`'s `Dir.mktmpdir` teardown racing git maintenance.

  Added 2026-09-11, from a run with two to five agents running rspec at once. Each of these went red
  in a pre-commit or `pspec` run while another suite was live, and passed alone -- run the named
  example by itself on a quiet box before believing any of them:
  `Lain::CLI::Up against a real tmux server --nvim cockpit splits the chat window into an nvim pane
  and a chat pane sharing one socket and one cwd`;
  `Lain::Supervisor as an actor reactor the bounded drain over a mixed fleet an actor's own captured
  Async::TimeoutError is not misread as the drain's bound`;
  `role_prelude_wiring_spec`'s `sends no more than Anthropic's 4 cache_control blocks for a
  long-lived role child`;
  `lain.rb without the compiled extension keeps Ruby's own LoadError message rather than replacing
  it`;
  `the review annotation runtime a buffer that goes away drops the orphaned entry once it has
  settled it, so a reused bufnr inherits nothing`;
  and the vsock harness's `VsockAvailability.available? leaks no descriptor across repeated
  probing`.

  Added 2026-08-28, and it is the one shape this ledger did not yet carry: two examples in
  `spec/lain/frontend/neovim/runtime/62_approval_spec.rb`'s `answering a parked approval in the
  editor, end to end` group fail
  **in isolation** while the same file passes inside a full `pspec` run --
  `resolves one unwrapped call per answerable row, in queue order, for two parked approvals` and
  `carries the wrapped command unwrapped, with the rendered lines unchanged`. Measured at
  `428d662b`: 1 failure on 3 of 3 solo runs of the file, a different example each time, against a
  whole-suite run of the same tree at 0 failures. So the usual reflex is inverted here -- solo is
  the unreliable reading and the suite is the trustworthy one, which is the opposite of what the
  TMPDIR note above trains you to do. Do not take a red from
  `rspec spec/lain/frontend/neovim/runtime/62_approval_spec.rb` as evidence of anything; re-run it
  under the whole suite before believing it, and expect a `pspec` to trip it occasionally too.
  (The group lived in `spec/lain/frontend/neovim_runtime_spec.rb` until 2026-09-14, when that file's
  eighteen groups were split to one spec per runtime lua module. The two example NAMES are
  unchanged, which is why this entry still finds them -- and that is the general rule rather than a
  detail of this one entry: **a path in a flake entry is a convenience, not the key.** When a file
  moves, repoint the path and keep the name. CLAUDE.md's "record a flaky spec by NAME, never by
  line number" is what let this entry survive a split that moved every line in it.)

  Added 2026-08-23: the entry above still under-describes this file. Two MORE of its examples have
  been observed red and green on the same box within minutes, both in the `#continue refuses a
  resolution that is not one` describe block that no entry here names: `Lain::Isolation::Worktree::Handback
  #continue refuses a resolution that is not one can be retried, and concludes once the markers are
  gone` and `... wants all three shapes in order, not any marker-shaped line`. Measured directly:
  the file alone, four consecutive runs, no `parallel_rspec` and no `pre-commit` running, went
  `0, 0, 0, 2` failures; a separate isolated run on the same box reddened the `we\nird.txt` example
  the 2026-08-19 entry already names, which that entry says passes in isolation.

  **So the honest unit here is the FILE, not any example in it.** Treat a red example anywhere in
  `spec/lain/isolation/worktree_handback_spec.rb` as unattributable until it is re-run alone, and do
  NOT conclude "not a known flake" because the particular example name is missing from this list --
  that is the exact misreading the by-name rule was written to prevent, and this file defeats it by
  moving between examples. It builds its own repository under `Dir.mktmpdir` and never touches
  lain's own git admin dir, so the number of worktrees registered in this repo is NOT the cause:
  that hypothesis was tested and rejected 2026-08-23.

- **The `:ollama` live suite has a KNOWN-RED example, and it predates this chunk.**
  `Lain::Provider::Ollama temperature-0 reproducibility produces identical text across three warm
  same-seed runs` (`spec/integration/provider/ollama_spec.rb`) fails on this box: three warm
  same-seed runs at temperature 0 give **three distinct completions**. Measured 2026-08-24 at HEAD
  **and at `f63dae70`**, the commit before the ollama-cloud chunk began — so it is environmental or
  server-side, not a regression from any card. It only runs under `LAIN_OLLAMA=1`, which is why no
  default suite sees it.
  Recorded by NAME so the next person to run the live tier does not read it as something they just
  broke. The honest consequence: **neither ollama arm is currently a determinism-comparable bench
  arm on this machine** — the cloud arm's non-reproducibility is measured and expected
  (`references/ollama/cloud.md`), and the local arm's is a real defect that is still open. Do not
  draw a variance conclusion from either without re-establishing this first.

- **`rubocop -a` rewrites UNTRACKED files too, and there is no copy to restore.** A bare
  `bundle exec rubocop -a` inspects the whole working tree, not just tracked or staged files, so
  scratch scripts, probe specs and anything else sitting untracked in a worktree get autocorrected
  in place. Safe cops only, so behaviour does not change -- but the file is no longer what its
  author left, and an untracked file has no `git checkout` to undo it. Observed 2026-08-24 when a
  lint pass rewrote three of a review agent's probe scripts. Scope the command
  (`bundle exec rubocop lib spec exe`) when the tree holds work you have not committed. This is
  separate from the never-name-a-`.toml` rule above, which is about what gets parsed as Ruby.

  Added 2026-08-24, found by a nine-run `spec:flakes` sweep: `Lain::Tools::ReadFile refusing a read
  that is too large to hand back reads at most a bounded probe of the file it refuses, and never
  slurps it` went red in **1 run of 9** and green in the other eight, on an otherwise quiet box.
  One observation, so the mechanism is not established -- recorded by name now precisely so the
  second sighting is recognised as a second rather than mistaken for a regression.

  **RETIRED 2026-09-12 — `rake spec:flakes` exited 1 on EVERY invocation, and it was the harness,
  not the suite.** `bin/spec-flakes` rewrote `$HOME` and `XDG_*` inside each forked run, which
  collided with the spec group that asserts on `$HOME`: five examples in `Lain::Paths a $HOME that
  is not absolute` (`refuses a HOME of '.'`, `refuses a relative HOME`, `refuses an empty HOME`,
  `guards config_home and cache_home by the same rule`, `accepts a HOME of '/'`) plus
  `Lain::Frontend::Neovim the thread pane's write refusal delivers a nothing-typed write refusal on
  the review rail` failed in **all nine** runs, deterministically. `rake pspec`, which does not
  rewrite `$HOME`, was green at the same commit across three runs. So a red `spec:flakes` was never
  evidence of anything until those six were subtracted, and the tool could never serve as a gate
  while its own isolation fought the specs that assert on the variable it rewrote. Measured
  2026-08-24 during the ollama-cloud chunk; the task and `bin/spec-flakes` were removed rather than
  fixed, because the defect was in the harness's own isolation, not in the six specs it collided
  with — fixing those specs would have hidden the harness's `$HOME`/`XDG_*` rewrite rather than
  correcting it.

  **RETIRED BY EVIDENCE 2026-08-24 — the teardown shape is fixed at the fixture.** `git commit` and
  `git merge` spawn a DETACHED `git maintenance run --auto --quiet --detach` (seen under
  `GIT_TRACE=2`), and that process outlives the example: `Dir.mktmpdir`'s teardown then races it
  and dies on `Errno::ENOENT` under `.git/objects/`, which RSpec blames on whichever example the
  `around` hook was closing. `SeedRepo::PINS` now sets `maintenance.auto=false` and `gc.auto=0` in
  every seeded repo, so no second process exists to race. Measured on one box, same minute, with a
  standalone reproducer: **101 teardown failures in 400 unpinned cycles, 0 in 400 pinned**; either
  pin alone suffices, and both are kept because `maintenance.auto` is git 2.29+. `rerere.enabled=false`
  is pinned with them for hermeticity — it is a common `~/.gitconfig` setting, and leaving it
  ambient made this suite's behaviour depend on whose box it ran on.

  **This retires the teardown shape only.** The `we\nird.txt` example below and the
  `#continue refuses a resolution that is not one` pair above are separate observations that this
  fix does not explain, so the FILE-not-the-example rule above still stands for them.

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

  **`buffers_spec`'s `re-attach is idempotent: no duplicate commands, and motions/syntax still
  work` is RETIRED as of 2026-08-23 — it had a real cause and it is fixed**, and both halves of
  what this list said about it were wrong: it was neither load-induced nor a passer in isolation.
  Measured alone on an idle box it failed **7 of 20** runs, always on one of two values —
  `Expected [1, 0] to eq [2, 0]` (the `]]` motion did not move) and `Expected "" to eq "lainRole"`
  — and a state dump at the failure showed every idempotence claim the example makes still TRUE:
  same `bufnr`, `]]` still buffer-local, `filetype` still `lain`, `lainRole` still defined. Only
  the buffer's CONTENT was wrong: `["(no turns yet)"]` where the example had just injected two
  lines. The example's barrier was `wait_until { bufnr("lain://timeline") != -1 }`, which is a
  real wait for a FIRST attach and **nothing at all for the second** — the buffer is already
  there, which is what re-attach idempotence means — so the newcomer's at-rest prime, posted
  after `#run` returns on the drain thread, landed on top of the injection at a different point
  every run. The fix waits on the newcomer's own `User LainRender` instead. Forced deterministic
  both ways with a gated `Surfaces#prime` (6/6 red before, 6/6 green after); 25/25 green since.
  **The product was not at fault, and the reason is LIVENESS rather than anything about priming.**
  `Frontend::Neovim#run` tears down in an `ensure` — `@channel.close`, the joins, `@rpc.stop` — so
  the first lain's channel is dead before the second attaches: `channel_alive(owner)` is false,
  runtime.lua takes the re-attach path rather than the `{ refused = "owned" }` one, and the at-rest
  prime is the NEW OWNER's. That is the sequential re-attach a human performs (quit lain, start
  another in the same nvim), never a live double attach — which is refused, and refused *because*
  a newcomer's empty prime replacing a running lain's rendered views is one of the three harms
  runtime.lua's head measured. Both halves are pinned by
  `spec/lain/frontend/neovim/runtime_spec.rb`'s "one lain per editor".

  A live demonstration of why this list is by NAME rather than by line: `buffers_spec.rb:329` was
  recorded by line in an earlier chunk, and one card in this one moved that same example to `:417`
  by adding 88 lines above it.

- **Record a flaky spec by NAME, never by line number.** The four first recorded as
  `cli/up_spec.rb:115`/`:175` drifted within days — one chunk grew that file by 454 lines and the
  live failure moved to `:166`. A stale line number is worse than no list: it reads as "not a
  known flake" and sends the next reader hunting a regression that is not there.
- **For a `SpecWatchdog::Stuck`, even the NAME can be unreliable — read past it to the `around`
  chain before trusting it.** `spec/support/watchdog.rb` is deliberately the OUTERMOST `around`
  (so it can see a hang in an editor spawn, not just in an example body), which means it also
  wraps every FILE's own `around` blocks — shared fixture setup that runs before every example in
  that file, whether or not that example's own body touches the thing which stalled. A strike
  during that setup still reports the example that happened to be current, by exact name and
  line, same as any other `Stuck`.
  Two names were chased as flaky commit-hook failures with nothing in their own bodies that could
  hang: `spec/lain/cli/command/review_spec.rb`'s `answers its own usage when no target was named`
  (its body calls no git at all) and `spec/lain/cli/review_spec.rb`'s `reviews against the ref
  --base names instead, when it is given one`. Neither is a bad test, and neither reproduced by
  name. What DID reproduce, 2026-08-23, twice in one hunt, is the MECHANISM: on their immediate
  NEIGHBOURS in the same describe blocks, driving the identical shared code:
  `command/review_spec.rb`'s `around` block does `git branch -M main` before every example in the
  file, and it stalled 61.4s inside `Mixlib::ShellOut::Unix#configure_parent_process_file_descriptors`;
  `cli/review_spec.rb`'s `LocalBranch#merge_base!` — the same call target 2's own body drives —
  stalled 61.3s inside `IO.select`. Both were caught live as `SpecWatchdog::Stuck` naming the
  wrong example. The trigger needs no other agent: `git commit` runs `rake check`'s `multitask`,
  fanning `rubocop` over the whole repo and `parallel_rspec` (one worker per core) out together,
  which is real structural contention on its own. **So a `Stuck` on one example is evidence
  against that example's FILE and its shared fixtures, not against that example's own body** —
  the same "the honest unit is the FILE" lesson `worktree_handback_spec.rb` already taught above,
  arriving through the watchdog instead of through leaked state.
  Fixed the same day, in the watchdog itself rather than in either spec: `SpecWatchdog::Sentry::Starvation`
  now checks CPU time consumed against wall time and the box's own 1-minute load average, and a
  `Stuck` report leads with "STARVED, not necessarily stuck" instead of "This is a hang, not
  slowness" when the numbers say the process was never scheduled rather than genuinely wedged —
  still loud, still dumps every thread, just honestly labelled. See `spec/support_watchdog_spec.rb`.
- **Never name a `.toml` explicitly on a `rubocop` command line.** `rubocop -a lib/lain/prompt/default.toml`
  parses it as Ruby and "corrects" it — it silently stripped `format = ` from the prompt format.
  A bare `bundle exec rubocop` (and so `pre-commit run --all-files`) is safe: the default
  `Include` patterns do not match `.toml`. **An `Exclude` entry does not save you** — verified:
  `AllCops: Exclude` governs RuboCop's own file *discovery*, not a path a human hands it
  directly, so the file is still parsed when named. The only defence is not naming it.

  **The rule is general, not `.toml`-specific** (2026-08-22): naming `docs/toolchain-traps.md`
  on a `rubocop` command line makes it parse THIS FILE as Ruby and report offenses in the
  prose. Harmless only because no `-a` was passed. Name Ruby files, and nothing else.
- **A `let` read from inside `Sync` deadlocks the reactor, and it looks like a hang in your subject.**
  RSpec memoizes a `let` under a `Mutex`. A `Mutex` acquired inside an `Async` task is owned by the
  **fiber**, not by the thread — so the *first* read of a `let` from inside a `Sync` block parks the
  reactor's fiber on a lock the example's own fiber is holding, and neither can move. What you see
  is the example sitting at ~0% CPU until `spec/support/watchdog.rb` fires at 30s, with a stack
  ending in `IO::Event::Selector::URing#select` under `Async::Scheduler#run` — which reads as "my
  async subject wedged", not as "RSpec's memoization did". It is the same fiber-ownership branch
  that trap-hunt cost hours to find in the editor specs; found again 2026-08-22 in `ToolDelivery`'s
  spec, and reproduced *by accident* by the reviewer's own probe before the fix was applied — a
  `Mutex` locked by the example fiber answers `owned? == false` when a sibling fiber on the same
  thread asks. A read of an **already-memoized** `let` never takes the lock, so the whole fix is to
  force them before the reactor opens:

  ```ruby
  before { [response, timeline, session, snapshots, journal] }   # then Sync freely
  ```

  The tell that separates it from a genuine hang: the same example passes when its `let`s are
  turned into plain locals. If a spec drives `Sync`/`Async` at all, force every `let` it touches.
- **`Async::Task#wait` on a CANCELLED task does not raise**, so `expect { run.wait }.to raise_error`
  asserts nothing at all. Measured on async 2.42.0, 2026-08-22: after `run.stop`, `run.wait` returns
  `nil` with `run.status == :cancelled` and no exception — the task's own handler has already
  absorbed the `Async::Cancel`. An example written to prove "the interrupt still ended the run"
  therefore passes for the wrong reason, and keeps passing if the interrupt stops working. Assert
  the *state* and the *consequence* instead — `expect(run).to be_cancelled`, plus something the run
  would have done had it continued (a turn that is absent, a response never requested).
  Relatedly, `Task#defer_stop` is a deprecated alias for `#defer_cancel` in 2.42, and it guarantees
  exactly **one** deferral: `#cancel` defers only while its tri-state guard reads `false`, and a
  second cancel arriving inside the region falls through to an immediate `Fiber.scheduler.raise`.
  A `defer_stop` region is a shield against *an* interrupt, never against a storm of them.

- **`remain-on-exit` sent as a SECOND tmux invocation loses the race against a pane that dies
  immediately — 6 losses in 20.** tmux answers `new-window` the moment its SERVER accepts the
  request, and it reaps a pane on its own event loop afterwards, so a `set-window-option -t ...
  remain-on-exit failed` sent after the open arrives at a window that is sometimes already gone.
  Measured 2026-08-28 on tmux 3.7b through the real `Mixlib::ShellOut` path, 20 windows running
  `exit 42`: the open took 8-16ms and the option another 8-18ms, and **6 of 20 read back no
  corpse at all**. Chained into the SAME command list —
  `new-window ... <command> ';' set-window-option -t =name remain-on-exit failed` as one argv —
  the loss is **0 in 30**, because tmux runs a command list to completion before it processes
  the pane's death. A raw shell loop reproduces the race perfectly well — 4/30, 5/30 and 3/30 over
  three runs, about 13%, comparable to the Mixlib path's 6/20 — so any harness will do. What will
  NOT show it is measuring the wrong thing: asking whether `set-window-option` itself was *refused*
  answers 0/30 even while a third of the corpses are already gone, because on a window tmux has
  destroyed the option call still succeeds against the session. Measure the status you can read
  back, not the exit code of the call that was supposed to preserve it.

  Note what this means for the older entry above about `keep_failed_pane` writing `remain-on-exit`
  last: ordering the option EARLIER was the right fix there and is not sufficient here. `Up`'s
  chat pane runs a REPL that lives for minutes; a fleet window runs a command that can exit in
  under a millisecond, and nothing short of the same invocation is early enough.

  Chaining costs one thing: a non-zero exit no longer says which half failed. `-P` recovers it
  for free — tmux prints the new window's target only when `new-window` itself ran, so an empty
  stdout beside a non-zero exit means the OPEN failed (be loud) and a printed target means only
  the option was refused, which is what a tmux older than 3.2 does with the `failed` value.

- **`display-message -p` answers for the CURRENT pane when its target does not exist, and exits
  0.** Asked about a window that is gone, `tmux display-message -p -t 'lain:=nope'
  '#{pane_dead}:#{pane_dead_status}'` does not fail and does not answer empty: measured on 3.7b it
  printed `1:42` — *another* window's corpse status — at exit 0. Any liveness or exit-status check
  built on it will confidently report an unrelated pane's fate as the one you asked about.
  `list-panes -t <target> -F ...` refuses instead (`can't find window: nope`, exit 1), and that
  refusal is the honest answer; use it for every question about a specific window's pane.

  Two more edges on the same call, both real: `Mixlib::ShellOut#exitstatus` is `@status&.exitstatus`
  and so is **nil for a signalled client**, where `.zero?` raises `NoMethodError` out of whatever
  is asking — use `&.zero?`. And parse the answer so it fails CLOSED (`survived = dead == "0"`,
  not `dead != "1"`): an unreadable reply becoming "healthy" is the one direction a liveness check
  must never round toward.

  Related, and it bites every scratch-socket spec in this repo: **`kill-server` does not unlink the
  socket.** `/tmp/tmux-1000/` held 13,668 leftover `*-spec-*` inodes when this was found. Unlink
  `File.join(ENV.fetch("TMUX_TMPDIR", "/tmp"), "tmux-#{Process.uid}", socket)` in the same `ensure`
  that kills the server.

- **A tmux pane inherits the spec runner's PATH, so a pane spec can pass on a binary production
  never sees.** tmux hands a new pane the environment of the SERVER it runs under — with exactly
  one carve-out among the names you set. Measured on 3.7b, setting the same name on the server and
  on the client that asks for the window (`TERM`, `TMUX` and `TMUX_PANE` are outside this: tmux
  synthesises those rather than inheriting them from either side):

  | set on | the pane reads |
  |---|---|
  | server vs client `PATH` | **the CLIENT's** |
  | server vs client `LAIN_MODEL` | the SERVER's |
  | server-only `LAIN_PREFLIGHT` | the SERVER's |
  | `new-window -e LAIN_MODEL=…` | the `-e` value |

  A spec is the client. So a pane opened from the suite gets `bundle exec`'s PATH, which carries
  the gem bindir, which carries an **installed** `lain` — and the bare `lain watch <digest>` a
  fleet window used to run therefore worked in every spec while dying of status 127 in a real
  cockpit, where nothing has put lain on a pane's non-interactive `$SHELL -c` PATH. That defect
  survived the whole life of the feature with green specs sitting over it.

  So: **any spec that opens a real pane and asserts on what the command did must first drop, from
  `ENV["PATH"]`, every directory holding the executable under test** — on the server it starts
  *and* on the client it shells from, since the two disagree. `fleet_windows_spec.rb`'s
  `#lainless_path` is the worked example. Without it the spec is exercising a binary the product
  cannot reach, and the greener it looks the less it means.

  Two corollaries for `Up::PaneCommand`. Its `gem_exports` PATH re-export stays necessary and
  correct — a client that never ran chruby hands a pane the same half-PATH a stale server does —
  but the reason is the carve-out, not the server's staleness. And its "there is no pushing one in
  at spawn time" is too strong: the shell-prefix form that claim was measured against really does
  not reach the pane, but `new-window -e NAME=value` does — though `-e` can only SET, never unset,
  so it could not carry the recipe's `unset` preamble even if every surface grew the parameter.

## CI is a different box, and both of these were green here and red there

Two examples went red on every GitHub runner while passing on every developer machine, for three
consecutive pushes (2026-08-24, 2026-08-25). Neither was a flake and neither was a regression: both
were **new specs that had never run anywhere but a workstation**, each carrying an unstated
assumption about the environment. The runner image was identical across the last green run and the
first red one — checked, not assumed — so "CI changed under us" was ruled out before anything else.

- **A spec that leaves `$XDG_*` to the ambient environment tests nothing on a box that exports one.**
  `Lain::Paths a $HOME that is not absolute guards config_home and cache_home by the same rule`
  overrode only `HOME`. But {Lain::Paths#xdg_dir} returns an absolute `$XDG_CONFIG_HOME` **verbatim**
  and never consults `#home` at all, so the `$HOME` guard it was asserting is unreachable whenever
  that variable is set — the accessor answers instead of refusing. Runners export it; this box does
  not. Reproduce the CI failure locally in one line:

  ```bash
  XDG_CONFIG_HOME=/tmp/cfg bundle exec rspec spec/lain/paths_spec.rb   # red, everywhere
  ```

  The fix is `with_hostile_home`, which clears `XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_STATE_HOME`
  alongside setting `HOME`. **Any example asserting the `$HOME` fallback must clear the variable
  that shadows it**, or it is vacuous on half the machines that run it. This is the same collision
  `bin/spec-flakes` hit from the other direction (see the retired `spec:flakes` note above): there
  the harness *set* `$HOME` and `XDG_*` and five of these examples went red in all nine runs.

- **tmux 3.4 misreports `#{pane_current_path}`, inserting a backslash before every `$`.** A pane
  sitting in `a$b` formats as `a\$b`, while `readlink /proc/<pane_pid>/cwd` — where that pane's
  shell demonstrably *is* — says `a$b`. Measured directly in an `ubuntu:24.04` container against
  the plugin itself; the pane's real cwd is correct, so this is a **reporting** defect, not a
  session-creation one. Fixed upstream by 3.7. Ubuntu 24.04 LTS ships 3.4, which is what
  `.github/actions/spec-binaries` installs from apt, so **every runner has it and no dev box does**.

  The consequence for `plugin/tmux`: the resolver hashes `sha256(realpath(dir))`, so a path tmux
  spells differently hashes to a project nobody wrote state for, and the HUD renders its honest
  `lain: no state yet`. That is the *correct* behaviour — lain cannot resolve what tmux misreports —
  and it is what `neutralizes a hostile pane cwd` now pins on such a tmux, while asserting the
  payload-never-runs half unconditionally on every version. The `$` cannot be spelled out of that
  example: `$(...)` substitution is the attack it exists to prove inert.

  Ruled out along the way, so nobody re-runs them: the `#{q:}` shell-quote escape set is
  **byte-identical** in 3.4, 3.5 and 3.7 (`format_quote_shell` in `format.c`); `/bin/sh` being dash
  on Ubuntu and bash here makes **no** difference (both render identically against the same expanded
  job); and it is not a race on the pane's cwd — 80 consecutive sessions under a fully loaded box
  never once reported an empty path.

  **Probe the behaviour, never parse `tmux -V`** — a distro backport makes the version string lie,
  and the pane is already there to ask. The general rule this is an instance of: an example that
  drives a real binary is pinned to *that binary's* bugs, and CI's copy is older than yours.
