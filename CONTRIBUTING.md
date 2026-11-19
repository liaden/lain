# Contributing

## Setup

lain is developed on Ruby 4.0.10 from mise. 4.0.6 is the oldest that works: 4.0.5 crashes under
`rake pspec`.

```bash
bin/setup                        # bundle install, and the pre-commit hooks when pre-commit is installed
bundle exec rake compile         # builds the Rust extension (needs clang)
bundle exec rake daemon:build    # builds lain-daemon, for the :core specs
```

## Checks

```bash
bundle exec rspec                # the quick loop, skips the slow files
bundle exec rake pspec           # the whole suite, in parallel; what the commit hook and CI run
bundle exec rubocop -a           # safe autocorrect only; never -A
cargo test && cargo clippy --all-targets -- -D warnings
```

## Documentation

Two pre-commit hooks check the docs, and CI runs both:

- lychee checks every relative link and heading anchor (`lychee.toml`).
- vale checks prose against the writing rules in `styles/Lain/` (`.vale.ini`). An error fails the
  commit and a warning only prints. When a rule is wrong about 1 passage, wrap the passage in
  `<!-- vale Lain.RuleName = NO -->` and `<!-- vale Lain.RuleName = YES -->`.
- A new crate, plugin or app README is added by name to the vale hook's `args` in
  `.pre-commit-config.yaml`.

```bash
pre-commit run lychee --all-files
pre-commit run vale --all-files
```

pre-commit installs both tools itself, and CI runs them through the same pre-commit config. To see
vale's warnings and suggestions for 1 file, run it directly:

```bash
mise x vale@3.27.0 -- vale --minAlertLevel=suggestion docs/users/cockpit.md
```

User pages go in `docs/users/` and developer pages in `docs/devs/`.

## Rules

[CLAUDE.md](CLAUDE.md) is the rule book for people and agents alike: toolchain, code style,
comments, testing and how to commit. Read [docs/devs/toolchain-traps.md](docs/devs/toolchain-traps.md)
before believing a red suite.

[docs/devs/](docs/devs/README.md) indexes the rest: architecture, design and the test suite.
