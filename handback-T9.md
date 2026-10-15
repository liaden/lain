# T9 hand-back

## Files changed

- `lib/lain/approval/composed_term.rb`: new `PROGRAMS` entries for `ls` (refuses `-R -L -H`, `--recursive` and the 3 `--dereference*` flags), `pwd` and `which` (refuses `-i`, `--read-alias`, `--read-functions`). New closed `VERSION_PROBES` table (`rustc cargo rustup dx adb go gcc clang cmake`) with the rustup-proxy accepted risk in its comment, plus a private `VersionProbe` that admits exactly `["--version"]`. `allowlisted?` and `unflagged?` (through a new `flags_for`) accept a probe stage. The landing predicate now walks `landing_words(term)`, which drops a `which` argument with no `/`. The header list items 3 and 9 say so.
- `spec/lain/approval/composed_term_spec.rb`: 8 new examples under "a read-only probe of where the agent is and what is installed".
- `spec/lain/cli/wiring/board_build_spec.rb`: 3 new production-path examples (probes approve, `pwd && ls -la` approves, the 7 hazards park). The `&&` example gives the toolset a bash tool whose verdict hands over a 2-pipeline `Shell::Term`, since this verdict cannot parse `&&` yet.

## Failing run (before production code)

`bundle exec rspec spec/lain/approval/composed_term_spec.rb spec/lain/cli/wiring/board_build_spec.rb`
170 examples, 6 failures (the 4 approval examples, the landing-skip example, both board approvals). The hazard examples passed red, as they should: refusal by absence.

## Passing run

Same 2 files plus `spec/zeitwerk_spec.rb` and `spec/output_discipline_spec.rb`, after the coordinator's ruling: 177 examples, 0 failures.
Wide run before the ruling, 97 spec files that name `ComposedTerm` or the newly approved commands (`ls`, `pwd`, `which`, `X --version`), `LAIN_SLOW=1 parallel_rspec -n 8`: 4838 examples, 0 failures.

## Checks

- rubocop on all 3 files: no offenses.
- yard-lint on the lib file: no offenses.
- `bin/comment-census --check-tickets`: exit 0.
- `bin/zeitwerk-census --check`: all ok.

## Wiring diffs

None. The card lists no shared-file wiring.

## Surprises

1. **Dropped `node`, `npm`, `python3` and `ruby` from `VERSION_PROBES`**, on the coordinator's ruling: the shell verdict refuses interpreters by name on purpose, so they could never approve, and widening the verdict is a security change for the user to decide. A spec shows `ruby --version` still asks.
2. An existing board_build example ("leaves an ordinary command to park exactly as it did before", in the triage section) used `ls -la` as its ordinary command. That command now approves, so I changed it to `du -sh lib`.
3. I added `which`'s `-i`, `--read-alias` and `--read-functions` as disqualifying flags. The card listed none for `which`, but `/usr/bin/which` 2.25 `--help` says they read stdin, and the table promises every flag was read off the binary.
4. The landing skip covers only predicate 9. A bare `which` argument still goes through the ordinary-name, root and content predicates, as the card asks.

## Fix round

Each fix had a failing test first. The red, before any production change: the 2 card files gave 174 examples and 3 failures (the toolchain file in the cwd or above it, the legacy file above the root, the listing of credentials), and the new board example failed alone, 96 examples and 1 failure.

1. **Blocker, rustup toolchain.** New predicate 10 (`unpinned?`). A `rustc`, `cargo` or `rustup` probe is refused when a `rust-toolchain` or `rust-toolchain.toml` file, or a dangling link of either name, sits in the call's real cwd or any directory above it. The walk does not stop at the root. The accepted-risk comment now names what is accepted (the user's default or override, and a download) and what is not (a toolchain the checkout pins). Run against `/home/tara/tmp/lain/T9-review/rtc/sub`, `rustc` and `cargo` come back nil and `gcc --version` approves.
2. **ls listing withheld names.** New predicate 11 (`unrevealing?`). For each `ls` stage, the operands are every non-dash word plus every word after `--`; with none, it lists the cwd. Each operand that lands on a directory has every entry classified through the same classifier, under 2 names: its own name (absolute, and relative to the real cwd) and its landing (`ordinary_landing?`). Both must be ordinary and not exempt. That is stricter than `Sensitivity::Filter`, which keeps exempt names, and it matches predicate 4. Listings are 1 level deep. Hidden entries count even without `-a`, so a bare `ls` in a directory holding `.env` asks. The reviewer's probe: `ls .ssh`, `ls -la keys`, bare `ls -la` and `ls etclink` (the entries of `/etc`) all park; `ls sub` and `ls sublink` approve.
3. `pwd && ls -la` still goes through a stand-in verdict. It waits for the restack on the `&&` card.
4. Deleted both WHAT comments and renamed `NAMES_PROGRAMS` to `PROGRAM_LOOKUP`. `VersionProbe` now carries a 1-line WHY comment, because `Style/Documentation` requires one.
5. Moved the `which` special case into `landed(stage)` and `looked_up_paths(stage)`. `ordinary_landing?` now shares a new `ordinary_spellings?`.
6. The probe spec lists its 9 names directly.

Passing: the card specs plus the zeitwerk and output_discipline specs, 181 examples, 0 failures. The wide 97-file set, 4843 examples, 0 failures. Rubocop, yard-lint and comment-census `--check-tickets` pass, and zeitwerk-census `--check` is all ok.

7. **Dot entries, on the coordinator's ruling.** An `ls` with none of `-a`, `-A`, `--all` or `--almost-all` skips dot entries in the listing check, because `ls` does not print them. The test is a `Flags` (`SHOWS_DOT_ENTRIES`), so a bundle (`-lA`) or an abbreviation (`--alm`) counts as asking for them. Red first: 80 examples, 1 failure (`ls -l dotted` and a bare `ls` beside a `.env` were refused). After: card specs plus zeitwerk and output_discipline, 182 examples, 0 failures. Rubocop, yard-lint and both census checks pass. The bare `ls` case left the older listing example, since that command now approves there. No entry cap, per the ruling.

## Fix round 2

First, `lib/lain/approval/composed_term.rb` had a future mtime, left by the mutation script. I touched it back to now before starting.

Red first: `composed_term_spec.rb`, 85 examples, 3 failures: options that take a value, the cwd judged when no operand is a directory, and the cwd that cannot be resolved.

1. **Blocker, ls option values.** The `ls` flags now refuse every option that takes a value, from the man page: `-I -T -w`, `--block-size --format --hide --ignore --indicator-style --quoting-style --sort --tabsize --time --time-style --width`. They also refuse the 3 options with an optional `=WHEN` (`--color --classify --hyperlink`). The `Flags` matcher works both ways, so abbreviations and bundles (`--wid`, `-lw`) count. Also, `listed_directories` now falls back to the cwd whenever no operand lands on a directory; `operands` no longer adds `.`. Each guard is pinned on its own: a mutant without the flags fails "refuses an ls option whose value happens to name a directory" (`ls -I plain` with a `plain` dir in `.ssh`), and a mutant without the fallback fails 3 examples. That flags-only example was added after the code, so its red comes from that mutant, not from a run before the code existed. The reviewer's board probe with `PROBE_CWD=.ssh`: all 7 park (`ls -w 80`, `--width 80`, `-T 4`, `-I x`, `--sort size`, bare `ls`, `ls -l`).
2. **Surviving mutants.** I added 1 example each: a dangling `rust-toolchain.toml` link; a factory whose cwd lookup raises, which refuses both `rustc --version` and `ls` (this covers both rescues; `unpinned?` now resolves the cwd through `landing_of(".")`, the same call the listing predicate uses); and a link named `.env` pointing at an ordinary file. A rerun of the 4 mutants plus 2 new ones (no value flags, no cwd fallback): each fails at least 1 example.
3. One WHY comment on `ordinary_entry?` accepts that a bare `ls` parks next to an ordinary-named link to a gated file.

Passing: the card specs plus zeitwerk and output_discipline, 188 examples, 0 failures. The wide 97-file set, 4850 examples, 0 failures. The reviewer's toolchain probe, 9 examples, 0 failures. Rubocop, yard-lint and comment-census `--check-tickets` pass, and zeitwerk-census `--check` is all ok. My mutation script restores the file in `ensure`, and I touched the file afterwards, so no mtime is left in the future.
