## Execution conventions this run must honour

If the project has a contributor or agent guide (`CONTRIBUTING.md`,
`AGENTS.md` or `CLAUDE.md`), follow it for the binding rules; if not, apply the
conventions below. It covers how to build and test, how to commit, and what a
commit must not break. This hole pins the *orchestration* conventions the
shipped scaffold cannot know: the branch/worktree naming scheme, who owns which
shared files, the integration checks that must pass before close-out,
and any manual pass the user always wants to run themselves. Override it at
`.lain/slots/skill/execute-plan/conventions.md`.
