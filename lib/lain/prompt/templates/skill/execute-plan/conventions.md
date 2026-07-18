## Execution conventions this run must honour

Defer to the repo's CLAUDE.md for the binding rules — the commit-grouping traps (a new lib
file, its manifest line, and its spec land in the *same* commit), the pre-commit stash
behaviour, output discipline, and the toolchain export the commit shell needs. This hole pins
the *orchestration* conventions the shipped scaffold cannot know: the branch/worktree naming
scheme, who owns which shared files, the integration checks that must pass before close-out,
and any manual pass the user always wants to run themselves. Override it at
`.lain/slots/skill/execute-plan/conventions.md`.
