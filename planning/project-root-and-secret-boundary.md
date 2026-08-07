# `lain up <path>`: project root, working directory, and the secret boundary

Requirements draft, 2026-08-07. Not a task plan — no cards, no waves. This is the
"what must be true" pass that `/create-plan` reads afterwards.

## What exists today

There is no project root. `Dir.pwd` is the default for every consumer that takes a
`root:` — `Config.load`, `ProjectDir.new`, `Skill::Library.load`, `Approval::Risk.new`,
`Prompt::Slots.load`, `DSLCatalog.load`, `Workspace::Snapshot`, `Workspace::Restore`,
`Approval::Remembered`, `Review::Source` — and nothing computes one. `lain up` takes no
positional argument; the only `cwd:` in it feeds `Cockpit`'s per-project nvim socket hash.

`Tools::ReadFile` resolves against `session.worker_env.cwd` and reads whatever the
filesystem hands back. There is no read-side control at all. The write side has one:
`Middleware::RefuseSecretWrites` guards `memory_write` and `improvement_write` at the
`ToolRunner#dispatch` seam, and its class comment says in as many words that
`read_file` passing a credential through is out of its scope.

So this chunk adds a concept (root), splits it from a second one that already exists but
is unnamed (cwd), and builds the read-side mirror of a middleware that already works.

---

## Part 1 — Root and cwd are two things

The core requirement, and everything else falls out of it.

- **cwd** is where relative paths resolve and where a spawned pane starts. Narrow, and
  it's a hint about focus, not authority.
- **root** is the authority boundary: the tree `Approval::Risk::OutsideRoot` judges paths
  against, where `.lain/` is found, where config and skills load from, what a repo-wide
  grep is allowed to sweep.

Today they collapse. The monorepo case is exactly the case that breaks the collapse: cwd
should be `services/ingest/`, root should be the repo top, and a permission decision about
`libs/shared/foo.rb` should say yes.

### R1 — Invocation

- `lain up` with no argument: cwd is the process's `Dir.pwd`.
- `lain up <path>`: absolute or relative, expanded against `Dir.pwd`; it becomes cwd.
  A path that isn't an existing directory is a refusal, not a silent fallback.
- `lain up --root <path>` sets root explicitly and skips detection entirely.
- The same resolution serves `lain chat`, not just `up` — `up` is a tmux wrapper around
  `chat`, and a root that only exists under the cockpit would be a trap.

### R2 — Root detection ladder

First match wins. Every rung is a directory that is an ancestor-or-self of cwd.

1. `--root` / `LAIN_ROOT`.
2. `root = ...` in `.lain/config.toml`, if a `.lain/` was found by rung 3.
3. Nearest ancestor holding `.lain/`. This is the monorepo lever: drop `.lain/` at the
   subtree you want to be the project, and it wins over the repo top.
4. Nearest ancestor holding a `.git` **entry** — directory or the one-line pointer file a
   linked worktree uses. Our own upward walk, not `git rev-parse` (R4).
5. Nearest ancestor holding a non-VCS project marker, if we want one at all — see Q-A.
6. No match: **root = cwd**, and the session announces it. Narrow, not broad.

### R3 — Root refusal set

Detection may never *return* any of these, however it got there. An explicit `--root`
may (R6 covers what happens then).

`$HOME`, `/`, `/tmp`, `/var/tmp`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, `$XDG_CACHE_HOME`,
`/etc`, `/usr`, and any mount point that isn't cwd's own. Hitting one means the ladder
falls through to rung 6 and says which rung it rejected and why.

This is the whole answer to "don't take `$HOME` as the project root." It's a stop rule on
the walk, not a special case in the git detector, so it holds no matter which rung would
have produced it.

### R4 — Ignore inherited git environment during detection

`GIT_DIR` and `GIT_WORK_TREE` in the environment hijack git's discovery. Joel's dotfiles
are a bare repo at `~/.cfg` with work-tree `$HOME`; a shell where that alias's env has
leaked makes `git rev-parse --show-toplevel` answer `$HOME` from *anywhere* under it.

So: detect by walking for a `.git` entry ourselves, and if we shell to git at all, scrub
`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` and `GIT_CEILING_DIRECTORIES` from the child.
`WorkerEnv`'s explicit-`nil`-scrubs rule is the mechanism; the removal lever already exists.

R3 catches this too, as defence in depth. Both, because R3 is a blunt stop and R4 is the
statement of *why* the walk was wrong.

### R5 — cwd must lie under root

If it doesn't — `--root` pointing sideways, a symlinked cwd resolving out — refuse at
startup. A cwd outside root means every relative path the model writes is "outside the
project root" to `Approval::Risk`, which turns every call into a prompt.

Resolve both through `File.realpath` before comparing. `Paths#project_hash` already
kernel-resolves for the same reason (nvim's `getcwd()` vs Ruby's `Dir.pwd`).

### R6 — Home posture

`lain up ~` is allowed and enters a named posture, not the ordinary one. Root is `$HOME`,
and:

- the protected-path set of Part 2 is **not** overridable in a home posture, by config or
  by prompt;
- the session says out loud that it's in home posture, in the HUD and in the Journal;
- dotfiles flavour is detected, and it only answers "where do edits belong":
  - **bare repo** (`~/.cfg` + `core.bare=true` + a work-tree of `$HOME`): the tracked file
    set is the editable surface. Untracked files under `$HOME` are not project files.
  - **stow** (`~/dotfiles/<pkg>/...` symlinked into `$HOME`): follow the link and treat
    the package directory as part of root, so an edit lands in the repo rather than
    through a symlink into an untracked copy.
  - **plain**: no special surface. Everything is gated by Part 2 and nothing else.

Flavour detection is a convenience. If it's wrong, Part 2 still holds — that ordering is
the requirement, not an implementation note.

### R7 — One resolved value, injected

A frozen `Lain::Project` (`root`, `cwd`, `posture`, `detected_by`), built once at CLI boot
and passed to every consumer that today defaults `root: Dir.pwd`. `Ractor.shareable?` must
be true; it rides `Session` alongside `WorkerEnv`, sent and never stored on the Timeline.

A spec that parses `lib/` and fails on a *new* `root: Dir.pwd` default is the enforcement,
same shape as `spec/lain/project_dir_spec.rb`. Existing defaults stay as defaults, since
they're what makes the library usable outside a CLI boot — but nothing new gets one.

---

## Part 2 — Secrets, and the four questions

Threat model first, because it decides how much of this is worth building.

**The adversary is accident, not a model that is trying.** A model with `bash` can `cat`,
`base64`, `split`, or `curl -d @file`. Nothing in-process contains that; the plan already
puts real confinement out of process (M5/M6), and CLAUDE.md's Rust placement rule says an
"in-process sandbox" is not a sandbox. What's buildable here buys three things: a key never
reaches a prompt cache by accident, a human sees the first egress of anything
credential-shaped, and there's a durable record of what left. Say that in the docs, so
nobody reads this as containment.

### Q1 — Should we protect high-entropy files? **Yes, as triage — never as a verdict.**

*(Revised 2026-08-07 after Joel's push-back. The first draft said no; that argument was
against entropy as a terminal ACCESS decision, and it does not survive being pointed at a
triage rung feeding a review loop. What follows is the corrected position.)*

Entropy is a bad terminal answer and a good first rung. It fires on minified JS,
base64-embedded assets, lockfile hashes, UUID fixtures and `Cargo.lock` — files an agent
must read — and it misses `password = hunter2`. But:

- A low-entropy password is not worth protecting anyway. In this codebase the low-entropy
  matches are overwhelmingly `test-fake-password`-shaped fixtures, so the miss is cheap.
- A false positive costs **one** review, not one per read: the confirmation cache of Q3 is
  keyed on the content digest, so a `Cargo.lock` cleared once stays cleared until its bytes
  change.
- A false negative is a leak, which is categorically worse.

That asymmetry is the same one `Approval::Risk`'s own comment states — *"every ruling on
these patterns should therefore widen them, never sharpen them."* Entropy-as-triage is
consistent with that doctrine; entropy-as-verdict is not.

**The ladder.** Each rung only reduces what reaches the next.

1. `Lain::Sensitivity` on the path (Q2) — free, name-shaped.
2. **Entropy + issuer-fixed patterns on the content** — free, no model. Clean → egress.
3. **A LOCAL oracle** — flagged content, a verdict and a confidence, no human yet.
4. **The human** — anything the oracle did not clear at threshold.
5. Egress.

**The oracle arm is a seam that already exists.** `RefuseSecretWrites` takes an `oracle:`
with a `NullOracle` default and its comment names this exact arm: *"a future ollama
classifier (OR-1) tomorrow, without this class changing shape."* Underneath sits the tier
system — `Oracle::Heuristic` (free local predicate), `Oracle::Model` (a provider call),
`Oracle::Recorded` (replay), `Oracle::Router`. An `Oracle::Definition` is template + typed
`Tool::Input` schema + tier, content-addressed by digest. So rungs 2 and 3 are a `Heuristic`
and a `Model` over ONE `Definition`, and confidence is a schema field exactly like
`Router::SCHEMA`'s `reason`. No new architecture.

Three constraints on it, each of which is a way to get this wrong:

- **Pin the tier to a LOCAL provider.** Sending a file to a model to decide whether the file
  is safe to send has already sent it. That is fine when the model is ollama on this box —
  but `Oracle::Router` exists to pick models, and a router that escalated this question to
  Claude would defeat the whole control. Pinned, not routable, and asserted by a spec.
- **Confidence needs a threshold set by measurement, not by taste.** A local model's
  self-reported confidence is poorly calibrated; treat it as a rank, not a probability.
  Journal the verdict alongside the human's eventual answer so the threshold is tunable
  against ground truth — which is bench work, and this repo is a bench.
- **An oracle timeout, or a missing ollama, falls toward the human.** `Approval::AutoSurface`
  already states the doctrine: *an ambiguous answer MUST fall toward defer, never toward
  approve.* A degraded rung 3 is a `Capability::Policy` `:degrade` journaling a
  `CapabilityDegraded`, not a silent pass.

### Q2 — Default deny list? **Yes, in two tiers, keyed on path shape.**

One pure classifier, `Lain::Sensitivity`, that answers `ordinary | gated | denied` for a
path. No filesystem access, no entropy, no reading the file to decide. It's called by
everything in Q4, so it has to be cheap and total.

**Denied — never read, no prompt, no in-session override.**
`~/.ssh/id_*`, `~/.gnupg/**`, `~/.aws/credentials`, `~/.config/gh/hosts.yml`, `~/.netrc`,
`*.kdbx`, `~/.password-store/**`, browser `Cookies`/`Login Data`/`key4.db`, `~/.docker/config.json`,
`~/.kube/config`, anything matching `id_ed25519`/`id_rsa` without `.pub`.

Overridable only by hand-editing `.lain/config.toml`, away from the moment of pressure.
That's `Approval::Risk`'s own doctrine for risky answers, applied to a second thing.

**Gated — readable, but only through Q3's redaction and confirmation.**
`.env`, `.env.*`, `.envrc`, `*.pem`, `*.p12`, `credentials.json`, `secrets.y*ml`,
`.git-credentials`, `.npmrc`, `.pypirc`, `.gitconfig` (it carries tokens), `terraform.tfstate`,
`*.tfvars`.

`~/Downloads`, `~/Documents`, `~/Desktop`, `~/Pictures` are gated on a different ground —
not credential shape, but "you didn't mean for the agent to be in there." Same gate, so one
mechanism, but the refusal message says which reason it was.

Both tiers ship as constants with a config table that can **add** entries. Removing a
denied entry needs the hand-edit. Config that only widens is the safe direction, and it's
the same asymmetry `Approval::Risk` argues for on its patterns.

### Q3 — Redacted read with confirm-once? **Yes — this is the best of the three, with four constraints.**

The shape: a gated read returns the file's *structure* with values masked —
`ANTHROPIC_API_KEY=<redacted>` — because for `.env` and `.envrc` the model almost always
needs the keys, not the values. Then a human can release the real bytes.

1. **Redaction happens below the tool, not above it.** Once real bytes are in an `Event`
   they're content-addressed, digested, in the Journal, and in the prompt cache prefix.
   There is no un-indexing it — the exact argument `RefuseSecretWrites` makes for the write
   side. So the middleware rewrites `env[:result]` at the `ToolRunner#dispatch` seam and
   the unredacted string never exists above it.

2. **The confirmation cache is keyed on REGION digests, not on path+mtime and not on the
   whole file.** Two corrections stacked here, and the second is Joel's.

   Not mtime: "unchanged since the last read" has to mean the same bytes. mtime is
   forgeable and this repo already carries the bootsnap (mtime, size) collision as a
   documented trap.

   Not the whole file either. The unit of both flagging and approval is the **flagged
   region** — the entropic run, the matched assignment — so a `.env` gaining an unrelated
   comment does not re-prompt for a key that has not moved. Concretely:

   - A region's identity is the digest of **its own bytes**, never its offset. Digesting
     `(start, length)` would make an inserted line above invalidate everything below it,
     which is whole-file behaviour wearing a region's name. `Canonical` → blake3 on the
     region content, which is the house convention anyway.
   - Every read **re-runs the detector** and yields a current region set. Approval covers a
     set of region digests; any current region whose digest is not in it prompts. Regions
     in the approval that are no longer present are simply dropped.
   - That is what makes this safer rather than merely quieter: a whole-file digest
     approved once and then re-approved wholesale after an edit can carry a **new** secret
     through on the strength of the old decision. A region set cannot — a new secret is by
     construction a region nobody has cleared.

   The same regions are the masking unit, so one concept serves both halves: an approved
   region renders as its real bytes, an uncleared one as `<redacted:N>`. That also buys
   partial approval, which is the behaviour you actually want — release `Cargo.lock`'s
   hashes while `ANTHROPIC_API_KEY` in the same file stays masked.

   The residual, stated rather than buried: region-scoped review means the human is
   approving *those regions'* egress, not the file's. Whatever the detector missed leaves
   with the unflagged remainder and nobody looked at it. Recall of the rung-2 detector is
   therefore what bounds the leak, which is the argument for widening its patterns and for
   the rung-3 oracle reading the whole file rather than only the hits.

3. **A confirmation is session-scoped by default.** Persisting "yes, send `.env.local`"
   across sessions is precisely a risky answer being written down from the prompt, which
   `Approval::Risk::Classification#keepsake` refuses by returning nil. Cross-session
   persistence is a hand-edit. This isn't a new rule, it's the existing one applying.

4. **A redacted read does not count as a read.** `Tools::ReadFile` calls
   `session.record_read(path)`, and the edit-before-write contract asks that read-set
   whether the model has seen the file. A model that has only seen `<redacted>` and then
   writes the file would clobber every secret in it. Redacted reads record separately, and
   an edit against a redacted-only read is refused.

The pattern set for masking is `RefuseSecretWrites::PATTERNS` plus dotenv/TOML/YAML
assignment shapes. That constant should move somewhere both middlewares read it, so the
read side and the write side cannot drift on what a credential looks like.

### Q4 — Exfiltration through bash. **The classifier belongs to every arm, not to `read_file`.**

A control on `read_file` alone is theatre: `cat .env` is a fully literal command,
`Shell::Verdict` covers every byte of it, and a capability set holding `cat` allows it.

So `Lain::Sensitivity` is consulted by:

- `Tools::ReadFile` — the obvious one.
- `Tools::Grep`, `Tools::Glob`, `Tools::ListFiles` — a grep over root must not print
  matching lines out of a gated file, and a glob must not enumerate `~/.ssh`. Results get
  filtered, and the filtering is *reported* ("3 paths withheld"), never silent.
- `Tools::Bash` and `Tools::CoreExec` — on the **parsed term's argv words**, from
  `Shell::Verdict`'s reconstructed argv, not on the raw command string.
- `Tools::WebFetch` and any URL-carrying argv word — the egress half.

Two holes to name rather than pretend away:

- **`Approval::Risk`'s signals don't compose over a single field.** Its own comment says
  so, and carries it as MA-1: `ShellString` looks at `command` for metacharacters,
  `OutsideRoot` looks at path-named fields for escapes, and neither sees the other's half.
  Reading argv words for sensitivity has the same shape as `OutsideRoot`, so it either
  rides MA-1's fix or inherits MA-1's hole. Decide which; don't discover it later.
- **A `Shell::Verdict` abstention is the common case**, and abstention goes to a human
  anyway. So the argv classifier mostly matters for the commands that *are* fully literal —
  which is the `cat .env` case exactly, and that's fine. But it means the control's
  coverage is "literal commands," and a human is the control for everything else.

---

## Part 3 — A typed egress tool, and confining it

Joel's proposal: a first-class `curl`/`wget` tool, confined so that touching a denied path
kills the call.

### R8 — The typed tool earns its place with no sandbox at all

This is the stronger half of the idea and it should land first, independently.

Today egress rides `bash` as a **command string**, which is why `Approval::Risk::ShellString`
has to hunt metacharacters and `Url` has to regex the whole value. A tool with declared
fields — `url`, `method`, `headers`, `body`, `timeout` — hands the classifier a real `url:`
to read instead of a string to grep. That is a partial discharge of MA-1 ("the signals do
not compose over a single field") for the egress case specifically, and it is worth doing on
its own merits.

**Typed fields only, never an argv passthrough.** `curl` reads files through `-d @file`,
`-T`, `--upload-file` and `-K <configfile>`, writes them with `-o`, and speaks `file://`.
A passthrough argv is bash with extra steps and gives back everything the typed shape bought.
The tool composes its own argv from validated fields, the way `CLI::Up` already composes
tmux argv arrays rather than command strings.

### R9 — Confinement is Landlock, not strace

**strace cannot reject.** By the time `openat("~/.ssh/id_ed25519")` appears in the trace the
read has happened or is about to; strace is a monitor. `--inject` is per-syscall and not
conditional on the argument, so it cannot fail selectively on a path. Killing afterwards is
detection, not prevention.

**Drop the wireshark half entirely.** It is TLS. The capture shows a connection, never a
payload, so it answers no question the file-open half does not answer better.

**Landlock is the actual primitive.** Kernel 5.13+ for filesystem, ABI 4 (6.7) for TCP
bind/connect; this box runs 6.8. Unprivileged, path-based, applied by the process to itself
before `exec`, enforced by the kernel — a whitelist rather than a monitor. Rust crate
`landlock`.

Placement follows CLAUDE.md's rule without argument: confinement is isolation-relevant, so
it lives **out of process** in `crates/lain-core`, never in `ext/lain`. The rule's own words
are that an in-process sandbox is not a sandbox.

The ruleset a confined egress call gets: read access to root only, no access to the denied
set, no write access anywhere except a named scratch path, and network restricted to the
declared `url`'s host if ABI 4 is available.

### R10 — macOS is a degraded arm, not a blocker

`sandbox_exec`/Seatbelt profiles work and are deprecated-undocumented. Whatever we do there,
the shape is already built: `Capability::Policy` on `:degrade` journals one
`Telemetry::CapabilityDegraded` per missing capability, and the call falls back to the human
gate. A platform without Landlock loses the kernel rung and keeps every other rung —
sensitivity classifier, entropy triage, local oracle, human — which is the whole point of
building the ladder rather than one control.

The failure that must not happen is a missing sandbox reading as a granted one. `:degrade`
is loud by construction, so use it rather than an `if landlock_available?`.

---

## Where the pieces live

| Piece | Home | Shape |
|---|---|---|
| `Lain::Project` | `lib/lain/project.rb` | frozen value, `Ractor.shareable?`, sent-not-stored |
| Root ladder | `lib/lain/project/resolver.rb` | pure over an injected filesystem probe, so it's unit-testable without a real `$HOME` |
| Dotfiles flavour | `lib/lain/project/dotfiles.rb` | three named detectors, `:seam` specs against real repos |
| `Lain::Sensitivity` | `lib/lain/sensitivity.rb` | pure, name-shaped, no IO, no entropy |
| `Middleware::RedactSecretReads` | `lib/lain/middleware/` | mirror of `RefuseSecretWrites`, same seam, `Telemetry::ReadRedacted` |
| Credential patterns | shared constant | one table, both middlewares |

Ruby throughout. None of it passes CLAUDE.md's five-part Rust test — the classifier is
per-call and cheap, and the resolver is IO.

---

## Open questions for Joel

**Q-A. Non-VCS project markers at rung 5?** `package.json`, `Cargo.toml`, `go.mod`,
`Gemfile`, `pyproject.toml`. My read: **skip it.** In a monorepo the nearest `package.json`
is a *package*, not the project, so it would fight rung 4 and usually lose the case you
wanted. Rung 3's `.lain/` already gives you an explicit way to say "this subtree is the
project," and it's one you control.

**Q-B. Does a gated read prompt inline in chat, or park in `Approval::Queue`?** Inline is
what you want when you're at the keyboard; the queue is what makes it work for a headless
run. `Approval::Escalation` already has the ladder. My read: inline, with the queue as the
non-TTY fallback, no new mechanism.

**Q-C. Should `denied` be invisible or loud?** A `read_file` on `~/.ssh/id_ed25519` can
answer "refused: protected path" or "no such file." Loud teaches the model the boundary and
it stops asking; invisible is marginally better against a model that's probing. Given the
threat model above I'd go loud, but it's a real fork.

**Q-D. Does the `.lain/` at rung 3 need to be *committed* to count?** An uncommitted
`.lain/` in a directory you don't own — a vendored dep, a downloaded archive — silently
redefines the project root. Probably paranoid. Flagging it.

**Q-E. Multi-root?** A monorepo session that legitimately spans two subtrees. My read:
one root, and rung 4 (repo top) is the answer for that case. Adding a root *list* makes
every `within_root?` test a fold and I don't think it earns that yet.
