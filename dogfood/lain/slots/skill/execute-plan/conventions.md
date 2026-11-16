## Execution conventions this run must honour

This is the Lain repo. Its CLAUDE.md holds the binding rules; these are the ones a run breaks most often.

Toolchain: the shell's default `ruby` is wrong. Every command first runs `eval "$(mise env -s bash ruby@4.0.9)"`, exports `LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib`, and sets `TMPDIR` to a directory on the repo's filesystem, one per agent. Set `LAIN_SPEC_WORKERS=12`. `bin/verify` does all of this and runs the suite.

Commits go on `main`, in dependency order, leaf first. A new lib file and its spec land in the same commit, because the commit hook stashes unstaged tracked changes and leaves untracked files alone, so a staged spec whose subject is untracked passes the hook and lands a HEAD that cannot load. If the hook fails the files stay staged; unstage them before the next `git add`. Stage by explicit path, never from `git diff --name-only`. Do not run git in a way that changes a worktree while the hook is running: its autostash is repo-wide, so another worktree's `git status` lies until it ends.

The suite: `bundle exec rake pspec` is the suite command and waits on the suite lock at `$XDG_STATE_HOME/lain/locks/suite.lock`; read that file to see the holder. A bare `rspec` takes no lock, so a red beside one is not evidence. Run one rspec process at a time, by path. Check the example count, not only the failure count.

Comments explain WHY only and are rare. No ticket or card ids in comments or commit messages. Run `bundle exec rubocop -a` (never `-A`) and `bin/comment-census --check-tickets` before a card is done.

Review: the panel is the Ruby roster (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson). Shared files are edited by the orchestrator only; a card hands back a one-line diff.
