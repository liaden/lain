# QA round 9, continuation — the scenarios the main pass did not reach — 2026-08-23

**Companion to [`qa-findings-round9-2026-08-23.md`](qa-findings-round9-2026-08-23.md).** The main
pass drove the full-round tier (6 of 13 scenarios) and named seven as unreached. This pass drove
**four of those seven for the first time ever**, plus one section of a fifth. Read the two documents
together; finding ids continue from the main pass (F54, P13).

## Summary

**Four scenarios written from the code on 2026-08-23 and never driven — `repl-commands`,
`epic-tier`, `secret-boundary`, `changeset-review` — now have real coverage, and their documents
turn out to have been very accurate.** Nearly every expected string, refusal and record name in them
was correct. That answers the question the README posed about them ("the first round to drive each
should expect to correct the document as much as to find defects, and should say which it did"):
**this round mostly confirmed them.** Three concrete scenario corrections are recorded below, all
minor, none a defect in lain.

**`secret-boundary` — the README's "largest untested surface", owed since round 4 — passes every
check driven.** The full classifier table, both directions of the home-anchoring, the `.pub`
carve-out, the `exempt` asymmetry, the unliftable denial, and a clean closing negative.

**`--exec docker` was unblocked mid-round** (podman + podman-docker installed at the operator's
initiative) and **still gates**, which is the defect that section exists to catch.

Two new findings, both UX, plus three process defects — one of which made the close-out check itself
report false positives.

| id | sev | what |
|---|---|---|
| **F57** | **HIGH** | `Exec::Docker` hardcodes `--user`, which is correct for docker and inverted for rootless podman — the mounted project becomes unreadable and unwritable, and two `:seam` specs go RED on any host with `podman-docker` |
| **F55** | **MEDIUM (UX)** | `Exec::Docker` returns the container **client's** own chatter (shim banner, image-pull progress) as the command's stderr, so the model reads runner noise as program output and spends a turn explaining it away |
| F56 | LOW (UX) | `/review-submit` over a survey refuses in a sentence that calls the survey a **branch** — the local-branch wording reused unchanged |
| **P14** | **process** | `capture-pane -S -<n>` **cannot page back in the chat pane at all** — it is a TUI on the alternate screen, which has no scrollback. Any check reading more than one screenful of chat output is unverifiable this way, and it produced a false "four commands missing from `/help`" |
| **P15** | **process** | the sandbox cannot redirect `HOME` without also pinning `MISE_DATA_DIR`, `GEM_HOME` and `GEM_PATH` — and `secret-boundary` **requires** a redirected `HOME`. Following that scenario literally with the stock sandbox writes fake private keys into the operator's real `~/.ssh` |
| **P16** | **process** | a redirected `HOME` makes `git status --porcelain` — the close-out check itself — report **false positives**, because git's global ignore lives at `$HOME/.config/git/ignore` |

---

## What each scenario did, first time driven

### `repl-commands` — §0, §1, §2, §3 (part), §5

- **§0 — the registry is zero-model-turn, confirmed.** `/help` and every command below left the
  journal byte-identical. Registration order is **not** alphabetical (`Quit, Rewind, Pin, Unpin,
  Fork, Btw, Keep, Status, …` from `surface.rb:138`), which is what the scenario asks for — an
  alphabetical listing would mean a second ordering exists somewhere.
- **§1 — the read-only four all render and journal nothing.** `/mode` reports the `accept_edits`
  default with no layers.
- **§1 — the `/mode` grammar passes in full.** `+notify` / `-notify` each journal a switch; a bare
  `/mode` read journals nothing. Both refusals name their complete valid set:

      error: unknown mode layer "nosuchlayer", expected one of [:auto_approve, :goal, :notify, :vi]
      error: unknown posture "nosuchposture", expected one of [:plan, :manual, :accept_edits, :auto]

  — postures most-restrictive-first, as specified.
- **§1 — `/mode !` is a reset, not a step, and it writes ONE record.** From `auto` + two layers:

      mode_switch  from=auto to=plan from_layers=["notify","vi"] to_layers=[] surface=tty
      policy_switch from=approve_all to=deny_all surface=tty

  **No intermediate ladder** through `accept_edits`/`manual` — which is the specific failure the
  scenario names ("postures the session was never really in, and every later fold reads them as
  real"). The paired `policy_switch` is correct.
- **§2/§3 — every digest-path refusal says the grammar out loud**, which is the check:

      "abc" is too short to name a turn (4 characters minimum) -- /pin names a turn, not a count:
        give a turn digest, or bare /pin for the last assistant turn
      no turn matching "zzzzzzzz" on this session's chain -- /pin names a turn, not a count: …
      no turn matching "zzzzzzzz" on this session's chain -- /unpin names a turn, not a count: …
      /rewind 999 is out of range; this session holds 2 committed turns (valid range: 1..2)

  `/unpin` correctly substitutes its own verb. `/rewind` names the valid **range**, which is better
  than the text the scenario quotes.
- **§5 — the two refusals are genuinely distinct**, as required. Nothing open points at
  `/review <pull-request>`; a survey open gives its own sentence about there being nowhere to post.
  **F56** is the wording nit in the second.

**Not driven:** §2's ambiguity refusal (needs two digests sharing a 4-char prefix — the scenario
says to manufacture it and a 2-turn session cannot), §2's pin-survives-compaction effect check
(needs volume), §4 (`/fork` `/btw` `/keep`), §6 (`/yolo`), §7 (`/goal`, the only loop), §8 (`/meta`),
§9. **§7 in particular is still the only place a self-driving loop and its cost would be recorded**,
and it remains unmeasured.

### `epic-tier` — §1, §1b, §3

- **§1 — all four config refusals pass**, exit 1, **zero backtrace frames**, and **every one names
  the config file path first**, which is the scenario's specific demand:

      <path>: epics_home "repo " is not one of xdg, repo
      <path>: [epics] has no keys "hoem"; known keys: home, gates
      <path>: [epics] must be a table, got String: "deferred"

- **§1b — the repo-mode gitignore trap warns, and the warning is exemplary.** Silence here was the
  defect; instead:

      warning: .gitignore:1:/.lain/ makes git ignore this home, so these epics are invisible to
      review -- repo mode exists to put them in a pull request. Drop that pattern (this command
      never edits .gitignore).

  It names the exact ignore line, what it breaks, why the mode exists, the remedy, and its own scope
  limit. **This is also direct support for the main pass's F50** (`.lain/state.json` dirtying user
  projects with no ignore path): lain demonstrably *can* detect and report `.gitignore` interactions,
  so F50's proposed fix has precedent in the codebase rather than being novel.
- **§3 — the gate mapping refuses on both sides, and reports every unknown key in ONE pass:**

      [epics.gates] has no stages "reserch"; the pipeline is research -> epic_plan -> issue_plan -> implementation
      [epics.gates] names unknown gate policies "defered"; known policies: interactive, hands_off, deferred, adjudicated
      [epics.gates] has no stages "reserch", "issue_pln"; the pipeline is …      <- BOTH named

**Scenario correction.** §3 gives `printf '[epics.gates]\ngates = "deferred"\n'` as the `NotATable`
case. It is not — that config *is* a table containing a key called `gates`, and it correctly returns
`has no stages "gates"`. The real `NotATable` shape is a scalar one level up:

```bash
printf '[epics]\ngates = "deferred"\n'   # -> [epics.gates] must be a table, got String: "deferred"
```

**Not driven:** §2, §4, §5 (all four policies), §6 (the stage boundary — "the ruling this tier turns
on"), §7, §8, §9. Also **§3's `for_all` property was NOT driven**: it fires on `epic submit`, not on
`epic status`, and needs an actual epic to exist. My probe ran `status` and proved nothing; recorded
as unreached rather than passed.

### `secret-boundary` — §1, §1b, §2, §7 — the owed scenario

**Every check driven passes.** Driven against a fixture under a redirected `HOME` (see P15).

| path | verdict | the check it is |
|---|---|---|
| `lib.rb` | ordinary, read cleanly | the control |
| `.env`, `server.pem` | **gated** → reached a human → denied | `credential` |
| `$HOME/.ssh/id_qa.pub` | **ordinary**, read cleanly (`ssh-rsa AAAA fake`) | **the `.pub` carve-out** — a false positive here is a session-killer, since a denial is unliftable |
| `$HOME/.kube/config` | **denied, `protected`** | the home-anchored rule fires |
| `<checkout>/.kube/config` | **read cleanly** | **the innocent twin** — the anchoring does not over-reach |
| `$HOME/Downloads/x` | **gated** → approved → read | a different gate reason |
| `<checkout>/backup/root/.ssh/id_rsa` | **denied, `protected`** | unambiguous rules match wherever they sit |

Both directions of §1b prove out, which the scenario says "only shows if the round creates the
innocent twin". The unliftable refusal names itself as unliftable and says what to do instead:

    refused: <path> is a protected path; no approval can lift this, so name a different path
    rather than retrying this one in another form

**§2's asymmetry — the section's whole point — holds in both directions:**

    exempt = ["*"]    -> REFUSED: [sensitivity] exempt matches everything: "*"
    exempt = ["~/"]   -> REFUSED: [sensitivity] exempt matches everything: "~/"
    gated  = ["*"]    -> LEGAL, exit 0      (a wildcard here can only ADD)
    denied = ["*"]    -> LEGAL, exit 0

So the single config line that would disable the boundary is rejected, while the same pattern under
the two widening keys is accepted. **And `exempt` cannot lift a `denied`** — the boundary's worst
failure mode: with `exempt = ["~/.ssh/id_qa"]` loaded and the config accepted, that path is *still*
refused as protected.

`exempt` also has a narrower grammar than the scenario implies, and says so:
`[sensitivity] exempt is a basename glob ("*.secret") or a home-anchored path ("~/.netrc")`.

**§7 — the closing negative, with a positive control.** No secret bytes reached any journal in the
sandbox: `sk-live-0000`, `BEGIN PRIVATE KEY`, `BEGIN OPENSSH PRIVATE KEY`, `MIIBOgIBAAJBAK` and
`fake-key` all return **0** journals. The one value that IS present is `ssh-rsa AAAA fake` — the
`.pub` file, public by definition and correctly classified ordinary — which is what makes the five
zeros evidence rather than a broken grep. The operator's **real** `~/.ssh` was never touched
(0 files modified since round start).

**Not driven:** §3 (the listing filter), §4 (the content mask / `Regions`), §5 (`--yolo` against a
denial), §6 (`--secret-oracle`). §4 and §5 are the two that would complete the "three-place split",
so the split is now **two places driven of three**.

**Withdrawn before filing.** The model sent `{"path" => "/.ssh/id_qa"}` — a tilde mangled to a root
path — and I nearly filed lain's tilde substitution. `/ruby` against the live process answered
`ENV["HOME"]` = the sandbox home and `File.expand_path("~/.ssh/id_qa")` = the correct sandbox path,
so the mangling is the model's. Worth knowing for §1c: **drive tilde paths with absolute paths
instead**, or you measure the model. The reading is still useful — `/.ssh/id_qa` does not exist and
was refused `protected` anyway, demonstrating live that the classifier answers **before** a file is
opened.

### `changeset-review` — §1, §1b, §2

Subject for the record: `master 5c73c7a3`, `feature b8448ba0`, three commits
(`lib: a total`, `bin: use it`, `doc: say what it is`).

- **§1 — both refusals name the ROLE**, which is the point (`base` and `head` fail identically
  otherwise): `head ref "no-such-branch" does not resolve to a commit in <repo>` and
  `base ref "no-such" does not resolve to a commit in <repo>`.
- **The `: <detail>` tail is load-bearing and it survives.** Run from outside any repository:

      head ref "feature" does not resolve to a commit in <dir>: fatal: not a git repository
      (or any parent up to mount point /home)

  and it is correctly *absent* for a merely-unknown ref, which is exactly the
  `rev-parse --verify --quiet` behaviour the scenario describes.
- **§1b — two roots:** `"orphan" and "feature" share no merge base in <repo>, so there is no
  revision to anchor the old side to`. Verbatim.
- **§2 — the three scopes render visibly differently** (flat file list / grouped by commit message /
  grouped by directory) and the enum refuses by name:
  `Expected '--scope' to be one of cumulative, commits, by_directory; got nonesuch`.

**Scenario correction.** §0's setup assumes the default branch is `main`; `git init` on this box
creates `master`, so every `git rev-parse main` in that section fails. Have the setup capture the
branch name rather than hard-coding it.

**Not driven:** §3 (`--base`), §4 (the ceilings), §5 (the cockpit over a changeset — the section
that would give the note rail a real OLD side, which `cockpit-surfaces` §4b explicitly cannot),
§6, §7, §8.

### `subagents-and-backends` — §4 only

**Unblocked mid-round.** docker was absent at the start of this pass; the operator installed podman
plus `podman-docker`, which puts a `/usr/bin/docker` shim on PATH. `Exec::Docker::CLI` is the
hardcoded string `"docker"` and `CLI::ExecBackend#refuse_without_client!` probes PATH for exactly
that name, so the shim satisfies it — `--exec docker` now constructs where it previously refused.

**The section's key check passes: a container session still gates.** The full ladder is journalled
for a `bash` call under `--exec docker`:

    escalation      rung=triage    verdict=abstain  authority=automatic
    escalation      rung=rules     verdict=abstain  authority=automatic
    approval_pending  tool=bash requester=agent
    approval_decision tool=bash verdict=approve
    escalation      rung=surfaces  verdict=allow    authority=human   "a surface approved this call (tty)"

A `--exec docker` session that auto-approved "because it is in a container" is the defect this
section exists to catch, and it is not present.

**Not driven:** §1, §2, §3 (`--isolation worktree` and the open help-text question), §5
(`lain watch`), §6, and §4's own `--exec-image` / pipe-refusal / timeout / stopped-daemon checks. The
pipe probe was attempted and **the model did not issue the piped command**, so it asserted nothing —
recorded as inconclusive, not as a pass.

---

## F57 — `Exec::Docker`'s hardcoded `--user` makes the backend unusable under rootless podman

**HIGH.** Found 2026-08-23 while grounding the fix plan, not during the round proper. It is the
first finding here that leaves the **spec suite red**: `spec/lain/exec/docker_spec.rb:355` and
`:372` fail on any host where a `docker` client resolves to rootless podman. They passed before only
because they are `:seam`-gated on `DockerBackendAvailability` and were **skipped** — installing
`podman-docker` mid-round unskipped them.

**Mechanism.** `Exec::Docker` always passes `--user "#{Process.uid}:#{Process.gid}"`
(`lib/lain/exec/docker.rb:110`, used at `:169`). Under **docker** that is right and its docstring
says why (`:103-104`): the container uid must match the host uid or files written into the mounted
project are owned by root. Under **rootless podman the mapping is inverted** — the host user is
already container **root**, and naming an explicit uid maps it through subuid to a host identity with
no access to the bind mount at all.

**Measured, both arms, same mount:**

```
$ docker run --rm --user 1000 --volume $D:$D --workdir $D alpine sh -c 'id; cat seed.txt; touch made'
uid=1000(tara) gid=0(root)
cat: can't open 'seed.txt': Permission denied
touch: made: Permission denied

$ docker run --rm --volume $D:$D --workdir $D alpine sh -c 'id; cat seed.txt; touch made2'
uid=0(root) gid=0(root)
seed                      <- reads
$ ls -l $D/made2          <- and the write landed on the HOST owned by tara
-rw-r--r-- 1 tara tara 0 made2
```

So omitting `--user` under podman satisfies the very property the spec at `:372` asserts ("writes
into the mounted project as the calling user, not as root") — the same intent needs the opposite
argv on the two clients.

**Why it matters beyond this box.** `podman-docker` is the standard docker-compat path on Arch,
Fedora and RHEL, and `CLI::ExecBackend#refuse_without_client!` probes PATH for a file named
`docker` (`lib/lain/cli/exec_backend.rb:129`) — it cannot tell the two clients apart. So
`--exec docker` resolves happily and then cannot read or write the project it mounted, which is the
backend's entire purpose. The failure is also *silent in the right way to be maximally confusing*:
the container starts, the command runs, and every file operation returns `Permission denied`.

**Fix shape.** `user:` is already an injected keyword with a default (`docker.rb:110`), so the seam
exists: let `nil` mean "do not pass `--user`", and resolve it where the client is already being
probed (`CLI::ExecBackend`), which is the one place that knows which binary it found. Detection can
be `docker --version` (podman's shim prints `podman version …`) rather than anything heuristic.
What would pin it: the two `:seam` examples above passing under **both** clients, and an argv-level
example asserting `--user` is absent when `user:` is nil.

**Caveat this finding cannot settle:** it was measured against podman 6.1.0 rootless only. Rootful
podman behaves like docker here, so a fix keyed on "is podman" rather than "is rootless" would be
wrong — key it on the mapping, or make it configurable and default by client.

## F55 — the container backend hands the client's own chatter to the model as stderr

**MEDIUM (UX).** `Exec::Docker` returns the `docker` client's stderr verbatim as the tool result's
stderr, so everything the *runner* says — not the command — is presented to the model as though the
program emitted it.

**Evidence.** One `echo GATED_OK` under `--exec docker`, journalled tool result:

```
exit status: 0
--- stdout ---
GATED_OK
--- stderr ---
Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg.
Resolved "alpine" as an alias (/usr/share/containers/registries.conf.d/00-shortnames.conf)
Trying to pull docker.io/library/alpine:latest...
Getting image source signa…
```

**That it misleads is measured, not inferred:** the model spent part of its reply explaining the
noise away — *"The additional lines you see in the output are from Docker/podman trying to pull an
image, but they don't affect the result of the `echo` command itself."* That is tokens spent, and a
turn where a wrong conclusion was equally available.

**Not a podman artifact, though podman makes it loud.** Image-pull progress on first use is docker's
behaviour too; the shim banner is the podman-specific half and is fixable out of band
(`/etc/containers/nodocker`). The lain-side fact is that the backend has no separation between the
client's diagnostics and the command's own output.

**Reproduction:** `lain chat --exec docker --prompt 'Run: echo HI'` against any image not yet
pulled, and read the `tool_result` in the journal.

**Fix shape:** the backend already builds the client argv itself, so it knows which stream is whose
— run the client with its progress suppressed (`--quiet` where available), or capture the client's
stderr separately from the container's and attach it as backend diagnostics rather than as command
stderr. What would pin it: a seam spec asserting a tool result for a trivial command under a
not-yet-pulled image contains only the command's own output.

## F56 — the survey `/review-submit` refusal calls a survey a branch

**LOW (UX).**

    error: this review was opened on survey of <path>, and a branch has no pull request to post a
    review to -- the annotations and the verdict are on the journal either way. Run `/review
    <pull-request>` against the pull request itself to post one.

It names the thing a **survey** and then reasons about **a branch**. The local-branch sentence was
reused without changing the noun. The remedy is right and the refusal is otherwise good; a reader
who knows a survey is not a branch will wonder which one lain thinks it has.

**Reproduction:** `/survey ./lib` then `/review-submit`.

---

## Process defects

### P14 — `capture-pane -S -<n>` cannot page back in the chat pane

The chat pane is a TUI on tmux's **alternate screen**, which has no scrollback. Measured:

```
alternate_on=1
capture-pane -S -50   -> 50 lines
capture-pane -S -400  -> 50 lines
capture-pane -S -2000 -> 50 lines      # history-limit is 2000 and it makes no difference
```

**This produced a false finding and I nearly filed it.** `/help` prints ~44 command lines plus a
skill catalog into a 50-row pane; the top scrolls away and is unrecoverable. Reading it back showed
`/pin`, `/unpin`, `/rewind` and `/quit` "absent from `/help`" — and they are exactly the **first
four in registration order** (`surface.rb:138`). Both `/pin` and `/rewind` then dispatched correctly
with the scenario's own expected refusal text.

**The lesson for the method:** any check that needs more than one screenful of chat output cannot be
driven through `capture-pane`. Narrow the output, or read a `lain://` buffer, which is a real buffer
with real lines. And a "missing" item that sits at the very start or end of a long render should be
suspected as a capture artifact before it is filed.

### P15 — the sandbox cannot redirect `HOME`, and `secret-boundary` requires it

`secret-boundary` §0 writes fake private keys into `$HOME/.ssh/`. `qa-sandbox.sh` redirects the four
`XDG_*` variables and `TMPDIR` but **not** `HOME`, so following §0 literally writes into the
operator's real `~/.ssh`. That is unacceptable and it is also silently wrong — several of the rules
under test are home-anchored, so they would be resolving against the operator's real home.

Redirecting `HOME` alone breaks the toolchain: mise's install root is `$HOME/.local/share/mise`, so
`lain` re-installs Ruby into the sandbox home and then cannot find any gem
(`Bundler::GemNotFound`, ~120 gems). The working set is:

```bash
export HOME="$QA/home"
export MISE_DATA_DIR=/home/tara/.local/share/mise
export GEM_HOME=/home/tara/.local/share/mise/installs/ruby/4.0.6/lib/ruby/gems/4.0.0
export GEM_PATH=/home/tara/.gem/ruby/4.0.0:$GEM_HOME
```

**This is not the `GEM_HOME` hazard `method.md` warns about** (P9 / round 8): that hazard is a
*foreign* gem set reaching `exe/lain` and re-locking `Gemfile.lock`. These point at the exact gems
lain already resolves. Verified: `Gemfile.lock` md5 unchanged across the whole pass.

**And `HOME` is not in `PANE_ENV`**, so it must be exported before the tmux server starts, like
`LAIN_DESKTOP`. Verify per pane rather than assuming.

### P16 — a redirected `HOME` makes the close-out check itself lie

With `HOME` redirected, `git status --porcelain` on the lain checkout reported **four untracked
entries that were not there**: `.claude/settings.local.json`, `.envrc`,
`references/papers/src/`, `references/papers/rst/…`.

None were created by the round — all four date from 2026-08-14 to 08-18, and
`find -newermt <round start>` returns nothing. The cause is that git's global ignore lives at
`$HOME/.config/git/ignore` (`.envrc` is ignored at line 30 of it), so a redirected `HOME` makes git
stop honouring it and every globally-ignored file appears untracked.

Re-run with the real `HOME`: **identical to the baseline**.

**Why it matters more than it looks:** `method.md` makes `git status --porcelain` a close-out
assertion precisely because round 8 missed a real repo mutation. A driver who redirects `HOME` for
`secret-boundary` and then runs that assertion gets false positives — and the obvious "cleanup"
response is `git add -A`, which would commit the operator's local settings and `.envrc`. **Take the
close-out `git status` in a shell that has not sourced the sandbox env**, or unset `HOME` for it.

---

## Close-out

- XDG negative: `find ~/.local/state/lain -newermt '2026-08-23T13:50:31Z'` → **0**, positive control
  (`-newermt 2026-08-19`) → **468**.
- Operator's real `~/.ssh`: **0** files modified since round start.
- No `.lain/` left in the lain checkout.
- `dunstctl count displayed`/`waiting`: **0**/**0**. The whole pass ran `LAIN_DESKTOP=0`, verified
  per pane.
- `git status --porcelain` on the checkout: **identical to baseline** (see P16 for the false alarm).
- `Gemfile.lock` md5 unchanged: `f51222770364686a2cb61b9845368b05`.

## Still owed after this pass

- **`memory-and-dogfood`** — not driven at all.
- **`rails-blog`** — not driven. Rails is absent from this box; the scenario says to install it
  rather than substitute, and installing it collides with P15's `GEM_HOME` question, so it wants a
  deliberate setup rather than an improvised one mid-pass. It remains the only route to §2
  (unbounded tool output), which round 8 also did not reach.
- The **majority of sections** in the four scenarios driven here — each was driven at its
  deterministic core, not exhaustively. The per-scenario "Not driven" lists above are the specific
  debts, and the largest single ones are `secret-boundary` §3–§6 (the content mask and `--yolo`),
  `epic-tier` §6 (the stage boundary), and `repl-commands` §7 (`/goal`, the only loop, and the only
  place cost-per-act would be recorded).
