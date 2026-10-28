# Dogfooding lain on lain

`dogfood/lain/config.rb` is the config a checkout of lain uses on itself: it names `bin/verify` as the
isolation verifier and lets the bash tool run exactly that command.

`bin/dogfood-setup` links `.lain` to `dogfood/lain` and prints the `lain trust` command. Read the config,
then run it: a config does not run until its bytes are trusted.

`.lain/` stays ignored (`/.lain/` in `.gitignore`). It holds per-checkout state, such as the status line
the cockpit republishes each turn, and the decision to version it is still open. The committed copy lives in
`dogfood/lain/` so every clone gets the same bytes meanwhile. The setup script adds the `.lain` symlink to the
checkout's git exclude file, since the ignore rule matches a directory only.

`bin/verify` rebuilds the toolchain (mise ruby 4.0.6, `LD_LIBRARY_PATH`) because the fence scrubs the
environment, compiles the extension, and runs `rake pspec`. It exits with the suite's status.
