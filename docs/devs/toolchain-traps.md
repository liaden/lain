# Toolchain traps

Every entry here cost real debugging, and most share one shape: a failure that is not what it looks like. Before believing a red suite, a missing constant or a clean green, check the conditions below.

`CLAUDE.md` keeps the headline of each rule; this file keeps the evidence.

## Interpreter

**Do NOT use `~/.rubies/ruby-4.0.6`.** It was built against a home-directory prefix that no longer exists, so its compiled-in `$LOAD_PATH` is dead and every gem binstub shebang points at nothing. `bundle` cannot start, and `rake pspec` cannot spawn a worker.

Three separate agents lost hours to this in one chunk. The workaround is worse than the breakage: forcing the interpreter up with `RUBYLIB` puts the stdlib ahead of the gems, which shadows the real `cgi` gem with Ruby 4.0's stripped one and fails the vendored-SDK specs on `CGI.parse`. Two agents then reported that as a Ruby 4.0 incompatibility and a third as a locked-gem problem. The cause was the workaround. If the suite shows failures you did not cause, check the interpreter before believing them.

**TMPDIR must be on the same filesystem as the repo.** `review/deletability_spec.rb` copies a fixture tree with `cp -al`, and a hard link cannot cross a device. The default `/tmp` is tmpfs here while `$HOME` is ext4, so all 7 of its `BootWithout` examples fail in fixture setup with a bare `Command failed with exit 1: cp`. That reads like a defect and is not one.

That one path is also shared mutable state between concurrent agents, which matters now that an orchestrated chunk routinely has several worktrees running at once. The isolation, forge, review and frontend specs drive real `git` and real `tmux` against fixture trees under `$TMPDIR`, so 2 concurrent full-suite runs collide by construction.

The shape is a `.git/objects/maintenance.lock` ENOENT, a tmux cwd `realpath` miss, a different example failing each run, and green the moment the other process exits. So a red `pspec` is not evidence until no other `parallel_rspec` is live. The same lesson applies to the traps below about scratch filenames and reading the tree mid-run: check the conditions before believing the failure.

**Ask that question with `pgrep`, not with `ps | grep`.** The obvious spelling over-counts and never reaches zero when several agents poll at once. `ps aux | grep '[p]arallel_rspec'` also matches the shell command lines of sibling agents running the same check, so 2 waiters block each other forever. Measured: it reported 2 against 1 real run, the extra being a `zsh -c` wrapper. Match the binary instead, which no wrapper's argv contains:

```bash
pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'   # 0 means genuinely quiet
```

A live `nvim`/`ollama` cockpit contends for the same fixtures without being a `parallel_rspec` process at all, so a zero here is necessary and not sufficient.

**Wait on `pre-commit` too.** The hook autostashes unstaged tracked changes before running the suite against the staged tree, and that stash is repo-wide. A concurrent reader in another worktree sees its own unstaged edits vanish and reappear, `git status` disagree with what it just wrote, and untracked-file visibility change under it. Two agents hit this as a bare `NameError` on a constant they had just added.

It is the "do not read the tree while a suite run is in flight" trap one layer deeper: it reaches `git status` as well as file reads. Check for a live hook before believing a tree that looks wrong, and re-check once quiet, with the precise pattern:

```bash
pgrep -cf '[p]re[-_]commit (hook-impl|run)'   # git runs it as `python -mpre_commit hook-impl ...`
```

The bare `pgrep -f '[p]re-commit'` false-matches. The bracket trick hides only the pattern's own spelling, and any process whose command text holds the plain word matches it. A sibling agent's background waiter whose echo said "waiting for pre-commit" read as a live hook to every other agent, and left several reading "busy" for the length of a run (2026-09-11). Match the hook's real argv, and never put the unbracketed word in a long-running command of your own.

The hook's real argv has an underscore. git starts it as `python -mpre_commit hook-impl`, so the hyphen-only `[p]re-commit (hook-impl|run)` read 0 under a live hook, and 2 sessions landing on main each believed the other's hook was not running (2026-11-10). `[-_]` covers both spellings, the hyphen for `pre-commit run` and the underscore for the hook.

**`rake compile` needs `clang`** (bindgen wants `libclang`). Switching interpreters invalidates `rb-sys`'s build fingerprint and forces a rebuild, which is usually when its absence surfaces.

**4.0.6 is a floor.** 4.0.5 crashes the VM intermittently under `rake pspec`: [Bug #22072](https://bugs.ruby-lang.org/issues/22072), `[BUG] should have cvar cache entry`. `rb_cvar_set` builds a new `RCLASS_CVC_TBL` without copying the old contents, so in a multi-Ractor process a later class-variable READ finds no cache entry and aborts.

Our one `Ractor.new` (`spec/lain/rust/fuzzy_spec.rb`) is enough to arm it. It surfaces at whatever cvar gets read first, for us `i18n/config.rb:176`, which is a victim and not the cause. Fixed in 4.0.6, along with 2 more Ractor crashes (#22075, #22084).

## OpenSSL

The installed 4.0.6 was configured against Homebrew's OpenSSL (3.6) but has no RPATH, so at runtime it resolves the system `libcrypto.so.3` (3.0.13) and dies with `version OPENSSL_3.4.0 not found`. The `LD_LIBRARY_PATH` export in `CLAUDE.md`'s toolchain block is the workaround for lain itself.

Bash children no longer inherit it. Only on a machine whose children need it, also export `LAIN_ENV_PASS=LD_LIBRARY_PATH`. The fix is to rebuild against the system OpenSSL, which is what the runtime linker picks anyway:

```bash
rm -rf ~/.rubies/ruby-4.0.6
ruby-install ruby 4.0.6 -- --with-openssl-dir=/usr    # then: bundle install && rake compile
```

`bundle install` and `gem` write outside the repo, so they need the sandbox disabled.

`ruby-4.0.1` is also installed and is unusable for native gems: its `RbConfig` points at a deleted Homebrew `gmkdir`/`ginstall`. It and the OpenSSL breakage above teach the same lesson: keep Homebrew out of the Ruby build.

## RuboCop autocorrect

Use `rubocop -a`. Do not reach for `-A` without reading the diff.

Even `-a`, the safe form, can leave a file unparseable. `Style/BlockDelimiters` (`Safe: true`) rewrites a `{ }` block as `do ... end` when that block is the body of an ENDLESS method definition (`def foo = Dir.mktmpdir("x") { |d| ... }`). Ruby cannot parse the result, the emitted `end`s consume the enclosing block's, and `Layout/BlockAlignment` then "corrects" the wreckage on top.

The same block under a normal (non-endless) `def` is rewritten harmlessly; the endless definition is the trigger. Two agents reproduced it independently: `ruby -c` on the result reports `unexpected 'end', ignoring it`, and one run detected 15 offenses and corrected 14 of them before anyone read the diff. Minimal reproduction:

```ruby
# before -- valid, ruby -c passes
def elsewhere(&) = Dir.mktmpdir("lain-slot-elsewhere") { |dir| yield File.join(dir, "escape.txt") }
```

```ruby
# after a single `bundle exec rubocop -a` (Safe cops only)
def elsewhere(&block) = Dir.mktmpdir("lain-slot-elsewhere") do |dir|
  yield File.join(dir, "escape.txt")
end
```

So `-a`'s "safe" means safe from changing behavior, with no guarantee the file still parses afterward. Read the diff, and run `ruby -c` on anything `-a` touched that used an endless method definition.

`-a` applies only cops marked `Safe: true`. `-A` also applies unsafe ones, and at least one of those is dangerous here. `Style/RedundantSelfAssignment` (`Safe: false`) flagged `@timeline = @timeline.append(...)` on the assumption that `append` mutates its receiver, as `Array#append` does. Ours was pure. The "correction" would have discarded every turn with no test failure. The method is now `Timeline#commit`, which reads correctly and sidesteps the cop.

A second `-A` specimen: `Lint/UselessDefaultValueArgument`'s correction deletes the second argument of `RequiredKeys.fetch(record, key) { }`. That is a project method named `fetch` that takes a block, not `Hash#fetch`, so the deletion silently changes which key the call reads. The cop assumes a block argument to `fetch` is a default-value fallback, so a positional default alongside it is redundant. That holds for `Hash#fetch` and not for this method. The method was renamed to `read`/`read_filled` so the cop never fires on it, with no inline disable.

## Known traps

- Anthropic's stream accumulator is `accumulated_message`, not `get_final_message`. The stream is single-pass and `accumulated_message` mutates its snapshot.
- On the streaming path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON String. `Provider::Anthropic` parses it; nothing above the Provider may see it.
- The system keyword is `system_:` (trailing underscore). Content-block `.type` is a Symbol.
- `:model_context_window_exceeded` and `:compaction` are Beta-only stop reasons. The non-beta enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it is non-exhaustive, so always have an `else`.
- Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not cache, with no error.
- `require "active_support/core_ext"` fails unless `require "active_support"` comes first.
- Constants and nested classes defined inside a `Data.define(...) do ... end` block are lexically scoped to the enclosing module, not the Data class. Reopen the class after the block instead (see `Request::SYSTEM_PREFIX`).
- A reopened class gets exactly 1 docstring, and it goes on the REOPEN. The `Data.define` assignment above it stays bare. YARD keeps one docstring per namespace and silently discards the rest, so documenting both loses content with no warning at write time; `yard-lint`'s `Documentation/DuplicateNamespaceComment` catches it, at commit.

  RuboCop's `Style/Documentation` pulls the other way but does not conflict in practice: it fires on the `class` keyword, which the reopen satisfies, and never on the assignment. Two shapes both pass, so pick by whether the reopen carries behavior:

  ```ruby
  Anchor = Data.define(:path, :side) do   # bare: no comment above this line
    include Telemetry::Journalable
  end

  # One reviewable position: ... <- the docstring lives HERE
  class Anchor
    SIDES = Review::SIDES.map(&:to_sym).freeze
  end
  ```

  A reopen holding only a constant (`JOURNAL_TYPE` and nothing else) is a pure namespace, and `Style/Documentation` does not fire on it. That shape may keep its docstring above the `Data.define`, but then any explanation of the reopen goes inside the class body, never above the `class` keyword, or it becomes the second docstring again.

  `lib/lain/review/records.rb` is the pure-namespace case, `lib/lain/review/anchor.rb` and `lib/lain/review/hunk.rb` the behavior-carrying one. Both shapes are clean under `rubocop --only Style/Documentation` and under `yard-lint`, which is the pair to check when in doubt.
- YARD reads `@word` at the start of a comment line as a tag, so a prose reference to a keyword argument wraps into `Warnings/UnknownTag` and fails the commit. Write it inline (`the `compose:` note on {Neovim#initialize}`), not as the first token of a wrapped line.
- `rm .git` before running anything in a COPY of a linked worktree. A linked worktree's `.git` is a one-line pointer file (`gitdir: /path/to/lain/.git/worktrees/<name>`), not a directory. So `cp -a` of a worktree gives you a copy whose git admin data is still the original's, and the isolation and forge specs, which drive real `git` against the repo they find, then operate on the linked worktree's admin directory instead of the copy's.

  Observed 2026-08-04: one full-suite run from such a copy deleted the entire copy. Nothing warns you; the pointer file looks inert. Copying a worktree for mutation, bisect or spike work is otherwise reasonable. Delete the pointer first, or copy from a real clone.
- The same trap sits one layer down, in a copied SUBMODULE checkout. A submodule's `.git` is a pointer file too (`gitdir: ../.git/modules/<name>`), and that admin directory names its checkout back in `core.worktree`, which a `cp -a` does not change. So git run in the copy reads the original's admin data and writes into the original's working tree. It is the entry above with a second door into it.

  A legitimate submodule and a copied one differ in one thing: whether the admin directory names THIS checkout back. A linked worktree says so in its `gitdir` file, a submodule in `core.worktree`, and a copy of either answers with somebody else's path. `spec/worktree_identity.rb` asks that at suite boot and refuses to run when the answer is no. The remedy for a copy you made on purpose is the one above.
- A class named for a top-level constant SHADOWS it for everything lexically inside the enclosing namespace. Defining `Effect::Handler::Sensitivity` made `gate.rb`'s bare `Sensitivity::Policy` resolve to `Handler::Sensitivity::Policy` and die, for every caller omitting the keyword, which was most of them.

  It fired again when that layer moved to `Middleware::Sensitivity`: every bare `Sensitivity::…` in the sibling secret middlewares (`redact_secret_reads.rb`, `withhold_secret_paths.rb`) silently became a reference to the new class. `Module.nesting` order is not something anyone reasons about until it bites. Before naming a class after a top-level constant, grep its namespace for the bare name, and root-qualify (`::Lain::Sensitivity`) at every such site.
- `pre-commit` exports `GIT_INDEX_FILE` into every hook, so a spec fixture that shells to `git` without scrubbing builds against lain's index. It passes in every normal run and fails only at commit time. One card exposed 13 examples, and only the one that commits failed loudly.

  Scrub the wider set, beyond `GIT_DIR`: a command-line `--git-dir` already beats that one, while `GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE` and `GIT_CONFIG_*` are the ones that redirect git. `GIT_CONTEXT_SCRUB` also drops `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`, `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM`, `GIT_REPLACE_REF_BASE`, `GIT_NO_REPLACE_OBJECTS`, `GIT_GRAFT_FILE`, `GIT_SHALLOW_FILE` and `GIT_IMPLICIT_WORK_TREE`. Never use a blanket `GIT_*`, since specs set `GIT_CONFIG_GLOBAL` on purpose.
- A commit hook in a LINKED WORKTREE also exports `GIT_DIR`, which a hook on main does not. Under it, a fixture's bare `git init -q` in any temp dir reinitializes the worktree's admin dir, and git, with a `GIT_DIR` and no work tree, guesses BARE. `core.bare = true` lands in the `.git/config` every worktree shares, and main answers "this operation must be run in a work tree" until it is set back with `git config core.bare false`.

  A fixture's `update-index` lands in that worktree's index instead (every file staged deleted, a stray `UU README`). Seen 2026-10-16 from one `git commit` in a worktree, and reproduced in a throwaway repo: 12 spec sites spawned git through `Open3` or `system` with no environment, or with only `GIT_INDEX_FILE` cleared. The `Lain/GitFixtureScrub` cop (`.rubocop/cops/lain/git_fixture_scrub.rb`) now fails on a git spawn with no environment first; it cannot judge a partial one, so pass `SeedRepo::SCRUB` whole.
- Mutation harnesses lie by default here, and same-size mutants are the norm. `20`→`10`, `<=`→`<` and `min_by`→`max_by` are all byte-identical in length, so they collide with bootsnap's `(mtime-seconds, size)` iseq key and run against stale bytecode while `git diff` reads clean.

  Stamp a unique mtime per write (`File.utime`). Assert each mutant applied exactly once and still parses. Score on the failure COUNT, never a string prefix (`start_with?("4")` relabels everything once the example count crosses a digit boundary). Use literal fixtures and exclude the subject from any corpus that scans it.

  Wrap the run in `ensure`: 2 agents in one chunk died mid-run leaving a live mutant in the tree, caught by re-reading the file and by no test. And never park the harness in `spec/support/`: `spec_helper.rb` globs `support/**/*.rb`, so it loads in every worker of every run. One harness defined `Object#run` globally and called `Dir.chdir` at load.

  The harness must also refuse to score when it measured nothing, and refusing a MISSING count is only half of it. This was learned twice in one day, 2026-08-19.

  First half: a run invoked outside its toolchain wrapper printed every structural line it was built to print ("mutant applied", "restored", "identical: yes") while every `rspec` line came back EMPTY, because the interpreter was wrong. Structure without measurements reads as a pass at a glance, and the blank `examples` fields were the only tell.

  Second half, found when that guard let its own author through: a mutant that broke class definition made rspec load nothing and print a perfectly real `0 examples, 0 failures`. That satisfies "a count line was produced" and still measures nothing. A mutant that does not load is an unrun one, not a surviving one, and it scores as a kill unless the harness says otherwise.

  Third door, which subsumes the other 2: a count line that is real, non-zero and SHORT. A `SystemExit` or a load-order truncation yields `22 examples, 0 failures` where the baseline was 32. That reads as "the mutant survived" and means "half the file never ran", the same truncation trap recorded above, wearing a mutation harness.

  So the rule is that the count EQUALS the baseline count; a count merely being produced does not pass. Capture the baseline once before mutating and compare against it every run. This is the stale-bytecode confident green above, arriving through 2 more doors. It has the same shape as a script that asserts its anchor EXISTS without asserting its edit APPLIED, which is how this paragraph failed to land the first time it was written.
- A generic filename in a shared scratchpad is shared mutable state between concurrent agents. One agent's `run.sh` toolchain wrapper was overwritten by another and silently repointed at a different worktree; commands kept running and kept passing, against someone else's checkout.

  The measurement it produced (4 mutants all "caught") was taken against unedited files and proved nothing. It surfaced only when a substring replacement failed on a file that had just been read. Name scratch files uniquely, and have a runner refuse to start unless a file it owns is present (`test -f .handback-T<id>.md || exit 1`). The failure mode is a confident green from the wrong tree, with no crash.
- Do not read the tree while a suite run is in flight. Under `rake pspec` a read can return content without edits that are already on disk. Twice in one task this looked exactly like the live-mutant signature above; `git status` and a re-read after the run exited confirmed disk was correct both times. Re-check after the run, not during.
- `ls-files` truncates against the PROCESS directory, so a home-repo surface read from a subdirectory is both short and rejoins to the wrong file. `-C <dir>` is the fix; `--full-name` is not sufficient.
- Under starvation the example COUNT can go up as well as down, and an inflated count is itself the tell. The count rule elsewhere warns that a dead worker, an OOM kill or a `SystemExit` reports FEWER examples with 0 failures. 2026-08-23 produced the opposite shape twice, from 2 independent agents on a box at load 82-214 with rival `parallel_rspec` runs in flight: a tree whose true count was 15209 reported **15217 examples, 28 failures**, and one whose true count was 15229 reported **15233 examples, 17 failures**. Neither number is evidence; the movement of the count away from the true one says so.

  `bundle exec rspec --dry-run` is the ground truth for the count. It collects every example without executing any, takes seconds, and is immune to load, so it answers "did a worker die, or did the packer double-count?" without paying for a run. Take a dry-run count first, and only then read a `pspec` line against it.
- `rake pspec` can exit 0 while printing `rake aborted!`. Observed 2026-08-23: the task printed `15172 examples, 2 failures` followed by `rake aborted! Command failed with status (1)`, and the calling shell still saw exit status 0. The exit code is not a gate. Score a suite run on the printed `N examples, M failures` line only. Together with the example-COUNT rule in CLAUDE.md, that is 2 independent ways a red suite reads green.
- A forked or out-of-band RSpec runner that never renames `$PROGRAM_NAME` loads zero spec files and reports a confident green. `Configuration#files_or_directories_to_run=` appends the `spec` default path only when `$PROGRAM_NAME` basenames to `rspec`. A `Kernel#fork` of a preloaded process, or anything else that drives RSpec's API instead of going through the `rspec` executable, keeps whatever argv-zero its parent had. Without the rename the run collects and executes nothing and still exits 0. That is a third way (alongside the 2 above) that a red suite reads green, from a runner that never loaded a single example.

  The fix goes deeper than the file list. `CLI::Up::ChatPreflight` expands a relative executable to an absolute path, while `up_spec`'s spy compares the raw `$PROGRAM_NAME`. Renaming the process to a bare `rspec` (needed for the file-loading trick above) broke that comparison and produced 10 examples failing in every run, from the rename itself and not from the suite.

  A runner built this way also wants its own `TMPDIR`/XDG tree per run, for the shared-mutable-state reason given above (`:21-29`). Surfaced by `bin/spec-flakes`, a forked whole-suite runner retired 2026-09-12 for an unrelated collision (below). The script is gone but the mechanism binds any future one built the same way.
- This box's shell is zsh, and `cmd 2>&1 1>/dev/null | sed` does NOT swap descriptors there. zsh's MULTIOS tees instead, so a probe written to isolate stderr silently reports stdout's content as if it were stderr. Measured 2026-08-23 while checking that a renderer prints its "never blank" sentence to stdout: the idiom said stderr, plain file redirection said 0 bytes on stderr, and the second answer was the true one. Use file redirection (`cmd >out 2>err`) when the question is WHICH stream a thing came out of. The pipeline idiom is a bash habit and it lies here.
- The interactive shell's `grep` is a function onto `ugrep`, which SKIPS a file it heuristically calls binary, with no error, no warning and zero matches. `grep -m1 '^status:'` over every `planning/specs/chunk-*.md` reported `chunk-skills-roles-tools.md` as having no status line, and line 3 of that file reads `status: done`.

  The document is valid UTF-8, but `file -b` calls it `data` and ugrep 7.8.4 takes that as a reason not to search it. A document was nearly left out of an archival move over it. It is the same family as the zsh idiom above: a confident answer, not an error. Pass `-a` whenever a grep's EMPTINESS is what you are about to act on.
- A `SystemExit` inside an example truncates the run and still reports "0 failures". Thor turns a refusal into `exit(1)` and RSpec does not rescue `SystemExit` inside an example. One regression took a file from 32 examples to 22 while reporting a clean pass, and the truncation point moved with the seed. Under `parallel_rspec` that is indistinguishable from the OOM-kill shape above. Pass `debug: true` to any Thor `.start` in a spec, and check the example COUNT.
- A trap restored late by an unjoined thread truncates a run and blames the wrong example. A thread that installs its own INT handler and puts the old one back on its way out can outlive its example if `after` kills it without joining. It then restores RSpec's SIGINT handler into the middle of a LATER example, and a self-signal there stops the worker as if Ctrl-C had been typed. The run ends early with a short count and one misleading failure, or none, so read the COUNT. Join every thread that touches a trap, with a bound.
- An unbounded blocking `accept` in a spec helper hangs the file instead of reddening it. `spec/lain/frontend/input_pane_spec.rb`'s `open_pane` called `server.accept` with no timeout. A pane that could not construct never connects, and the call blocks instead of raising, so the whole file hangs on the first example that hits it.

  Fixed with `server.timeout = 5`, set on the server itself before `accept`, one step earlier than the existing `chat.timeout = 5` already applied to the socket `accept` returns, which bounds only what happens AFTER a connection lands. It sits beside the rule above on purpose: that rule is about a run that finishes and under-reports, this one about a run that never finishes to report anything. Any spec helper that blocks on a real `accept`, `read` or `connect` needs its own bound, in addition to the one on the socket it hands back.
- Reline asks the terminal where the cursor is and waits 0.5s for an answer. Reline 0.7.0 (`reline/io/ansi.rb:208`) writes `\e[6n` and waits up to 0.5s for a reply when input and output are both TTYs. A spec that drives a prompt through a PTY and never answers pays 0.5s at every prompt, and nothing fails: the example is only slow.

  `spec/support/cursor_report.rb` answers with `\e[1;1R`. On `seams/input_pane_socket_spec.rb`, answering took the file from 43.0s to 30.0s alone, with 19 of 19 examples green. A new PTY spec that looks slow for no reason is the first place to look.

## Flaky specs

- 2026-10-02: after the speed and flakes plan, 15 full `rake pspec` runs at 12, 14 and 16 workers had no failure; the pre-plan tree failed 9 of the same 15. The names below stay as the record; the retired list further down says which were fixed and how. Budget a retry only for a name still live here.
- A flaky spec is recorded by NAME, never by line number. The 4 first recorded as `cli/up_spec.rb:115`/`:175` drifted within days: one chunk grew that file by 454 lines and the live failure moved to `:166`. A stale line number is worse than no list, because it reads as "not a known flake" and sends the next reader hunting a regression that is not there.

### Known load-induced flakes, by name

These were recorded 2026-08-18. All pass in isolation, all are driven by real `git`/`tmux`/`nvim` under a loaded box. See the TMPDIR note above before believing any of them:

- `Lain::Frontend::Neovim the review thread pane following the cursor does not re-place the diff on every further move once it is back`
- `isolation/worktree_handback_spec`'s `Dir.mktmpdir` teardown racing git maintenance

Added 2026-09-11, from a run with 2 to 5 agents running rspec at once. Each of these went red in a pre-commit or `pspec` run while another suite was live, and passed alone. Run the named example by itself on a quiet box before believing any of them:

- `Lain::CLI::Up against a real tmux server --nvim cockpit splits the chat window into an nvim pane and a chat pane sharing one socket and one cwd`
- `lain.rb without the compiled extension keeps Ruby's own LoadError message rather than replacing it`
- `the review annotation runtime a buffer that goes away drops the orphaned entry once it has settled it, so a reused bufnr inherits nothing`

Added 2026-10-06, a wall-clock example red under a load average of about 12 (agents running specs beside a suite) and green alone each time: `a chat whose terminal is gone ends at its prompt once the terminal is closed`. The walk-budget example that was on this list is retired below.

Added 2026-10-21, a thread count red once in a pre-commit suite at load 11 beside another rspec run (5 threads against 4), green alone (37 of 37) and green in a full suite on the base and on the change: `Lain::CLI::InputSocket serving a pane reaps a closed pane's reader, so it owns every thread it started`. Retired 2026-11-01 on its second red: a reader whose pane closed at once removed itself before `spawn` added it, and stayed in the registry dead. `spawn` now starts the thread inside the lock.

Added 2026-10-21, from 5 back-to-back full `pspec` runs at 12 workers on an otherwise quiet box (each run at the load the previous one left, 9 to 15). Every run reached all 26,464 examples. Two runs had 1 red each, and each example was green 5 of 5 alone and green across its file with the failing worker's seed:

- `Lain::Ext::Fuzzy#match on another thread lets the calling thread keep ticking while it matches` (p99 tick gap 28.7 ms against its 8 ms bound; a held GVL gives about 180 ms, so this is load, and the tick floors are now a pattern of 3).
- `Lain::Sensitivity::Policy#mask_paths against #judge, name by name does 1 realpath per directory over a plain listing, with judge's verdicts` (156 `File.realpath` calls against at most 21; green 30 of 30 alone). That one is a count, not a clock: the stub counts calls from every thread in the worker, so a thread an earlier example left running would inflate it. This was unproven; counting only the example's own thread would settle it.

Both are retired as of 2026-10-22, below.

Added 2026-10-22, from the 6 profiled runs of the suite (one per `bin/suite-profile` lens): under the wall-mode stack profiler, `Lain::CLI::InputSocket serving a pane sends nothing more while the header stays the same` failed once. The other 5 profiled runs reached all 26,464 examples green, and none of the 10 plain `pspec` runs of the same work failed. A wall profiler slows every thread, so read it as another wall-clock budget starved, not a product defect. It is one sample; if it recurs without a profiler, that makes it a pattern.

Added 2026-10-28, from landing suites run beside 4 to 8 agents (load 17 to 34). Each went red once in a pre-commit suite, then passed alone and passed with the failing seed 3 of 3 on the base and on the card:

- `SecretSurface the audit sample of confident approves samples 5 percent by default` (Async timeout)
- `Lain::Tools::Subagent a one-shot child that does not finish when the ceiling stops a child that had read files and written notes stays within the bound however the lists land against it` (watchdog STUCK)
- `Lain::CLI::Up a chat pane that dies at once bounds what it costs a HEALTHY launch by the grace it states` (0.43s against a 0.3s wall-clock bound, a threshold the 2026-10-27 ruling bans)

The CoreGraph descriptor count above went red again the same day (10 against 8).

Added later on 2026-10-28, from landing suites beside 2 reviewers running specs (load 26) and later ones beside working agents, each green alone and with its failing seed 3 of 3 on the base and on the card:

- `the review records' journal discriminators answers for every includer, including the ones no generic dummy constructs` (136 unique against 138 includers; fixed 2026-11-10, see below)
- `Lain::Bench::CLI#arms_report under --confine reader with --confine workspace hands every arm's tools a sandbox with the workspace switch on, and says so in the report` (watchdog STUCK inside `Confine::MaskList`'s walk)
- all 4 examples of `two cockpits on one machine` (a `you>` line never held in the input pane within 15s, and once STUCK at 30s awaiting the prompt: a launch is 5 boots in a row that outrun the waits under load)

The CredentialPatterns "on both sides" timing example is gone; see the retired list.

The CoreGraph descriptor count went red a third time (22 against 23: the count fell, so another thread closed an fd mid-ask) and is fixed. It now compares (fd, readlink target) pairs, so only a descriptor the ask left open fails it.

Both repeats that day are fixed too, so a red from either is no longer a known flake. The audit sample now counts what the sweep left undecided behind one hang guard, with no per-dequeue bound. The `--confine workspace` arms report reads a small seed checkout, where it had walked all of this one (about 3,100 files) once per sandboxed call, 73 times.

Added 2026-10-31, from landing suites in one plan run. Each went red once in a pre-commit suite and passed alone and with its failing worker's seed on the base and on the card, on cards that do not reach it:

- `Lain::Ext::Fuzzy#match on another thread behaves like a GVL-releasing binding raises the interrupt's error rather than returning a partial answer` (0.72s against a 0.32s bound, load about 16 with 3 agents running specs beside the suite)

`two cockpits on one machine` went red twice more the same day. All 4 examples failed once (a `you>` line never held in the input pane within 15s), and once `keeps one status feed per project, each with its own run's tokens` was STUCK and STARVED at a load of 28.5 with a game running beside the suite. Each time the file passed 3 of 3 with the failing seed on the base and on the card. That is 4 recorded reds of one launch that outruns its waits under load, so it is a card, not a flake to budget a retry for.

Added 2026-10-09, red once (watchdog STUCK at 30s) in a pre-commit suite under a load of about 11 on 16 cores with a reviewer's probes running beside it, and green 3 of 3 runs of its file alone: `a line typed while an ask is in flight on the chat's own terminal keeps a line typed mid-ask for the next prompt, once`.

Added 2026-09-29, red once in a whole-suite run (seed 59509) and green 3 of 3 alone. It counts every descriptor in `/proc/self/fd`, so anything else live in the same worker process moves the count: `Lain::Agent the graph CoreGraph hands out by default runs to completion holding no file descriptor of its own`.

Added 2026-09-21, from 10 hook-verified landings on a box with one core pinned by an unrelated job. Each of these reddened at least one pre-commit suite and then passed 3 of 3 serial runs of its file. Two more, the subagent fan-out order and the TTY's "loses and repeats nothing typed while notes keep arriving", are retired below.

- `Lain::Frontend::InputPane a pane with no chat to talk to says what it is waiting for without claiming the screen, and leaves when told to` (twice; the 2026-10-02 join did not reproduce its cause, so it stays here)
- `plain_chat_prompt_guards_spec.rb`'s `a plain chat's inline prompts over a real terminal Ctrl-C at human> offers stop, and s ends the ask while the session carries on`, on the final count run (its sibling there, "ends its line with who decided it and how", is retired below)

Since 2026-10-02 that file waits on events (the echo, a held note, a parked marker, PTY EOF) and takes its children from a warm pool. Five named 0.3s negative windows and the Ctrl-C readiness sleep remain, the last because a Ctrl-C within about 30ms of `you>` drawing can be lost. The Ctrl-C name stays live.

The 62_approval examples (now retired, below) reddened twice more in the same run. One timing flake per hook run was the norm that day, so budget a retry per landing, and check a retry's red against this list by name before believing it.

Added 2026-08-23: the 2026-08-19 `worktree_handback_spec` entry still under-describes that file. Two MORE of its examples have been observed red and green on the same box within minutes, both in the `#continue refuses a resolution that is not one` describe block that no entry here names:

- `Lain::Isolation::Worktree::Handback #continue refuses a resolution that is not one can be retried, and concludes once the markers are gone`
- `... wants all three shapes in order, not any marker-shaped line`

Measured directly: the file alone, 4 consecutive runs, no `parallel_rspec` and no `pre-commit` running, went `0, 0, 0, 2` failures. A separate isolated run on the same box reddened the `we\nird.txt` example the 2026-08-19 entry already names, which that entry says passes in isolation.

The unit to treat as flaky is the FILE, and no single example in it. A red example anywhere in `spec/lain/isolation/worktree_handback_spec.rb` is unattributable until it is re-run alone. Do NOT conclude "not a known flake" because the particular example name is missing from this list: that is the misreading the by-name rule was written to prevent, and this file defeats it by moving between examples.

It builds its own repository under `Dir.mktmpdir` and never touches lain's own git admin dir, so the number of worktrees registered in this repo is NOT the cause. That hypothesis was tested and rejected 2026-08-23.

Added 2026-10-15, from a pre-commit run and a reviewer's run beside about 10 agents running specs (load 13). Each passed alone, and each reads terminal bytes before a write that is still in flight lands, so a red under load is timing. Two LineEditor names, 1 InputPane name and the plain chat's "ends its line with who decided it and how" from this run are retired below.

- `Shift+Enter in a pane inserts a newline and submits the whole draft on Enter` (load 14, passed alone and 3 of 3 with its seed on the base commit)

Added 2026-10-19, from a landing hook beside about 20 agents running specs: `Lain::Agent the graph CoreGraph hands out by default runs to completion holding no file descriptor of its own` saw 9 open descriptors where it counted 10 (another example in the same worker closed one mid-count). It passed alone, and 3 of 3 with its worker's seed on the base commit and on the card's tree.

Added 2026-11-02, from the nyotes landing windows. Each passed alone and 3 of 3 on the base commit:

- `Lain::Shell::Pipeline a stop from outside kills a stopped term-arm command's group and unwinds promptly` raised ENOENT reading `/proc/self/task/<tid>/children` while a thread exited. It reddened in 2 landings, so it is also a follow-up card.
- `A project's own tests inside the workspace profile passes one spec file with the example count an unconfined run reports` hit its 30s watchdog (0.4s CPU, 30.4s wall) at load 23 on 16 cores (fixed 2026-11-10, see below).

Added 2026-11-04, from the nyotes landing suites, run at loads of 17 to 52 on 16 cores with other suites and a game beside them. Each went red once in a landing suite and passed alone (3 of 3 with the failing seed on the base, where it was tried), on cards that do not reach it:

- `typing in a real cockpit while the model is busy stops an ask parked on an approval when /stop is typed, without running the call or closing the session` (STUCK at load 17; 5 of 5 alone, on a card with no Ruby or runtime change).
- Repeats of the entries above: `a project's own tests inside the workspace profile passes one spec file with the example count an unconfined run reports` (STARVED at its 30s watchdog at load 28.3 and again at 24.5, so 2 more reds; fixed 2026-11-10, see below) and the same group's `passes the fence crate's tests, none of them skipped`; and all 4 examples of `two cockpits on one machine` (STUCK at load 21.5).
- `cockpit_approval_spec`'s `when the human approves the call shows a fleet line above a you> line in an input pane at its floor height` (the hint line was showing, not the fleet line; seed 30101, 5 of 5 alone). It is also a repeat of a sighting in an earlier plan's log, not recorded here until now.
- `read_file_spec`'s `an offset of one with no limit allocates like a whole read, not like a line-by-line one` (30434 allocations against a bound of 21666, seed 17987). The allocation count is process-wide, and the likely cause is a git-priming thread of an earlier example's board still running in the same worker; not reproduced in 3 tries.
- From one landing at a load of 51.6, each green alone: `review_spec`'s `answers 2 asks sent at once`; `child_env`'s `passes the names LAIN_ENV_PASS lists`; `qa_sandbox_pane_resolution`'s `sends to the pane the cockpit records`; `Lain::CLI::EpicSubmit`'s `journals the fail-closed decision for a stop landing` (a sibling of the retired Ctrl-C entry below); and 2 examples of the `cockpit_question` e2e.
- `Lain::Ext::AstGrep.search on another thread behaves like a GVL-releasing binding stops soon after its thread is killed, rather than at the end of the call` (0.56s against a 0.20s bound). It is the shared GVL-releasing group's wall-clock bound, the same one as the 2026-10-31 `Fuzzy#match` entry.
- From one landing whose suite alone reached a load of 66.9 on 16 cores (load 1.2 when it started), all STARVED at a 30s watchdog and green alone: `Landing calls in lib finds the calls it polices`; `Lain::RunClock MONOTONIC is named once even inside run_clock.rb, so RunClock's own default reads the constant too`; `a plain chat's inline prompts over a real terminal a line typed across the moment the prompt opens holds the whole line and asks again, when its end is typed at a human's pace, unseen`; `a chat fed by an input pane completes a skill named in the chat's context frame when Tab is pressed in the pane`; `CommentCensus third-party identifiers carries no project-scheme citation anywhere the checker scans`; `the deletion map booting without a capability still loads with disclosure_sweep and everything it forces removed`; and a repeat, `two cockpits on one machine leaves the second cockpit's editor answering after the first stops`.
- `Lain::CLI::Gateway refuses to start over a symlink at its token file's path, naming the path` (seed 13238): its last check connected where it expected a refusal. The spec opens and closes a server to pick a free port, so another worker can bind that port before the check. Three of 3 green alone.

Several of these wait on a wall-clock bound a loaded box starves, which the 2026-10-27 ruling forbids new specs to carry, so they stay cards to rewrite and not flakes to budget a retry for.

Added 2026-11-10, from the landing hooks of the hot-path run. Eight hooks went red and every card landed on a retry with no change. Their logs list 82 failed examples, 74 of them distinct by name. The names below passed alone (the cards' own alone runs), except where noted.

Of the 80 distinct failure reports, 57 carry the watchdog's `STARVED` line, in 6 of the 8 logs. That line prints the box's 1-minute load average, 27.2 to 140.8 against 16 cores, and the red process had used 14% or less of one core across 30.1 to 71.5 s of wall time. For those, the cause is starvation and not the example, so treat a `STARVED` red as unattributable until the box is quiet.

Repeats of entries above, red again in this run:

- `A project's own tests inside the workspace profile passes the fence crate's tests, none of them skipped` (4 hooks) and `... passes one spec file with the example count an unconfined run reports` (2 hooks, one of them also red for the first). Both spawn a nested cargo or rspec. They took 36 to 220 s against a 30 s watchdog budget in the red hooks and 9 to 12 s in the green ones, and every red log that shows a load line shows `STARVED` at load 31 to 104. This is the 3rd landing window in a row (2026-11-02, 2026-11-04, now) where the pair reddened, so it is a follow-up card, not a name to budget a retry for. Fixed 2026-11-10: both carry `starvable:` metadata, so an overrun on a starved box ends pending with the `STARVED` line, and on a quiet box it is still the `STUCK` raise.
- `the review records' journal discriminators answers for every includer, including the ones no generic dummy constructs` read `Expected 143 to eq 145` in 1 hook with no `STARVED` line; the 2026-10-28 entry saw 136 against 138, also 2 short. Green alone 3 of 3 on the base commit and once on the card's tree. Fixed 2026-11-10: a class `stub_const` left in `ObjectSpace` kept its name and its discriminator until GC ran, so the sweep saw 2 records under 1 name. The spec now counts only classes a constant names. The 2026-10-28 entry for this example is the same flake.
- `Lain::Bench::CLI#arms_report` (2 examples, the 2026-10-28 name), `the deletion map booting without a capability` (4 examples) and `a chat fed by an input pane completes a skill named in the chat's context frame when Tab is pressed in the pane` (both 2026-11-04 names), each `STARVED`.

New by name, no `STARVED` line: `bin/suite-load and bin/suite-redrate SuiteLoad::Group#stop returns as soon as a group that exits on TERM has ended` read 0.44 s against its 0.15 s wall-clock bound at load 12. It took 0.21 s alone, 3 of 3 on the base commit and once on the card's tree. The bound is a wall-clock threshold of the kind the 2026-10-27 ruling forbids, so it is a card to rewrite. The same file's `suite-load leaves no loop or run process after TERM from a start that ignored it` went red in another hook (not re-run alone).

Red once. Most carry a `STARVED` line; these do not: 3 of the 4 `StdinPump` examples, 3 of the 7 `Up` examples, 1 of the 2 `Exec::Local`, the `ApprovalView` `an item longer than one line`, and 7 of the 8 plain chat prompt examples.

- `Lain::Frontend::StdinPump` over a real terminal (4 examples)
- `Lain::Frontend::LineEditor#read on a real terminal` (7)
- `plain_chat_prompt_guards_spec.rb` (8: the Ctrl-C at a [y/N] pair, `prose typed at a [y/N]`, `/approve typed while the watcher's [y/N]`, `an arrow key typed before a prompt`, `Ctrl-C at an idle you> ends the chat over an empty line` and the 2 parked-call ordering examples)
- `Lain::CLI::Up against a real tmux server` (7)
- `seams/input_pane_socket_spec.rb` (4)
- `seams/tool_text_boundary_spec.rb` (3)
- `seams/approval_cycle_key_spec.rb` (1)
- `Lain::Frontend::Neovim` `a long note grown in a pane` (2), `ApprovalView` (2: `an item longer than one line` and `the fold surface, in a real editor`) and `the refusal rail's width`
- `capability degradation on the chat path` (2)
- `Lain::Error taxonomy the ratchet` (2)
- `Lain::Review::Source::LocalBranch#files_at` (2)
- `Lain::CLI::Wiring the journal routing discipline` (2)
- `Lain::Exec::Local` (2)
- `Lain::CLI::Command::Survey the survey banner's commands, against a real editor`
- `Lain::CLI::EpicDriver::IssueActor fences the embedded issue`
- `Lain::CLI::EpicDriver::Factory ... gates work squashed into the red commit`
- `Lain::CLI::Wiring::ToolsetBuild a judge-approved write ... runs it in the workspace profile`
- `git fixtures in spec/ pass an environment to every git they spawn`
- `forking and resuming a session whose subagent asked the human a question records a child question the human answered`
- `RuntimeCensus the command line --check exits 0 when all is within bounds`
- `Lain::Grader::Journaling#grade returns the Grade unchanged`
- `Lain::Grader::MutationReinsertion ... a helper the agent added under spec/support`
- `Lain::Isolation::MergeCoordinator.main_root`
- `SuiteProfile the hooks under spec/support/suite_profile`
- `test-only Nulls are named nowhere in lib/ or exe/`
- `bin/workspace-run reports a sealed toolchain file`
- `A related directory inside the reader sandbox refuses a read under a related directory that is not a repository`
- `Lain::Review::Source::Diffed#files over a real branch`

Red once with no `STARVED` line: `Lain::Sensitivity::Policy#mask_paths against #judge ... does 1 realpath per directory`, `Lain::TestLayout::Guard ... holds over lain's own spec tree`, `lain nvim plugin ... honors a state_path override`, `a plain chat against a faulty upstream names an endpoint that refuses connections` (each green alone) and `Lain::Ext::Bm25 on another thread ... lets the calling thread keep running while it works` (not re-run alone).

Added 2026-11-10, from the herdr-attention run's first landing hook, at load 29 to 33 on 16 cores with memory pressure stalling 29% of the window. Each passed alone at load 1.2 and 3 of 3 with its worker's seed on the base commit, on a card that adds 2 files nothing references:

- `Lain::Tools::Subagent a one-shot child that does not finish when the ceiling stops a child that had read files and written notes keeps the ceiling message and the last text block when the lists are huge` (STUCK at 30.5 s, 11.2 s of CPU, inside `ChildEnv#environment`; retired 2026-11-11, below).
- Two repeats, each now a follow-up card: `two cockpits on one machine leaves the second cockpit's editor answering after the first stops` (STARVED, 6% of a core) and `Lain::CLI::EpicSubmit Ctrl-C through the real CLI exits 130, with the fail-closed decision already journaled` (timed out waiting for the gate's prompt; the screen held only a RubyGems plugin load warning, gem-ctags_plugin.rb).

Fixed 2026-11-11, by user ruling: both repeats now wait on a property with the watchdog as the only clock, and carry `starvable:`, so a starved box ends them pending with the STARVED line. The EpicSubmit child prints its prompt in 0.9 s quiet and at most 2.5 s under 32 burners, so its own 10 s deadline was what expired, and the RubyGems warning was not the cause (the match is a substring). `two cockpits` waits for each boot as long as its 60 s group budget allows; red 2 of 2 on the base under a heavy burner, green 7 of 7 with the fix.

Also fixed the same day: `Lain::Shell::Pipeline a stop from outside ...` read `/proc/self/task/<tid>/children` after the thread exited (the 2026-11-02 entry, red again in this run). The spec's helper now skips a vanished task.

Added 2026-11-12, from the landing hooks of a later plan run. Each went red once in a landing suite, passed alone in the card's tree, and passed 3 of 3 runs of its file on the base commit:

- `Lain::CLI::EpicDriver::Run a stop by the human while an issue launches when the issue takes a while to read before its lease is asked for asks for no lease after a stop that lands during the read` (STUCK at 30.5 s at load 19.2 on 16 cores)
- Two examples of `Lain::CLI::TmuxSurface against a real tmux server`, red together in one suite: `keeps a cleanly exiting window's pane out of the way` and `holds the corpse of a window whose command exited non-zero`

Added 2026-11-16, from the review queue run's landing hooks. Red once in a landing suite, green alone, and 3 of 3 runs of its file on the base commit: `Lain::Ext::Timeline#messages re-entering Ruby frees the render state when the fiber is dropped inside Canonical.adopt` (leaked 1001401 bytes against its 1000000 limit, seed 30242).

Added 2026-11-17, from the lain-daemon run: `Lain::Approval::RemoteSurface through the built daemon's relay takes back what it published when it stops, so the phone stops showing it` timed out in the phone's wait for the item to open (20 s, `Async::TimeoutError` in `Phone#until_open`) in a landing hook at load1 1.2, after a reviewer saw it red 2 times in about 22 runs. It repeated, so it is a fix card in that run, not a flake to budget a retry for.

Added 2026-11-18, from the lain-daemon run's landing hooks on a box short of memory (swap full, the kernel OOM-killing desktop helpers, load1 31 to 40). Each hit the spec watchdog once and passed alone:

- `the repository is not a spec fixture has no example generated from a scan of repository content`
- `refusal width discipline excludes the lua eval source that shares a file with the rail's own refusals`
- `A project's own tests inside the workspace profile passes the fence crate's tests, none of them skipped` (retired 2026-11-18 with its sibling, see below)
- `Lain::Frontend::Neovim the inbox's open gesture, end to end opens the set under the cursor in lain://question when the human presses enter`

Two other hook runs that day went red on 13 and 36 starved examples across unrelated files under the same memory pressure. With swap full, the landing ran green at `LAIN_SPEC_WORKERS=8`.

Added 2026-11-20, from the round 30 fix run. Each was red once and green on a re-run:

- `Lain::CLI::HumanReplies a run interrupted while a question is outstanding closes the ghost's read on the next surface without waiting for a line`: STUCK at 30 s in a landing suite at load1 8.3. Green alone, and its file with the failing seed (59294) green 3 of 3 on the base and on the card.
- `Lain::Daemon with the daemon opted in inherits no descriptor from the lain that started it`: the descriptor helper lists `/proc/<pid>/fd` and then reads each link, and an fd that closed between the 2 raised ENOENT. Red in 1 landing hook, green on the retry.
- The Rust test `supervisor::two_starts_at_a_stale_spawner_both_fork_from_1_fresh_spawner` (crates/lain-daemon): red once in a reviewer's mutation run under load, green in every other run that day.

Not a flake, from the same run, and fixed in it: `Lain::CLI::Wiring` "sends a finished agent's notice after the delay, through the terminal and the feed" was red whenever the runner sat in kitty, because the notifier picks its escape from `KITTY_WINDOW_ID` and `TERM_PROGRAM` in the real `ENV`. `spec/support/terminal_env.rb` now drops both before the suite, and a spec that wants a terminal stubs `ENV`. A red under that name again is a regression.

Not a flake, from the same run: `A project's own tests inside the workspace profile passes the fence crate's tests, none of them skipped` fails with "path must be shorter than SUN_LEN" when `TMPDIR` is long, because the fence's socket lives under it. Keep `TMPDIR` short (`$HOME/tmp/lain/<short>`) before reading that red as a regression.

A live demonstration of why this list is by NAME and not by line: `buffers_spec.rb:329` was recorded by line in an earlier chunk, and one card in this one moved that same example to `:417` by adding 88 lines above it.

### Retired flakes, with the fix that ended each

Keep a retired name here so a later red under it reads as a regression, not as a known flake.

- 2026-11-22: `Lain::Supervisor as an actor reactor the bounded drain over a mixed fleet an actor's own captured Async::TimeoutError is not misread as the drain's bound` (listed since 2026-09-11). It was never a flake: the example was `pending` on a real defect, so its expected failure was read as a red; the Drain's bound now raises its own `Supervisor::Drain::Expired`, so an actor's own `Async::TimeoutError` settles as that actor's failure, and the example runs unpended. Its 1 timeout of the 60s window on 2026-10-19, beside about 20 agents, was never explained, so a repeat is a regression to chase.
- 2026-11-22: `role_prelude_wiring_spec`'s `sends no more than Anthropic's 4 cache_control blocks for a long-lived role child` (recorded red 2026-09-11, 2026-10-28 and 2026-11-22). Never a flake: the example was pending from 2026-07-17 and counted 5 on every run, and each "red" was its expected failure in the Pending section, read as the run's failure (on 2026-11-22 the real one was a `project_dir_spec` locator example). The 5 was a real defect: a role child's system carried its persona's mark and a 2nd on the role tail, so a long one was refused at encode. `Context#cache_marked` now keeps exactly 1 system mark, and the example runs unpended.
- 2026-11-22: `a stalled stream under an Async reactor two concurrent streams, one of them stalling raises the stall in the fiber that owns the dead stream` and `a stalled stream under an Async reactor two healthy streams interleaving lets both finish, each with its own content` (`Errno::ECONNRESET` in `StreamingUpstream::Chunk#emit`, green alone and with the failing seed on the base). A client that had left made the upstream's next write raise in its connection thread, and `stop` joins that thread, which re-raises it over the example's own verdict; `StreamingUpstream#serve` now treats EPIPE and ECONNRESET on a write as the client leaving.

- 2026-11-22: `Lain::Frontend::TTY a note rendered while a prompt is drawn keeps vi's mode and cursor, so a command typed after the note does what it says` (red once in a landing hook, seed 64684, `Errno::ENOTEMPTY` from the `Dir.mktmpdir` cleanup, green 3 of 3 alone). `kill-server` only signals the tmux child, which could still be writing into the dir as mktmpdir removed it; the group's `around` now waits, bounded at 10s, for the server and the pane's process to exit, and a child made to outlive the HUP by 0.5s while writing failed it every time before and never after.

- 2026-11-22: `Lain::CLI::Up degrading loudly writes a status-right that names the state file and depends on no optional binary` (seed 20641). It asserted the status-right never contains "jq", and the status-right embeds a random tmpdir name (`state-home-20261121-4181741-a8tnjq`) whose suffix can spell it. The example now uses a state path that always contains "jq" and matches `jq` as a whole word only after the path is removed.
- 2026-11-18: `A project's own tests inside the workspace profile passes one spec file with the example count an unconfined run reports` (STUCK at its 60 s budget in 2 landing hooks, 13.1 s and 13.0 s of CPU at load1 28.3 and 23.8; the 2026-11-10 `starvable:` fix did not apply, because the watchdog read was right: the worker was running). The copy in the example's setup was most of the cost: it copied every entry of the checkout but 5, and the main checkout's ignored `apps/lain-remote/target` holds 9 GB of build output since 2026-11-12. That copy took 7.8 s of CPU and 15.3 s of wall on a quiet box. The example now copies only the 11 entries the 2 nested runs read, 0.2 s of CPU and 0.4 s of wall from the same checkout. The same fix covers its sibling `... passes the fence crate's tests, none of them skipped`, which ran inside the same copy and was red in a landing hook the same day.

- 2026-11-17: `lain-rpc tests::an_overflow_warns_once_for_its_connection` (left 1, right 0; red in 2 landing hooks of the lain-daemon run). A real race: the test counted warnings with a scoped `set_default` subscriber, and tracing caches each callsite's interest process-wide, so another test thread could cache the shared warn callsite as never enabled. It failed 28 of 80 runs under 8 CPU hogs. The test module now installs 1 global subscriber and counts per thread: 0 of 100.
- 2026-11-17: `Lain::ProjectDir one locator for every governed path is the only place lib/ composes a governed path` (the 30 s watchdog, twice, at load1 23.5 and 33.7). Its cost was 2 tree walks and re-walked subtrees, not the parse. The scan now indexes once and runs 1 example per lib group: 8.1 s in 1 example became 5.1 s for the file, worst example 0.7 s, with the same findings.
- 2026-11-17: `Lain::Exec::Local a stop leaves no side effect from a String command stopped before it got there` (red in a landing suite 2026-11-16; one of the 2 unnamed `Lain::Exec::Local` entries above). A real race, not timing: a stop signalled the stage's process group, which `setsid` makes only after the stage starts, so a stop in that window met no group and the command ran on. Three of 100 runs under load left its file. A stage with no group yet is now signalled by pid: 0 of 100.
- 2026-11-12: `Lain::Tool::Offload keeps a sibling fiber running while the work holds its thread` and `... while the work never gives up the lock between threads` (red 2026-10-18, 10-19, 10-21 and 10-31, and at tick gaps of 0.302 and 0.312 against a 0.3 bound). Both judged ticks against a wall-clock share. The work now holds its thread until the sibling has ticked 5 times, so finishing proves the sibling ran, and no time is compared.
- 2026-11-12: `Lain::Tools::Subagent async fan-out out-of-order completion lands in one ordered user turn gathers every result into ONE user message in tool_use order, however the children finish` (red twice on the 2026-09-21 list, and again in a landing suite on 2026-11-12). The provider ordered the children by sleeps of 60, 40 and 20 ms, which load reorders. Each child now waits for the child called after it to finish, so the reverse order holds under any load.
- 2026-10-30: `draining one chore through a lease, a headless chat and lain land lands the chat's commit on the main branch` and `... marks the chore done with the landed sha and the session path` (both red together on 2026-10-29 at load 26 and on 2026-10-30, seed 59949, the chore marked "no drainer"). Likely cause, not reproduced under added load: `lain land wait` gave up after 5s with no live drain lock holder, and a drainer still booting under load holds none yet. The enqueue now records the started drainer's pid in the home, and a live one counts for up to 60s of boot.
- 2026-11-11: `Lain::Tools::Subagent a one-shot child that does not finish when the ceiling stops a child that had read files and written notes keeps the ceiling message and the last text block when the lists are huge` (watchdog STUCK at 30.8 s and 30.3 s at load 25 to 29, 9 s of CPU alone). It drove 5000 real `grep` calls through the loop; it now builds the child history and calls `Answer#partial` directly, about 0.1 s, keeping every assertion.
- 2026-10-30: `the repository is not a spec fixture has no example generated from a scan of repository content` (watchdog STUCK at 30s on 2026-10-28 twice, 2026-10-29 and 2026-10-30, about 16 s of CPU at load 20 or more). The scanner now skips the syntax walk for a file whose text cannot hold the shape, and walks the rest once instead of 5 times, so the scan takes about 5 s alone, down from about 9.
- 2026-10-30: `astgrep::tests::the_cancellable_walk_finds_what_find_all_finds_over_this_repositorys_ruby` and `treesitter::tests::the_cancellable_query_finds_what_the_plain_query_finds_over_this_checkouts_sources` (red 2026-10-29 and twice on 2026-10-30, `NotFound` in `read_dir`, after a full suite and inside a pre-commit run). A directory under the live checkout vanished between listing and reading. A poll of directory creates and deletes over a full `pspec` in a worktree saw none, so the writer was not found and is not shown to be a spec. `test_sources.rs` now skips a vanished directory or entry and still panics on any other error.
- 2026-10-30: `plugin/tmux lain.tmux against a real tmux server survives an install path with spaces in it` and `... renders 'lain: no state yet' when the pane's project has no state file` (red on 2026-10-18, 2026-10-28 and 2026-10-30, seed 44048, "pane session ... outlived its tmux server"). The teardown waited 10s for each pane's session to empty and raised; it now sends TERM, then KILL after 0.2s, to every process in each pane's session, so a slow or HUP-ignoring child is ended.
- 2026-10-28: `Lain::Tools::WebFetch an HTML page comes back as readable text refuses a page of more nodes than the walk budget quickly, naming raw` (red 3 times at about 3.05s against a 3s bound, load-induced). The example now counts the nodes the walk visits instead of timing it.
- 2026-10-23: `Lain::CredentialPatterns the credential assignment shape scans a 100 KB line in linear time for each gated password shape` (red in 4 pre-commit suites at loads 0.7 to 28, 0.25 to 0.32 s against a 0.2 s bound). The bound became a 100 KB over 10 KB time ratio under 30, so it judges growth and not the machine; its sibling "on both sides" moved with it. It reddened again on 2026-10-30 as that ratio (31.7 against 30, green alone and on base). Ruby cannot judge some of these shapes linear (some use a backreference or an atomic group inside a lookahead, which defeat `Regexp.linear_time?`), so both examples were deleted and the timing moved to the `credential_scan_assignment` and `credential_scan_gated` rows of `bin/hot-path-bench`, held to a ceiling.
- 2026-10-22: `Lain::Ext::Fuzzy#match on another thread lets the calling thread keep ticking while it matches` (red once on 2026-10-21 with a p99 tick gap of 28.7 ms against an 8 ms bound). The spec judged a released GVL by an absolute tick gap, which a loaded box inflates. It now judges the longest gap's share (`spec/support/gap_share.rb`), and the same change moved its siblings in the bm25, astgrep, treesitter and offload specs to that measure. Green in 10 of 10 interleaved full `pspec` runs at 12 workers on a quiet box (5 before the fixes, 5 after).
- 2026-10-22: `Lain::Sensitivity::Policy#mask_paths against #judge, name by name does 1 realpath per directory over a plain listing, with judge's verdicts` (156 `File.realpath` calls against at most 21, red once on 2026-10-21). The stub counted calls from every thread in the worker, so a thread an earlier example left running inflated the count. It now counts only the example's own calls. Green in the same 10 of 10 runs.
- 2026-10-21: `Lain::CLI::EpicSubmit Ctrl-C through the real CLI exits 130, with the fail-closed decision already journaled` (red 2026-10-18 and 2026-10-21 in pre-commit suites, exit 130 with no `gate_decision`). It was a product ordering bug and no spec race. Under Async a SIGINT never reaches the gate as an `Interrupt`; the stop becomes an `Async::Cancel` in every task. `Prompt#ask` yielded while its write was parked in the io_uring hook and again at its reader's spawn, after the `[y/N] ` bytes had reached the pty, and a cancel raised inside the ask journals nothing by design.

  The prompt now draws and spawns its reader under `defer_stop`, and a stop that lands there is moved to the park, which journals it. An example stops the task while the prompt's write is parked. The real-CLI example never reproduced the red in 90 loaded runs; that example and a real-SIGINT probe are the proof.
- 2026-10-17: `a plain chat's inline prompts over a real terminal a prompt the approval window decides ends its line with who decided it and how, and a y typed afterwards decides nothing` (red 2026-10-15 at seed 50146 and on a later landing at seed 17844, both with `expected ["\e[>4;0m\r\r\n"] to all match /\A\s*\z/`). It was no lib race, and it is not the 2026-10-02 one below, which stays fixed: the row it reddened on was blank to a human.

  When the window closes, the fixture's raw `SETTLED` can end the prompt's row, the pump's read, stopped on its own fiber, then writes the Shift+Enter reset `\e[>4;0m`, and only then does the closing note start with its own CRLF. The spec's `text` stripped CSI sequences with a `?` prefix but not `>`, so that invisible reset read as text on a row that has to be empty. `text` now strips every private-parameter prefix. A probe that delays the closing note by 100ms failed 3 of 3 with the old filter and passed 3 of 3 with the new one.
- 2026-10-17: the vsock harness's `VsockAvailability.available? leaks no descriptor across repeated probing` (listed above as load-induced since 2026-09-11). The spec went with the vsock tier, whose listener, `Transport::Vsock` and `:vsock` tag were deleted. Nothing opens an `AF_VSOCK` socket now, so a red under that name cannot recur.
- 2026-10-17: `Lain::Frontend::InputPane when the chat says nothing is published rewrites in place again once a whole redraw followed the resize` (seed 25833, `Expected nil to eq "\e7\e[1A\r\e[Kmodel:1s\n\e8"`), and the same race in `... while a prompt is up redraws a header that grew a row over the old one at a prompt with nothing typed` and `... redraws a header that lost a row over the old rows at a prompt with nothing typed`. A lib race: a header frame that arrived after a redraw but before the pump opened its read was dropped, because a read not yet open reads as touched. The pane now holds a declined header (`InputPane::HeldHeader`) and draws it on a later tick. A probe that delays the read's open by 100ms failed all 3; they now pass.
- 2026-10-17: `Lain::Frontend::InputPane when the chat says nothing is published echoes a draft itself, the terminal echoing nothing` (`Expected "abc\e[?2004h" not to include "abc"`), and the same race in `... sends a pasted segment longer than a cooked terminal's line whole, then the line typed after it` and `... rewrites the header in place below an answered approval's echo, and redraws whole at the next prompt`. The spec took the `idle` frame as proof that the idle reader had uncooked the terminal, but that reader first waits for the pump's lock, so a key typed early was echoed by the cooked pty (and a cooked line cut the paste at 4095 bytes). The specs now wait for the reader's bracketed-paste switch. A probe that delays the mode switch by 100ms failed all 3; they now pass.
- 2026-10-17: `Lain::Frontend::InputPane a signal the human sends the pane discards a draft held mid paste on Ctrl-C and sends the chat no signal frame` (`IO::TimeoutError` from `chat.gets`). Its settle on an echo that an open paste never draws always timed out, and the key typed after the Ctrl-C could reach the pane before the signal did and land in the paste. It now waits for the reader to take the bytes, and for a 2nd Ctrl-C's signal frame, before it types. A probe that delays the pane's signal handling by 100ms failed the old example and passes the new one.
- 2026-10-16: `Lain::Frontend::LineEditor#read, and the submit predicate asking the terminal for Shift+Enter resets at EOF`, `... resets after an exception` and `... writes the request before the read and the reset after it, on a terminal` (red 6 times across seeds 63896, 48225, 9063 and 61060, with `expected "\e[>4;1m" to end with "\e[>4;0m"`). The spec read the PTY master once with `read_nonblock` as soon as the slave closed, and the kernel hands a slave's write across from deferred work, so under load the reset had not landed yet.

  The proof is forced: with every slave write delivered 100ms late, the old specs failed 5 of 13, the fixed ones 0. `PtyBytes` in `spec/support/pty_bytes.rb` now waits for the bytes it expects, or reads to the EIO that follows the last of them. The same read was in `StdinPump`'s `asks the terminal for Shift+Enter around a command> read` and `InputPane::Uncooked`'s bracketed paste example, which use it too.
- 2026-10-16: `Lain::Frontend::TTY a note rendered while a prompt is drawn holds the note while the prompt is drawn, keeps the typed words, and prints the note as the prompt closes` (red once in a whole-suite run, worker seed 45006, with `Expected 23 to be < nil`, and green 3 of 3 alone with that seed). It waited for the note to show and then looked for the next `you>`, which the child draws a moment later. With the child made to pause 0.5s before its second prompt it failed 3 of 3. It now waits for a `you>` below the note before it reads the screen.
- 2026-10-16: `Lain::Telemetry::LandingBatch answers landing_batch to no other Journalable` (red once in a hook suite, worker seed 13907, with `undefined method 'split' for nil`). It walks `ObjectSpace` for every Journalable and read each one's name, and an anonymous Journalable an earlier spec in the same worker left alive has none. With one kept alive it failed every time; it now skips a class with no name, as `journal_discriminators_spec` already did.
- 2026-10-08: `typing in a real cockpit while the model is busy consumes the question when an ask parked on it is stopped` (red in 3 hook suites, with `"/stop" shown in the input pane never held within 10s` in an example that took 6 to 8s). `WaitUntil` looked at the condition a second time to decide whether to raise. The input pane echoes `/stop`, then erases that row to draw the `command>` prompt and redraws the line under it, so a second look that fell in that gap raised at once.

  The natural rate was 0 of about 80 runs alone under modest load, so the proof is forced: with a redraw gap injected into the pane and a 0.6s stall injected before the second look, the old wait failed 10 of 10 and the fixed one 0 of 10. The wait now answers for the look that held.
- 2026-10-03: `the deletion map booting without a capability does NOT load when a forced dependent is left behind` (red in a hook suite, green alone). `BootWithout#boot` read any output containing "ok" as a clean boot, and a failed boot's backtrace names its `Dir.mktmpdir` path, whose random suffix held "ok" in 81 of 20,000 names. A forced "ok" in the name reproduced it every time. The boot is now judged by the child's exit status.
- 2026-10-03: `Lain::Frontend::TTY a note rendered while a prompt is drawn loses and repeats nothing typed while notes keep arriving, and prints them all as the prompt closes` (red in a hook suite, green alone). The spec wrote its `notes` file in place while the child polled for it and read it at once, so the child could read it empty and raise `TypeError` on `Integer(nil)`. A 0.2s pause between create and write reproduced it every time. The spec now writes a temp file and renames it into place.
- 2026-10-02: `Lain::Frontend::Neovim lain://timeline reflects a turn commit does not touch lain://timeline for an event that names no turn` (seed 7814), and the same shape seen in `51_thread_spec`'s `restores a live diff with the folds the human was reading`. nvim creates its socket file before it listens, so a connect in that gap, from the spec or from lib's own `Socket.unix`, got `ECONNREFUSED`. `HeadlessEditor.start` now returns only once the editor accepts a connection, retrying a refusal until `WAIT`.
- 2026-10-02: 3 examples in `62_approval_spec.rb`: `... resolves one unwrapped call per answerable row, in queue order, for two parked approvals` and `... carries the wrapped command unwrapped, with the rendered lines unchanged` (red solo and in suites since 2026-08-28), and `the repl's own wiring puts a parked approval in front of the human renders it in lain://approval and answers it with y, with nobody having wired the view by hand`, never recorded here. The helpers read `lain://approval` before the buffer existed (`Invalid buffer id: -1`), and a presser thread that died left the example to wait out a 30s Timeout.

  The helpers now answer nil until the buffer exists, inside a bounded poll, and the presser re-raises into the example and is killed when it ends. Under `bin/suite-load`, 30 rounds: the old file failed 6, the new one 0. A general rule from the old entry stands: a path in a flake entry is a convenience, the NAME is the key, so when a file moves, repoint the path and keep the name.
- 2026-10-02: `Lain::Supervisor tracking a one-shot task drops the row when the task is stopped, and when it fails`, red on `main` under suite load and never recorded here before. The row leaves from a task of its own, and a failing task yields again to log its unhandled-exception warning before it finishes, so one `task.yield` could check before the row left. It now waits until the registry is empty, bounded at 5s.
- 2026-10-02: `Lain::Frontend::InputPane a signal the human sends the pane goes to the chat rather than interrupting the pane` (seeds 38780 and 1410). `after` killed a pane thread without joining it, so that thread put RSpec's SIGINT handler back late, inside a later example (see the unjoined-thread trap above). `after` now joins it, with a bound. Under `bin/suite-load`, 30 rounds: the old file failed 3, the new one 0.
- 2026-10-02: `62_approval_spec.rb`'s `the repl's own wiring puts a parked approval in front of the human announces the second gated call too, once the editor answered the first, and asks y/N about neither`, red in a landing under suite load, green alone; its sibling `... answers it with y ...` shares the window, so part of what the entry above credits to the helper fix was this race.

  It was a lib race and no spec fault: `ApprovalView#prime` runs on the drain thread and nothing ordered it before the watch fiber's sweeps, so a late prime drew the empty list over a parked call's row, and the view's record of what it last drew kept any sweep from redrawing it. Drawing is now under one Monitor and a prime redraws what a sweep already drew. Under a 4-core load the old code failed 6 of 160, the fix none; under `bin/suite-load`, 30 rounds, the fix 0.
- 2026-10-02: `plain_chat_prompt_guards_spec.rb`'s `a plain chat's inline prompts over a real terminal a prompt the approval window decides ends its line with who decided it and how, and a y typed afterwards decides nothing`, red since 2026-09-20 under load. A lib race: the approval reader runs nested under ApprovalPolicy's task, and when the window closed, the closing note waiting on the writer lock was stopped twice more (as the outer task finished, and from `read_until_decided`'s ensure) while Async's `defer_cancel` holds back only 1. The note died mid-write and the error was swallowed. The reader's ensures now run under `defer_cancel`, only a running reader is stopped, and a failed close reaches the channel as a rendered diagnostic. Under `bin/suite-load`, 30 rounds: the old code failed it 2 times, the fix 0.

### Environment-bound and other named failures

- The `:ollama` live suite has a KNOWN-RED example, and it predates this chunk. `Lain::Provider::Ollama temperature-0 reproducibility produces identical text across three warm same-seed runs` (`spec/integration/provider/ollama_spec.rb`) fails on this box: 3 warm same-seed runs at temperature 0 give 3 distinct completions. Measured 2026-08-24 at HEAD and at `f63dae70`, the commit before the ollama-cloud chunk began, so it is environmental or server-side and no card caused it. It only runs under `LAIN_OLLAMA=1`, which is why no default suite sees it.

  It is recorded by NAME so the next person to run the live tier does not read it as something they just broke. The consequence: neither ollama arm is currently a determinism-comparable bench arm on this machine. The cloud arm's non-reproducibility is measured and expected (`references/ollama/cloud.md`), and the local arm's is a real defect that is still open. Do not draw a variance conclusion from either without re-establishing this first.
- `rubocop -a` rewrites UNTRACKED files too, and there is no copy to restore. A bare `bundle exec rubocop -a` inspects the whole working tree, untracked files included, so scratch scripts, probe specs and anything else sitting untracked in a worktree get autocorrected in place. Safe cops only, so behaviour does not change, but the file is no longer what its author left, and an untracked file has no `git checkout` to undo it.

  Observed 2026-08-24 when a lint pass rewrote 3 of a review agent's probe scripts. Scope the command (`bundle exec rubocop lib spec exe`) when the tree holds work you have not committed. This is separate from the never-name-a-`.toml` rule below, which is about what gets parsed as Ruby.

  A second occurrence, 2026-09-21, came from a computed file list and not a bare invocation. An agent ran `rubocop -a` over `git status | awk '{print $2}'` to lint only what it had touched, and that list included the review panel's own untracked probe scripts sitting in the same worktree. The pass autocorrected 15 offenses across 2 of them, with no git copy to restore from.

  Piping `git status` into rubocop scopes the command to everything untracked in the tree, including work that belongs to somebody else reviewing alongside you, and not to YOUR changes. Vet a computed file list before handing it to `-a`, the same as you would a bare invocation.
- Added 2026-09-20, from a chunk running 3 implementers and 3 reviewers at once. Both went red under that load, in more than one run, and both pass alone on a quiet box. Both assert against a wall clock, which is the shape that fails first when a box is loaded:
  - `Lain::Frontend::HeadlessEditor #reap escalates to KILL when the editor ignores TERM, instead of waiting on it forever` (it read `expected 0.32 to be between 2 and 5`: the grace window elapsed while the box was busy, so the assertion measured the load and not the reap).
  - Its sibling `HeadlessEditor.start gives the editor back when the socket never appears and the editor ignores TERM`, seen later the same day and green 6/6 alone. Two of the 6 examples in that one file wait on a wall clock, so treat the whole file as load-sensitive, beyond these 2 names.

  A third, `plain_chat_prompt_guards_spec`'s "ends its line with who decided it and how", is retired above: it was a lib race, then a spec filter, never the clock.
- Added 2026-09-20 on a second sighting, from 2 agents in 2 runs, both under a sibling suite, and 110/0 alone each time: `Lain::Frontend::TTY a note rendered while a prompt is drawn holds the note while the prompt is drawn, keeps the typed words, and prints the note as the prompt closes`. It is `:seam`-tagged and drives a real tmux, which is the family every entry above belongs to.
- Also 2026-09-20, and a first sighting with no established mechanism, recorded by name now so a second is recognised as a second: `Lain::Provider::Ollama::Transport spooling into a WAL frame does not tee a failed response's body into the frame`. It went red in a `pre-commit` suite run alongside `worktree_handback`'s known teardown race, and both passed alone immediately after (40 and 94 examples, no code changed between). The commit that surfaced it touched only `lib/lain/epic/`, which is the clearest evidence it was the load and not the diff.
- Added 2026-09-21: this one was NOT contention, the opposite lesson from every entry around it. `spec/lain/seams/qa_sandbox_pane_resolution_spec.rb` produced 3 failures under a loaded box (`pgrep -cf tmux` reading 10 during one sweep; it counts live tmux panes box-wide by design), and 5 separate agents filed it as exactly the family this whole list documents: a spec that reds under load and passes alone. It does neither.

  The 3 failures reproduce SERIALLY, on a box with no tmux server running at all, which contention cannot explain. Run against `.claude/skills/manual-qa/scripts/qa-sandbox.sh` from before commit `d5d08b87`, the same 3 examples pass 5/5.

  `d5d08b87` narrowed the pane resolver so only `lain chat` counts as a chat pane and not any lain exe. That was correct, since the cockpit's own input pane is the lain exe too, and counting it made every stock cockpit ambiguous. But the spec's wrapped-chat fixture still launched a bare `lain`, so the fixture went stale under a resolver that had just gotten stricter.

  That commit staged no Ruby, and the pre-commit `ruby-checks` hook is `types_or: [ruby, rust]`, so the hook's own suite run never executed against it. A shell script a spec drives is invisible to a file-type filter keyed on what was staged and not on what the test exercises. Fixed in `2a39fd73`, which makes the fixture run `lain chat`.

  Two lessons. A spec's own SHAPE (drives real tmux, counts panes box-wide) is not evidence that a given red IS contention; that takes a serial run on a quiet box, which none of the 5 agents ran before filing it. And a hook's language filter guards the files it inspects, not the behavior a Ruby spec drives through them.
- Added 2026-08-24, found by a 9-run `spec:flakes` sweep: `Lain::Tools::ReadFile refusing a read that is too large to hand back reads at most a bounded probe of the file it refuses, and never slurps it` went red in 1 run of 9 and green in the other 8, on an otherwise quiet box. One observation, so the mechanism is not established. It is recorded by name now so the second sighting is recognised as a second and not mistaken for a regression.
- RETIRED 2026-09-12: `rake spec:flakes` exited 1 on EVERY invocation, and the harness was the cause, not the suite. `bin/spec-flakes` rewrote `$HOME` and `XDG_*` inside each forked run, which collided with the spec group that asserts on `$HOME`. Five examples in `Lain::Paths a $HOME that is not absolute` (`refuses a HOME of '.'`, `refuses a relative HOME`, `refuses an empty HOME`, `guards config_home and cache_home by the same rule`, `accepts a HOME of '/'`) plus `Lain::Frontend::Neovim the thread pane's write refusal delivers a nothing-typed write refusal on the review rail` failed in all 9 runs, deterministically.

  `rake pspec`, which does not rewrite `$HOME`, was green at the same commit across 3 runs. So a red `spec:flakes` was never evidence of anything until those 6 were subtracted, and the tool could never act as a gate while its own isolation fought the specs that assert on the variable it rewrote. Measured 2026-08-24 during the ollama-cloud chunk. The task and `bin/spec-flakes` were removed and not fixed, because the defect was in the harness's own isolation. Fixing those specs would have hidden the harness's `$HOME`/`XDG_*` rewrite and corrected nothing.
- RETIRED BY EVIDENCE 2026-08-24: the teardown shape is fixed at the fixture. `git commit` and `git merge` spawn a DETACHED `git maintenance run --auto --quiet --detach` (seen under `GIT_TRACE=2`), and that process outlives the example. `Dir.mktmpdir`'s teardown then races it and dies on `Errno::ENOENT` under `.git/objects/`, which RSpec blames on whichever example the `around` hook was closing.

  `SeedRepo::PINS` now sets `maintenance.auto=false` and `gc.auto=0` in every seeded repo, so no second process exists to race. Measured on one box, same minute, with a standalone reproducer: 101 teardown failures in 400 unpinned cycles, 0 in 400 pinned. Either pin alone suffices, and both are kept because `maintenance.auto` is git 2.29+. `rerere.enabled=false` is pinned with them for hermeticity: it is a common `~/.gitconfig` setting, and leaving it ambient made this suite's behaviour depend on whose box it ran on.

  This retires the teardown shape only. The `we\nird.txt` example below and the `#continue refuses a resolution that is not one` pair above are separate observations that this fix does not explain, so the FILE rule above still stands for them.
- Added 2026-08-19, a SECOND example in that same file and not the teardown shape above, which is why the entry above was not enough to recognise it: `Lain::Isolation::Worktree::Handback a conflicted path git would otherwise quote names "we\nird.txt" as it is on disk, and can conclude it`. Reproduced deliberately (2 of 2 full `rake pspec` runs at 14490 examples, 11 `nvim` processes live from other worktrees; run 2 red, green in isolation).

  It surfaced during a chunk that never touched isolation, and cost a card an unexplained red it recorded and did not smooth over. That was the cheapest possible outcome, but only because the count reconciled (+5, exactly the examples that card added), so truncation was ruled out first.
- The `up_spec` entries are RETIRED as of 2026-08-18; both had real causes and both are fixed. A stale "known flake" is worse than none, because it reads "not a regression" to the next person who sees them red. `threads -- chat args ...` and `leaves the global theme untouched ...` were independent witnesses of one production defect: `keep_failed_pane` wrote `remain-on-exit` as the LAST thing `configure_session` did, 4 tmux calls after the pane was already running chat. The fastest crashes died into a window with no option yet and took the server with them (9 losses in 20 forced repeats; 0 after).

  They failed as a RAISE with distinguishable messages, `no server running` and `no such session: lain`, which is how the 2 were told apart. `--nvim cockpit splits ...` was a different defect: a lossy `split` that made a dead pane's cwd read back as the pane's own command string. `leaves the global theme untouched` also had a second cause: a scratch `-L` server still sources the user's `tmux.conf`, whose background `tpm` rewrites global `status-right` at 300-500ms. That is now pinned with `-f File::NULL`.
- `buffers_spec`'s `re-attach is idempotent: no duplicate commands, and motions/syntax still work` is RETIRED as of 2026-08-23. It had a real cause and it is fixed, and both halves of what this list said about it were wrong: it was neither load-induced nor a passer in isolation. Measured alone on an idle box it failed 7 of 20 runs, always on one of 2 values, `Expected [1, 0] to eq [2, 0]` (the `]]` motion did not move) and `Expected "" to eq "lainRole"`.

  A state dump at the failure showed every idempotence claim the example makes still TRUE: same `bufnr`, `]]` still buffer-local, `filetype` still `lain`, `lainRole` still defined. Only the buffer's CONTENT was wrong: `["(no turns yet)"]` where the example had just injected 2 lines.

  The example's barrier was `wait_until { bufnr("lain://timeline") != -1 }`, which is a real wait for a FIRST attach and nothing at all for the second, because the buffer is already there, which is what re-attach idempotence means. So the newcomer's at-rest prime, posted after `#run` returns on the drain thread, landed on top of the injection at a different point every run. The fix waits on the newcomer's own `User LainRender` instead. Forced deterministic both ways with a gated `Surfaces#prime` (6/6 red before, 6/6 green after); 25/25 green since.

  The product was not at fault, and the reason is liveness and has nothing to do with priming. `Frontend::Neovim#run` tears down in an `ensure` (`@channel.close`, the joins, `@rpc.stop`), so the first lain's channel is dead before the second attaches. `channel_alive(owner)` is false, runtime.lua takes the re-attach path and not the `{ refused = "owned" }` one, and the at-rest prime is the NEW OWNER's.

  That is the sequential re-attach a human performs (quit lain, start another in the same nvim), never a live double attach. A live double attach is refused, and refused because a newcomer's empty prime replacing a running lain's rendered views is one of the 3 harms runtime.lua's head measured. Both halves are pinned by `spec/lain/frontend/neovim/runtime_spec.rb`'s "one lain per editor".

## Watchdog and fiber traps

- For a `SpecWatchdog::Stuck`, even the NAME can be unreliable: read past it to the `around` chain before trusting it. `spec/support/watchdog.rb` is deliberately the OUTERMOST `around` (so it can see a hang in an editor spawn and in an example body), which means it also wraps every FILE's own `around` blocks. That is shared fixture setup that runs before every example in that file, whether or not that example's own body touches the thing which stalled. A strike during that setup still reports the example that happened to be current, by exact name and line, like any other `Stuck`.

  Two names were chased as flaky commit-hook failures with nothing in their own bodies that could hang: `spec/lain/cli/command/review_spec.rb`'s `answers its own usage when no target was named` (its body calls no git at all) and `spec/lain/cli/review_spec.rb`'s `reviews against the ref --base names instead, when it is given one`. Neither is a bad test, and neither reproduced by name.

  What DID reproduce, 2026-08-23, twice in one hunt, is the MECHANISM, on their immediate NEIGHBOURS in the same describe blocks, driving the identical shared code. `command/review_spec.rb`'s `around` block does `git branch -M main` before every example in the file, and it stalled 61.4s inside `Mixlib::ShellOut::Unix#configure_parent_process_file_descriptors`. `cli/review_spec.rb`'s `LocalBranch#merge_base!`, the same call target 2's own body drives, stalled 61.3s inside `IO.select`. Both were caught live as `SpecWatchdog::Stuck` naming the wrong example.

  The trigger needs no other agent: `git commit` runs `rake check`'s `multitask`, fanning `rubocop` over the whole repo and `parallel_rspec` (one worker per core) out together, which is real structural contention on its own. So a `Stuck` on one example is evidence against that example's FILE and its shared fixtures, and says nothing about that example's own body. It is the same "the unit is the FILE" lesson `worktree_handback_spec.rb` taught above, arriving through the watchdog instead of through leaked state.

  Fixed the same day, in the watchdog itself and in neither spec: `SpecWatchdog::Sentry::Starvation` now checks CPU time consumed against wall time and the box's own 1-minute load average. A `Stuck` report leads with "STARVED, not necessarily stuck" instead of "This is a hang, not slowness" when the numbers say the process was never scheduled and not genuinely wedged. It is still loud and still dumps every thread, just accurately labelled.
- Never name a `.toml` explicitly on a `rubocop` command line. `rubocop -a lib/lain/prompt/default.toml` parses it as Ruby and "corrects" it; it silently stripped `format = ` from the prompt format. A bare `bundle exec rubocop` (and so `pre-commit run --all-files`) is safe: the default `Include` patterns do not match `.toml`. An `Exclude` entry does not save you. Verified: `AllCops: Exclude` governs RuboCop's own file discovery and not a path a human hands it directly, so the file is still parsed when named. The only defence is not naming it.

  The rule is general (2026-08-22): naming `docs/devs/toolchain-traps.md` on a `rubocop` command line makes it parse THIS FILE as Ruby and report offenses in the prose. Harmless only because no `-a` was passed. Name Ruby files, and nothing else.
- A `let` read from inside `Sync` deadlocks the reactor, and it looks like a hang in your subject. RSpec memoizes a `let` under a `Mutex`. A `Mutex` acquired inside an `Async` task is owned by the fiber, not by the thread, so the FIRST read of a `let` from inside a `Sync` block parks the reactor's fiber on a lock the example's own fiber is holding, and neither can move.

  What you see is the example sitting at ~0% CPU until `spec/support/watchdog.rb` fires at 30s, with a stack ending in `IO::Event::Selector::URing#select` under `Async::Scheduler#run`. That reads as "my async subject wedged" and gives no hint that RSpec's memoization did it.

  It is the same fiber-ownership branch that trap-hunt cost hours to find in the editor specs. It was found again 2026-08-22 in `ToolDelivery`'s spec, and reproduced by accident by the reviewer's own probe before the fix was applied: a `Mutex` locked by the example fiber answers `owned? == false` when a sibling fiber on the same thread asks. A read of an already-memoized `let` never takes the lock, so the whole fix is to force them before the reactor opens:

  ```ruby
  before { [response, timeline, session, snapshots, journal] }   # then Sync freely
  ```

  The tell that separates it from a genuine hang: the same example passes when its `let`s are turned into plain locals. If a spec drives `Sync`/`Async` at all, force every `let` it touches.
- `Async::Task#wait` on a CANCELLED task does not raise, so `expect { run.wait }.to raise_error` asserts nothing at all. Measured on async 2.42.0, 2026-08-22: after `run.stop`, `run.wait` returns `nil` with `run.status == :cancelled` and no exception, because the task's own handler has already absorbed the `Async::Cancel`. An example written to prove "the interrupt still ended the run" therefore passes for the wrong reason, and keeps passing if the interrupt stops working. Assert the state and the consequence: `expect(run).to be_cancelled`, plus something the run would have done had it continued (a turn that is absent, a response never requested).

  Relatedly, `Task#defer_stop` is a deprecated alias for `#defer_cancel` in 2.42, and it guarantees exactly 1 deferral. `#cancel` defers only while its tri-state guard reads `false`, and a second cancel arriving inside the region falls through to an immediate `Fiber.scheduler.raise`. A `defer_stop` region shields against one interrupt and gives no protection against a storm of them.

## tmux traps

- `remain-on-exit` sent as a SECOND tmux invocation loses the race against a pane that dies immediately: 6 losses in 20. tmux answers `new-window` the moment its SERVER accepts the request, and it reaps a pane on its own event loop afterwards, so a `set-window-option -t ... remain-on-exit failed` sent after the open arrives at a window that is sometimes already gone.

  Measured 2026-08-28 on tmux 3.7b through the real `Mixlib::ShellOut` path, 20 windows running `exit 42`: the open took 8-16ms and the option another 8-18ms, and 6 of 20 read back no corpse at all. Chained into the SAME command list, `new-window ... <command> ';' set-window-option -t =name remain-on-exit failed` as one argv, the loss is 0 in 30, because tmux runs a command list to completion before it processes the pane's death.

  A raw shell loop reproduces the race perfectly well (4/30, 5/30 and 3/30 over 3 runs, about 13%, comparable to the Mixlib path's 6/20), so any harness will do. Measuring the wrong thing will not show it: asking whether `set-window-option` itself was refused answers 0/30 even while a third of the corpses are already gone, because on a window tmux has destroyed the option call still succeeds against the session. Measure the status you can read back, not the exit code of the call that was supposed to preserve it.

  This qualifies the older entry above about `keep_failed_pane` writing `remain-on-exit` last: ordering the option EARLIER was the right fix there and is not sufficient here. `Up`'s chat pane runs a REPL that lives for minutes; a fleet window runs a command that can exit in under a millisecond, and nothing short of the same invocation is early enough.

  Chaining costs one thing: a non-zero exit no longer says which half failed. `-P` recovers it for free. tmux prints the new window's target only when `new-window` itself ran, so an empty stdout beside a non-zero exit means the OPEN failed (be loud) and a printed target means only the option was refused, which is what a tmux older than 3.2 does with the `failed` value.
- `display-message -p` answers for the CURRENT pane when its target does not exist, and exits 0. Asked about a window that is gone, `tmux display-message -p -t 'lain:=nope' '#{pane_dead}:#{pane_dead_status}'` does not fail and does not answer empty. Measured on 3.7b it printed `1:42`, ANOTHER window's corpse status, at exit 0. Any liveness or exit-status check built on it will confidently report an unrelated pane's fate as the one you asked about. `list-panes -t <target> -F ...` refuses instead (`can't find window: nope`, exit 1), and that refusal is the correct answer; use it for every question about a specific window's pane.

  Two more edges on the same call, both real. `Mixlib::ShellOut#exitstatus` is `@status&.exitstatus` and so is nil for a signalled client, where `.zero?` raises `NoMethodError` out of whatever is asking; use `&.zero?`. And parse the answer so it fails CLOSED (`survived = dead == "0"`, not `dead != "1"`): an unreadable reply becoming "healthy" is the one direction a liveness check must never round toward.

  Related, and it bites every scratch-socket spec in this repo: `kill-server` does not unlink the socket. `/tmp/tmux-1000/` held 13,668 leftover `*-spec-*` inodes when this was found. Unlink `File.join(ENV.fetch("TMUX_TMPDIR", "/tmp"), "tmux-#{Process.uid}", socket)` in the same `ensure` that kills the server.
- A tmux pane inherits the spec runner's PATH, so a pane spec can pass on a binary production never sees. tmux hands a new pane the environment of the SERVER it runs under, with exactly one carve-out among the names you set. Measured on 3.7b, setting the same name on the server and on the client that asks for the window (`TERM`, `TMUX` and `TMUX_PANE` are outside this: tmux synthesises those and does not inherit them from either side):

  | set on | the pane reads |
  |---|---|
  | server vs client `PATH` | the CLIENT's |
  | server vs client `LAIN_MODEL` | the SERVER's |
  | server-only `LAIN_PREFLIGHT` | the SERVER's |
  | `new-window -e LAIN_MODEL=…` | the `-e` value |

  A spec is the client. So a pane opened from the suite gets `bundle exec`'s PATH, which carries the gem bindir, which carries an installed `lain`. The bare `lain watch <digest>` a fleet window used to run therefore worked in every spec while dying of status 127 in a real cockpit, where nothing has put lain on a pane's non-interactive `$SHELL -c` PATH. That defect survived the whole life of the feature with green specs sitting over it.

  So any spec that opens a real pane and asserts on what the command did must first drop, from `ENV["PATH"]`, every directory holding the executable under test, on the server it starts and on the client it shells from, since the 2 disagree. `fleet_windows_spec.rb`'s `#lainless_path` is the worked example. Without it the spec exercises a binary the product cannot reach, and the greener it looks the less it means.

  Two corollaries for `Up::PaneCommand`. Its `gem_exports` PATH re-export stays necessary and correct, because a client that never ran chruby hands a pane the same half-PATH a stale server does, but the reason is the carve-out and not the server's staleness. And its "there is no pushing one in at spawn time" is too strong: the shell-prefix form that claim was measured against really does not reach the pane, but `new-window -e NAME=value` does. `-e` can only SET, never unset, so it could not carry the recipe's `unset` preamble even if every surface grew the parameter.
- A parked warm child that loses its worker exits on its own. `spec/support/warm_pool.rb` boots children ahead of the examples that take them and parks each one polling its go file. A worker killed mid-file (an OOM kill, a `kill -9`) runs no `after(:context)`, and a child started with `PTY.spawn` sits in its own session, so no Ctrl-C reaches it: its spares would poll forever. Each parked child compares `Process.ppid` against the `WARM_PPID` it was given and calls `exit!` when its parent is gone.
- A pane's `nvim --embed` that ignores TERM outlives the tmux server it ran under. `kill-server` signals the panes' shells, not their children, so an embed server reparented to init and lived for hours, showing up in every later `SpecWatchdog` dump as a live editor. The `qa_sandbox_pane_resolution_spec` teardown now collects each pane's process tree before `kill-server`, then sends TERM, waits 0.2s, and sends KILL to what is left.

## CI differences

Two examples went red on every GitHub runner while passing on every developer machine, for 3 consecutive pushes (2026-08-24, 2026-08-25). Neither was a flake and neither was a regression. Both were new specs that had never run anywhere but a workstation, each carrying an unstated assumption about the environment. The runner image was identical across the last green run and the first red one (checked, not assumed), so "CI changed under us" was ruled out before anything else.

- A spec that leaves `$XDG_*` to the ambient environment tests nothing on a box that exports one. `Lain::Paths a $HOME that is not absolute guards config_home and cache_home by the same rule` overrode only `HOME`. But {Lain::Paths#xdg_dir} returns an absolute `$XDG_CONFIG_HOME` verbatim and never consults `#home` at all, so the `$HOME` guard it was asserting is unreachable whenever that variable is set: the accessor answers instead of refusing. Runners export it; this box does not. Reproduce the CI failure locally in one line:

  ```bash
  XDG_CONFIG_HOME=/tmp/cfg bundle exec rspec spec/lain/paths_spec.rb   # red, everywhere
  ```

  The fix is `with_hostile_home`, which clears `XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_STATE_HOME` alongside setting `HOME`. Any example asserting the `$HOME` fallback must clear the variable that shadows it, or it is vacuous on half the machines that run it. This is the same collision `bin/spec-flakes` hit from the other direction (see the retired `spec:flakes` note above): there the harness SET `$HOME` and `XDG_*` and 5 of these examples went red in all 9 runs.
- tmux 3.4 misreports `#{pane_current_path}`, inserting a backslash before every `$`. A pane sitting in `a$b` formats as `a\$b`, while `readlink /proc/<pane_pid>/cwd`, where that pane's shell demonstrably is, says `a$b`. Measured directly in an `ubuntu:24.04` container against the plugin itself. The pane's real cwd is correct, so this is a reporting defect and no session-creation one. Fixed upstream by 3.7. Ubuntu 24.04 LTS ships 3.4, which is what `.github/actions/spec-binaries` installs from apt, so every runner has it and no dev box does.

  The consequence for `plugin/tmux`: the resolver hashes `sha256(realpath(dir))`, so a path tmux spells differently hashes to a project nobody wrote state for, and the HUD renders `lain: no state yet`. That is the correct behaviour, since lain cannot resolve what tmux misreports, and it is what `neutralizes a hostile pane cwd` now pins on such a tmux, while asserting the payload-never-runs half unconditionally on every version. The `$` cannot be spelled out of that example: `$(...)` substitution is the attack it exists to prove inert.

  Ruled out along the way, so nobody re-runs them: the `#{q:}` shell-quote escape set is byte-identical in 3.4, 3.5 and 3.7 (`format_quote_shell` in `format.c`); `/bin/sh` being dash on Ubuntu and bash here makes no difference (both render identically against the same expanded job); and it is not a race on the pane's cwd, because 80 consecutive sessions under a fully loaded box never once reported an empty path.

  Probe the behaviour and never parse `tmux -V`: a distro backport makes the version string lie, and the pane is already there to ask. The general rule this instances: an example that drives a real binary is pinned to that binary's bugs, and CI's copy is older than yours.
- `rake compile` on macOS builds the extension and skips `lain-fence`. The fence is Linux-only (Landlock), so the compile task prints a line and the sandbox runs degraded. The build is not the last blocker: `setsid` and `FIONREAD` are the next 2 places the Mac port stops, and `rake default` still runs the suite on a Mac regardless of this gate.
