# Container facts and passed-value masking

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

This plan settles the 2 UX points that QA round 25 left for the human.

1. **Container facts.** Under `--exec docker` with `--judge-facts facts` or `request`, the judge can no longer approve a bash call.
   Every stage resolves to `unresolved` with the `container_backend` anomaly, so the bar is never empty, and every call waits
   for a human (`planning/specs/qa-round-25-fixes.md:2558-2561`). This plan resolves container programs from the image itself.
   Each resolution and each run inspects the image tag for its ID (0.04s each), and the run names that ID, so a rebuilt tag
   takes effect on the next call. A tag rebuilt in the moment between a ruling and its run is the 1 case where the facts and
   the run can name different IDs. Lain lists
   every executable on the image's `PATH` with 1 `docker export` per image ID and caches the listing on disk under the ID.
   A path under a bind mount resolves on the host, because the mount is at the same path on both sides. Each command runs in a
   fresh `docker run --rm`, so no call can replace an image file for a later one: an image path is never writable by the agent
   and never fresh, so it classes `system`. A mounted path keeps the host's checks.
2. **Passed-value masking.** A project's `env pass:` lets a variable such as `DATABASE_URL` reach bash. Today its value is masked
   in bash output only where the region detector recognises the printed shape (`lib/lain/config/builder.rb:165-173`). This plan
   masks the literal bytes that matter wherever they recur: whatever the region detector finds when it scans the value itself
   (a DSN's password, a token), plus random-looking tokens in a value whose name hints at a connection string
   (`*_URL`, `*_DSN`, `*_URI`, `*DATABASE*`, `*CONN*`).

The human asked for the refactors first, so the features are cheap to add: 1 exec backend and 1 child environment built per
launch, with the resolver and the masker both reading them; the entropy test as a named unit; the literal-secret selection as a
named unit; 1 helper for "detect and mask". Rulings in the human's own words, 2026-10-18: "use the docker container's SHA to
only have to resolve various facts once per SHA"; "mask higher entropy values from environment variables and/or use the name of
the environment variable to help guide us".

Roadmap: follows item 63 (`ROADMAP.md`). Item 64 is this plan.

## Grounding

2026-10-18 at `cb5f41cc`. Files checked: `lib/lain/cli/{exec_backend,wiring,tool_guard,switchboard}.rb`,
`lib/lain/cli/wiring/{toolset_build,board_build,observers}.rb`, `lib/lain/exec/{docker,child_env,local}.rb`,
`lib/lain/shell/executable.rb`, `lib/lain/shell/executable/{resolver,stat,fresh,run_files}.rb`,
`lib/lain/approval/{judged,composed_term}.rb`, `lib/lain/approval/judge/facts.rb`, `lib/lain/tools/bash.rb`,
`lib/lain/tripwire/ledger.rb`, `lib/lain/telemetry/{exec_resolution,exec_record,read_redacted,capability_degraded}.rb`,
`lib/lain/session_record.rb`, `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/sensitivity/{regions,masking}.rb`,
`lib/lain/credential_patterns.rb`, `lib/lain/config.rb`, `lib/lain/config/builder.rb`, `lib/lain/paths.rb`,
`lib/lain/atomic_file.rb`, `lib/lain/confine/sandbox.rb`, `lib/lain/consolidation.rb`, `lib/lain/cli/improve.rb`,
`lib/lain/bench/harness.rb`, `lib/lain/bench/harness/confinement.rb`, `lib/lain/worker_env.rb`, `exe/lain`, `ARCHITECTURE.md`
(§ Bounding a bash call, § The secret boundary), `planning/qa/scenarios/{bash-confinement,secret-boundary,subagents-and-backends}.md`,
and the specs each card names.

Production paths, as read and traced by the panel:

- `Wiring#exec_resolver` (`lib/lain/cli/wiring.rb:816-818`) calls `ExecBackend.resolver_for(options[:exec], root:, fresh:)`,
  which returns `Shell::Executable::Resolver::CONTAINER` for docker (`lib/lain/cli/exec_backend.rb:57-61`). The exec
  backend itself is built separately, as `ToolsetBuild#initialize`'s `exec:` default (`lib/lain/cli/wiring/toolset_build.rb:210-212`).
  So 2 sites map the same `--exec` name, and the resolver never sees the image.
- That 1 memoized resolver reaches all 3 readers: the bash tool (`wiring.rb:810`, then `Tools::Bash.new(resolver:)`), the
  ladder's `ComposedTerm` and the judge's `Facts::Resolving` (both through `BoardBuild`'s `Classifiers#executables`,
  `board_build.rb:494`, `:584`; `switchboard.rb:533`). `Judged#ruled` approves when the bar is empty (`judged.rb:204`).
  `Wiring#wire_agent` registers the real `Fresh` before the toolset is built (`wiring.rb:348-349`).
- `Shell::Executable::Resolver.new(root:, fresh:, stat:, host_env:)` already takes the filesystem (`Stat`) and the base
  environment as ports (`resolver.rb:25`). `Bound`, `RunFiles` and `Fresh` read only `Stat`'s 8 methods: `lstat` (`.symlink?`,
  and `.ctime` in `Fresh`), `readlink`, `realpath`, `real`, `children`, `directory?`, `executable?`, `writable?` (`stat.rb`).
  `executable?`, `directory?` and `writable?` answer false for a missing path; only `lstat`, `readlink` and `realpath` raise.
- `Exec::Docker` runs each command as `docker run --rm --quiet --init` with the project mounted at its own path, plus the cwd
  when it is outside the project (`docker.rb:50`, `:181-190`). `PATH` does not cross into the container (`CROSSES`, `:65`;
  `crossing`, `:205`). An image's `ENTRYPOINT` receives the argv (`rhysd/actionlint:latest` has one).
- `Middleware::RedactSecretReads#printed` masks bash output with `Output` (`redact_secret_reads.rb:294-299`, `:763-780`):
  every detected region, plus the recurrences of `session_secrets` (`:303-308`). That method keeps a value only if its NAME
  matches `Exec::ChildEnv::SECRET` and it is at least `LITERAL_FLOOR = 8` bytes. `Row#recurrences` keeps a literal of 6 bytes
  or more (`:670-684`). The middleware reads raw `ENV` (`environment: ENV`, `:189`), and `ToolGuard#read_kwargs` passes none
  (`tool_guard.rb:484-488`).
- `Sensitivity::Regions` already holds the entropy test as private class methods (`high_entropy?`, `shannon`,
  `predictable?`; `regions.rb:294-341`) and already masks a URL's password (`PASSWORD_SHAPES["url credentials"]`);
  `Regions.detect("postgres://app:hunter2xyz@db.local/app")` returns exactly `hunter2xyz`.
- `Sensitivity::Masking.render(text, Regions.detect(text), ordinals:)` appears verbatim at `lib/lain/consolidation.rb:255`
  and `lib/lain/cli/improve.rb:127`.
- A startup notice is an `Observers` fold over a journal record (`cli/wiring/observers.rb`, `Unconfined` over
  `CapabilityDegraded`), read once at startup (`wiring.rb:294`). A notice raised later in a chat goes through `Wiring`'s
  `@notice` seam, set in `Wiring#run` before anything is built (`wiring.rb:291`).

Where docs and code disagree, and which won:

1. The `Resolver::CONTAINER` comment says resolving in the container was rejected because it costs a 2nd `docker run` per
   call (`resolver.rb:373-376`), and the round 25 plan said the same (`qa-round-25-fixes.md:196`). Per image ID instead of per
   call, the cost is 1 export per image, measured at 0.47 to 0.63s (Spike findings). The human's 2026-10-18 ruling wins; T14
   rewrites the comment.
2. `ARCHITECTURE.md:934` says "`--exec docker` is not wrapped; the container is its boundary". That stays true for the
   sandbox. `planning/qa/scenarios/bash-confinement.md:261-263` and `subagents-and-backends.md:417-420` say every docker stage
   is unresolved with `container_backend`, which T13 makes false. T14 corrects both.

Runtime premises probed rather than read (Spike findings, and the panel's probes): what `docker image inspect` prints and how
fast; whether `docker run` accepts an image ID; whether `docker export` keeps symlinks, modes and owners; whether a listing is
byte-identical across runs; what the container user can write under podman; which spike image has an `ENTRYPOINT`; what
`Regions.detect` finds on 65 sample values and on this machine's real environment; how the T7 rule scores on the corpus.

## Compatibility

| Surface | Verdict | Evidence |
|---|---|---|
| `lain` gem public API, including `CLI::ExecBackend.resolver_for` and `RedactSecretReads.new(environment:)` | free to break | version `0.1.0`, never tagged or released; `resolver_for` has 1 caller (`wiring.rb:817`) and 1 spec; `environment:` has 0 callers in `lib/` and 1 spec use (`redact_secret_reads_spec.rb`); no consumer under `~/dev` (the `~/dev/lain-*` directories are stale copies from 2026-08) |
| `.lain/config.rb` `env` table | unchanged | no card edits the DSL |
| Session journal records | additive | `SessionRecord::FORMAT = 1`, and added keys do not bump it (`session_record.rb:25-29`). 2 new record types: `exec_image` and `command_redacted`. Readers skip an unknown type (`session_record/replay.rb`, the class comment at `:52-54`). `exec_resolution` under docker now carries resolved stages; `to_journal` keeps its shape (`executable.rb:41-46`). `Tripwire::Ledger` reads `exec_resolution` (`tripwire/ledger.rb:80`); an image path is never fresh and docker is never confined, so it raises no new hits |
| `docker run` argv | free to change | it names the image ID inspected for that call in place of the tag; no stored data; specs in `spec/lain/exec/docker_spec.rb` pin the argv and change with T9 |
| On-disk image listing cache | new | `$XDG_CACHE_HOME/lain/exec-images/v1/<id>.json`; nothing writes under `cache_home` today (`paths.rb:235`); purgeable, keyed by format version and image ID |
| bash output under `env pass:` | intended change | more of a passed value is masked; `redact_secret_reads_spec.rb:1374` (a long value under a non-secret name stays unmasked) keeps passing because that name is not passed |

No must-keep surface blocks a large simplification.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| How does lain learn an image's ID and `PATH`? | `docker image inspect --format '{{.Id}}'` prints 64 hex chars in 0.05s; a missing image exits 125 "image not known". `docker run --rm` accepts the full ID, a 12-char short ID and `sha256:<id>`. All 3 local images declare `PATH` in `.Config.Env`. `rhysd/actionlint:latest` declares `ENTRYPOINT ["/usr/local/bin/actionlint"]` | podman 6.1 (docker CLI emulation) on this machine, images `alpine:latest`, `ubuntu:24.04`, `rhysd/actionlint:latest`; `~/tmp/lain/spike-evidence-2026-10-18/image-facts/`; the panel's `docker image inspect` |
| Which listing method? | `docker create` (no start), `docker export`, `docker rm`, with the tar read by `Gem::Package::TarReader`. Runs no code in the image, keeps every symlink hop (`/bin -> usr/bin`, `/usr/bin/awk -> /etc/alternatives/awk -> /usr/bin/mawk`), mode and uid/gid. 0.47 to 0.63s per image end to end; JSON of 43 to 47KB. `docker cp` follows directory symlinks and hides `/bin -> usr/bin`; a shell script in the image needs `sh`, `stat` and `readlink` and loses chain hops | prototype `image_facts.rb` in the evidence directory. Hard links arrive as tar link entries with their own mode |
| Is a listing cacheable by image ID alone? | Yes: 2 runs per image gave byte-identical JSON. `--user` and `--env FOO` do not change the container `PATH`; lain never crosses `PATH` | `cmp` of `*_2.json` against `*.json` |
| Can a call change an image file for a later call? | No. Each call is a fresh `docker run --rm`. Inside 1 call, podman's container root can write `/usr/bin` (`uid_map 0 1000 1`), and `--user 1000:1000` cannot; either way the write ends with the container | `touch /usr/bin/zz` results |
| What does the region detector find on a passed value alone? | 24 of 32 sample secrets, including every URL password (postgres, mysql, redis, amqp, mongodb+srv), `Password=` key-value pairs and `?token=` query values, each masking only the secret bytes. Misses: 16-char base64 and hex, 22-char base64url, bare opaque passwords, `?sig=` with 16 chars. False positives: a 40-hex git SHA and a 64-hex sha256, which entropy cannot tell from a hex key | 65-value corpus; `~/tmp/lain/spike-evidence-2026-10-18/pass-mask/{corpus,measure}.rb` |
| What should a hinted name add? | The grid's best row (16 chars, 3.5 bits, lowercase, uppercase and digits) scores 27 true positives and 2 false positives. Adding a hex branch (16 hex chars with at least 1 letter, 3.0 bits) scores 28 and 2. Without the 3-class rule, UUIDs and long identifiers become false positives. The 4 bare opaque passwords stay unmasked; no threshold separates them from path components. Pure-digit tokens must be excluded from the hex branch: a 16-digit number and a 17-digit timestamp pass it otherwise | grid in `measure.rb`; the panel's `probe_hinted_rule_t7.rb` in this session's scratchpad |
| Does a URL-userinfo rule belong in `Regions`? | It is already there. 6 repo hits for `scheme://user:pass@`, all examples | `q5.txt` |
| What does the real environment look like? | 85 variables. As if each were passed, the value scan and the hinted rule mask 6, 2 of them secret-named (already masked, and `env pass:` refuses them) and 4 tool-state blobs (`__MISE_*`, `DIRENV_*`) nobody would pass. `PATH` and `LS_COLORS` stay unmasked | `env.rb`, which prints names and lengths only |

Not measured: a large image (export cost grows with image size, so T12 has a budget and caches a timeout), a shell-less image
(export runs no code, so it should not matter), and real docker as opposed to podman (manual pass in Integration checks).

## Shared files

`ROADMAP.md`, `.rubocop.yml` (a `Metrics/*` raise goes in its own commit by the main session, saying why), and this plan.
Cards hand back 1-line diffs for these.

Implementer notes for every card: an example whose only assertion is `expect { ... }.not_to raise_error` counts against
`bin/spec-census`'s ceiling, so pair it with an assertion on state. A spec that needs docker uses a fake `docker` script on an
injected `PATH`, as `spec/lain/cli/exec_backend_spec.rb` does; no spec in the default tiers may need a real client. A spec that
writes the image cache passes its own `Paths` over a tmpdir, never the real `~/.cache`.

## Rejected options

- **Resolve inside the container on every call:** a 2nd `docker run` per call. The per-ID cache costs 1 export per image.
- **`docker cp` per `PATH` directory:** it follows a directory symlink and hides `/bin -> usr/bin`, and chain targets outside
  `PATH` need more calls.
- **A shell script in the image (`find`, `stat`, `readlink -f`):** needs a shell in the image, runs code there, and returns
  only final realpaths, not the hops.
- **A second resolver class beside `Resolver::Bound`:** `Resolver` already takes `Stat` and the base environment as ports.
  The docker side supplies a `Stat` that answers from the listing and the host, and nothing in `Bound` is copied.
- **Class an image path by the container user's uid/gid and mode:** the class asks who could have put the file there before
  this call, and in a fresh `--rm` container nobody could. Under podman the mode check made every image path `user`, and the
  judge's guidance defers on anything not `system` (`judge/facts.rb`), so every docker call would still have waited for a human.
- **Pin the tag once per process:** a `docker build -t same:tag` during a chat would be ignored until relaunch. An inspect per
  call costs 0.05s, and the listing is still cached per ID.
- **Pull a missing image during approval:** the pull would run before anyone ruled and spend the command's deadline twice.
  The approved `docker run` pulls by tag as today, and the next call's inspect finds the ID.
- **Prefetch the listing at launch:** no caller needs it before the first bash call, and the export would run for chats that
  never use bash.
- **A notice on every first export:** 0.5s once per image on the spike's images. Only a failed listing changes what the human
  sees, so only that gets a notice.
- **Carry the ruled image ID through to the run:** closes the moment between a ruling and its run in which a rebuilt tag could
  run an ID nobody ruled on, at the cost of threading a `Pin` from the ladder through the effect to `Docker#call`. A rebuild in
  that moment is the human's own action; revisit if a bench run ever needs the guarantee.
- **A URL-userinfo rule:** `Regions` already masks a URL's password (Spike findings).
- **Mask every passed value whole:** masks `RAILS_ENV=development` wherever "development" appears in output.
- **Run the hinted rule on every passed name:** the rule was measured on hinted names; widening it would mask build IDs and
  opaque identifiers in names that carry no credential.
- **`env mask:` and `env unmask:` config keys:** neither ruling asks for them, and the spike found no false positive among
  variables anyone would pass. A real false positive is the reason to add them.
- **Per-kind counts on `command_redacted`:** a literal and a region can coalesce into 1 span, so the split is not well defined,
  and nothing reads it. 1 total.
- **Bench parity (bench bash with the project's `env pass:`):** the bench reads no project config by design
  (`tool_guard.rb:425-430`), so its child environment cannot see `env pass:`. A round 26 item, outside this plan.
- **Journal the image ID on every `exec_resolution` record:** 1 `exec_image` record per ID per run says the same.

## Open decisions

None.

## Dependency graph

```mermaid
flowchart LR
  T1 --> T5
  T4 --> T5
  T5 --> T6
  T6 --> T7
  T2 --> T7
  T6 --> T8
  T9 --> T12
  T10 --> T11
  T10 --> T12
  T1 --> T13
  T11 --> T13
  T12 --> T13
  T13 --> T14
  T7 --> T15
  T8 --> T15
  T14 --> T15
  T3
```

T1, T2, T3, T4, T9 and T10 can start at once. T3 has no dependants.

## Tasks

### T1: Build the launch's exec backend once and derive the resolver from it          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/exec_backend.rb`, `lib/lain/cli/wiring.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`spec/lain/cli/exec_backend_spec.rb`, `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`
**Reuse:** `ExecBackend#backend` and its `docker`/`refuse_without_client!` (`exec_backend.rb:104-130`); the `child_env:`
built from `config.env_pass` at `toolset_build.rb:212`; `Wiring#exec_resolver`'s memo (`wiring.rb:816-818`); `Wiring`'s
`@paths` (`:270`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#exec_backend` (new, memoized), read by `Wiring#exec_resolver` and by the `ToolsetBuild.new`
call at `wiring.rb:803`, which passes `exec: exec_backend.backend`

Today 2 sites map `--exec` to a backend: `ExecBackend.resolve` (through `ToolsetBuild`'s `exec:` default) and
`ExecBackend.resolver_for`. After this card, `Wiring` holds 1 `ExecBackend` built with the launch's child environment, its
durable journal, its `Paths` and its notice seam (`@notice`, set in `Wiring#run`
before anything is built, `wiring.rb:291`); the toolset gets that instance's backend, and the resolver comes from the same instance.
`resolver_for` is deleted. Docker still resolves to `Resolver::CONTAINER`; T13 changes that. `journal:`, `paths:` and `notice:`
have no reader until T13; they are passed here so T13 does not edit `wiring.rb` while T5 does.

`ToolsetBuild`'s `exec:` default stays: 10 spec callers rely on it (`search_rules`, `attachment/store`, `subagent_gate`,
`backend`, `chat_launch`, `wiring`, `switchboard`, `epic_driver/factory`, `issue_actor` twice). Production passes `exec:`
explicitly, so the default is a spec convenience and no longer a production mapping; its comment says so.

**Acceptance criteria**

```gherkin
Scenario: The toolset and the resolver come from one backend
  Given a Wiring built with exec "local"
  When the toolset is built and the resolver is read
  Then the bash tool's exec is the backend the Wiring's ExecBackend built
  And the resolver is a Shell::Executable::Resolver over the project root

Scenario: Docker still resolves nothing on the host
  Given an ExecBackend for "docker" with a docker client on its PATH
  When its resolver is read
  Then it is Shell::Executable::Resolver::CONTAINER

Scenario: The backend is built once
  Given an ExecBackend for "docker"
  When backend is called twice
  Then both calls return the same object

Scenario: env pass still reaches a local child through the production build
  Given a project whose .lain/config.rb says env pass: %w[DATABASE_URL]
  When Wiring builds the toolset and bash runs printenv DATABASE_URL
  Then the child prints the host's DATABASE_URL
```
Spec files: `spec/lain/cli/exec_backend_spec.rb`, `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`

**Interface**

```ruby
class Lain::CLI::ExecBackend
  def initialize(name = nil, root:, image: nil, path: ENV.fetch("PATH", ""), filesystem: File,
                 child_env: Exec::ChildEnv::DEFAULT, journal: Channel::Null.instance, paths: Paths.new,
                 notice: ->(_text) {})
  def backend                      # memoized; same object on every call
  def resolver(fresh:)             # host Resolver for local, Resolver::CONTAINER for docker
  attr_reader :child_env, :journal, :paths, :notice
end

class Lain::CLI::Wiring
  def exec_backend                 # @exec_backend ||= ExecBackend.new(options[:exec], image:, root:, child_env:, journal:, paths: @paths, notice: @notice)
end
```

**Stop and report if:**
- `ToolsetBuild.new` has a production caller other than `wiring.rb:803` (grep `ToolsetBuild.new` under `lib/` and `exe/`).
- `exe/lain:796`'s preflight `ExecBackend.resolve` cannot keep working unchanged.
- `ExecBackend` instances are frozen, so `backend` cannot memoize; report rather than unfreezing a class other code shares.

### T2: Name the entropy test as its own unit          [risk: low]

**Depends on:** none
**Files:** `lib/lain/sensitivity/entropy.rb` (new), `lib/lain/sensitivity/regions.rb`, `spec/lain/sensitivity/entropy_spec.rb` (new)
**Reuse:** `Regions.high_entropy?`, `shannon`, `predictable?`, `slash_joined_words?`, `alphabet_run?` and the
`HEX_*`/`BASE64_*`/`ALPHABET_RUN`/`WORD_SEGMENT` constants (`regions.rb:47-79`, `:294-341`)
**Shared-file wiring:** none
**Reachable from:** `Sensitivity::Regions.detect` (`regions.rb:170`), reached from every masking site, calls `Entropy.high?`
and `Entropy.predictable?` in place of its private methods

A move with no behavior change: T7 adds a second threshold beside the first, and the measure belongs in one home.

**Acceptance criteria**

```gherkin
Scenario: The strict test answers as Regions did
  Given a 32-char random base64 token and a 40-char git SHA
  When Entropy.high? is asked about each
  Then both are true, as Regions' private test said before the move

Scenario: A path of words is predictable
  Given "var/lib/postgresql/data"
  When Entropy.predictable? is asked
  Then it is true

Scenario: Regions still finds what it found
  Given the existing regions_spec
  When it runs after the move
  Then every example passes unchanged
```
Spec files: `spec/lain/sensitivity/entropy_spec.rb`, `spec/lain/sensitivity/regions_spec.rb` (unchanged, must stay green)

**Interface**

```ruby
module Lain::Sensitivity::Entropy
  def self.shannon(token)          # bits per char
  def self.high?(token)            # Regions' current hex/base64 thresholds
  def self.predictable?(token)     # slash-joined words or an alphabet run
end
```

**Stop and report if:**
- A Regions constant moved here is read by another file (grep `Regions::HEX_`, `Regions::BASE64_`).
- The example count of `spec/lain/sensitivity/regions_spec.rb` changes.

### T3: Give "detect and mask" one helper          [risk: low]

**Depends on:** none
**Files:** `lib/lain/sensitivity/masking.rb`, `lib/lain/consolidation.rb`, `lib/lain/cli/improve.rb`,
`spec/lain/sensitivity/masking_spec.rb`
**Reuse:** `Masking.render` and `Regions.detect`
**Shared-file wiring:** none
**Reachable from:** `Consolidation#withheld` (`consolidation.rb:254-256`) and `CLI::Improve`'s `trace` (`improve.rb:125-128`)

The human asked for duplicated masking code to be folded while this area is open. Neither feature calls the helper.

**Acceptance criteria**

```gherkin
Scenario: One call masks every detected region
  Given text holding an AWS key id and plain words
  When Masking.redact is called with ordinals
  Then the key is replaced by a numbered placeholder and the words are unchanged

Scenario: Consolidation and improve mask through it
  Given the existing consolidation and improve specs that pin masking
  When they run
  Then they pass unchanged
```
Spec files: `spec/lain/sensitivity/masking_spec.rb`, `spec/lain/consolidation_spec.rb` and `spec/lain/cli/improve_spec.rb`
(unchanged, must stay green)

**Interface**

```ruby
module Lain::Sensitivity::Masking
  def self.redact(text, ordinals:) # render(text, Regions.detect(text), ordinals:)
end
```

**Stop and report if:**
- Another `Masking.render(..., Regions.detect(...))` site exists beyond the 2 named (grep); add it here rather than leave a
  third copy.

### T4: Move the literal-secret choice out of the bash masker          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/sensitivity/literals.rb` (new), `lib/lain/exec/child_env.rb`, `lib/lain/middleware/redact_secret_reads.rb`,
`spec/lain/sensitivity/literals_spec.rb` (new), `spec/lain/exec/child_env_spec.rb`
**Reuse:** `RedactSecretReads#session_secrets` and `LITERAL_FLOOR` (`redact_secret_reads.rb:85`, `:303-308`);
`Exec::ChildEnv.new(pass: [], env:)` (`child_env.rb:59`) and `ChildEnv::SECRET`
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#printed` (`redact_secret_reads.rb:294`), which builds `Literals` per bash result

No behavior change. `Literals` takes a child environment from the start, so T5 changes where it comes from and not its shape:
until T5, the middleware wraps its own `@environment` as `Exec::ChildEnv.new(env: @environment)`. `ChildEnv` gains
`#environment`, the live `@env.to_h`. The floor and the secret-name test move into `Literals`, where T6 and T7 add the
passed-value rules.

**Acceptance criteria**

```gherkin
Scenario: A secret-named value is a literal
  Given a child env whose environment has API_TOKEN set to a 20-byte value
  When Literals lists its strings
  Then the list holds that value

Scenario: A short or plain-named value is not
  Given SESSION_KEY set to 7 bytes and DEPLOY_REGION set to "eu-west-1-zone"
  When Literals lists its strings
  Then neither value is listed

Scenario: A lent value counts as well
  Given an empty environment and a worker env lending API_TOKEN as a 20-byte value
  When Literals lists its strings
  Then the list holds that value

Scenario: The bash masker behaves as before
  Given the backstop examples in redact_secret_reads_spec
  When they run
  Then they pass unchanged
```
Spec files: `spec/lain/sensitivity/literals_spec.rb`, `spec/lain/exec/child_env_spec.rb`,
`spec/lain/middleware/redact_secret_reads_spec.rb` (unchanged, the examples at `:1315-1385` must stay green)

**Interface**

```ruby
class Lain::Sensitivity::Literals
  FLOOR = 8
  def initialize(child_env:, lent: {})     # lent: the worker's env Hash
  def to_a                                 # Array<String>, unique, frozen
end

class Lain::Exec::ChildEnv
  def environment                          # @env.to_h, read on every call
end
```

**Stop and report if:**
- `LITERAL_FLOOR` is read outside `redact_secret_reads.rb` (grep the tree, specs included).
- The "unreadable env withholds the result" example (`redact_secret_reads_spec.rb`, near `:1382`) stops passing: the raise
  from `to_h` must still happen inside the middleware's rescue.

### T5: Hand the bash masker the launch's child environment          [risk: medium]

**Depends on:** T1, T4
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/cli/tool_guard.rb`, `lib/lain/cli/switchboard.rb`,
`lib/lain/cli/wiring/board_build.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`,
`spec/lain/cli/tool_guard_spec.rb`, `spec/lain/cli/switchboard_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`
**Reuse:** `Wiring#exec_backend.child_env` (T1); `ToolGuard::Inputs` (`tool_guard.rb:66-69`) and its 2 builders,
`Switchboard#initialize` (`switchboard.rb:242`) and `ToolGuard.detached` (`tool_guard.rb:437-446`)
**Shared-file wiring:** none
**Reachable from:** `Wiring` passes `exec_backend.child_env` to `BoardBuild`, which passes it to `Switchboard.for`
(`board_build.rb:74`), which puts it on `ToolGuard::Inputs`; `ToolGuard#read_kwargs` hands it to `RedactSecretReads.new`

The masker and the bash child then read 1 object for "which variables reach a command". `RedactSecretReads.new(environment:)`
becomes `child_env:`, defaulting to `Exec::ChildEnv::DEFAULT` (the many `described_class.new(ledger:, queue:, journal:)` calls
in its spec, `spec/lain/approval/secret_surface_spec.rb` and `spec/lain/session_record/replay_spec.rb` rely on a default).
`ToolGuard::Inputs` gains `child_env`, with the same default; `ToolGuard.detached` keeps it, which is what its runs' children
already get.

**Acceptance criteria**

```gherkin
Scenario: The masker reads the launch's child env
  Given a ChildEnv over an environment where API_TOKEN is a 20-byte value
  And a bash result whose output prints that value
  When the bash masker built by ToolGuard with that ChildEnv masks the result
  Then the value is replaced by a placeholder

Scenario: The production board carries the launch's child env
  Given a BoardBuild handed the ChildEnv an ExecBackend holds
  When the board's guard stack is built
  Then its RedactSecretReads holds that ChildEnv

Scenario: A detached run keeps the default child env
  Given ToolGuard.detached
  When its guard stack is built
  Then its RedactSecretReads holds Exec::ChildEnv::DEFAULT
```
Spec files: `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/cli/switchboard_spec.rb`,
`spec/lain/cli/wiring/board_build_spec.rb`

**Interface**

```ruby
class Lain::Middleware::RedactSecretReads
  def initialize(ledger:, queue:, journal: Channel::Null.instance, requester: nil, related: Unrelated,
                 child_env: Exec::ChildEnv::DEFAULT)
end

Lain::CLI::ToolGuard::Inputs      # gains :child_env, default Exec::ChildEnv::DEFAULT
```

**Stop and report if:**
- Another builder of `ToolGuard::Inputs` exists in `lib/` beyond the 2 named (grep `Inputs.new`).
- `Switchboard.for` has a caller other than `board_build.rb:74`.

### T6: Mask what the region detector finds in a passed value          [risk: high]

**Depends on:** T5
**Files:** `lib/lain/sensitivity/literals.rb`, `spec/lain/sensitivity/literals_spec.rb`,
`spec/lain/seams/passed_value_masking_spec.rb` (new)
**Reuse:** `Regions.detect`; `ChildEnv#passes?` and `#environment`; `Literals::FLOOR`
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#printed`, through the `Literals` built over the launch's `ChildEnv` (T5)

For each variable the child env passes, and each lent variable with a passed name, `Literals` runs `Regions.detect` on the
value and lists the bytes of every region it finds. A DSN then lists only its password, so the password is masked wherever it
recurs: printed alone, inside an error message, or cut out of the URL by a pipeline the output detector cannot read. A region
under `FLOOR` bytes is never listed.

**Acceptance criteria**

```gherkin
Scenario: A passed DSN's password is masked where it is printed alone
  Given env pass names DATABASE_URL set to "postgres://app:hunter2xyz@db.local/app"
  And a bash result whose output is "hunter2xyz"
  When the bash masker masks it
  Then the output holds a placeholder and not "hunter2xyz"

Scenario: The readable part of the URL stays readable
  Given the same DATABASE_URL
  And a bash result whose output is "connecting to db.local/app"
  When the bash masker masks it
  Then the output is unchanged

Scenario: A passed value with nothing detectable is not listed
  Given env pass names RAILS_ENV set to "development"
  When Literals lists its strings
  Then "development" is not listed

Scenario: The production path masks a passed password
  Given a project whose .lain/config.rb says env pass: %w[DATABASE_URL]
  And DATABASE_URL holds a password in the host environment
  When Wiring builds the chat and bash prints the password alone
  Then the tool result holds a placeholder in place of the password
```
Spec files: `spec/lain/sensitivity/literals_spec.rb`, `spec/lain/seams/passed_value_masking_spec.rb` (`:seam`: the real
`Wiring`, `ChildEnv`, guard stack and bash tool, with no double between them)

**Stop and report if:**
- A region `Regions.detect` returns on a value is not a byte substring of the value.

### T7: Relax the entropy bar for a value whose name hints at a connection string          [risk: high]

**Depends on:** T2, T6
**Files:** `lib/lain/sensitivity/entropy.rb`, `lib/lain/sensitivity/literals.rb`, `spec/lain/sensitivity/entropy_spec.rb`,
`spec/lain/sensitivity/literals_spec.rb`, `spec/fixtures/sensitivity/hinted_corpus.yml` (new)
**Reuse:** `Entropy.shannon` and `Entropy.predictable?` (T2); the spike corpus
(`~/tmp/lain/spike-evidence-2026-10-18/pass-mask/corpus.rb`, all synthetic values), copied into the fixture
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#printed`, through `Literals` (T5, T6)

For a passed name matching `HINTED`, `Literals` also lists each token of the value that `Entropy.hinted?` accepts:

- **Scan:** tokens matching `[A-Za-z0-9+/_-]{16,}={0,2}`, so `sig=<token>` yields the token and not the key.
- **Skip:** a token containing `/`, and a `predictable?` one.
- **Measure** on the token without its trailing `=` padding, and **list** it with the padding.
- **Accept** a token of at least 16 chars with at least 3.5 bits per char that holds a lowercase letter, an uppercase letter
  and a digit; or a token matching `/\A[0-9a-f]{16,}\z/i` that holds at least 1 letter, with at least 3.0 bits.

The thresholds are constants in `Entropy`, each with the spike's measured reason.

**Acceptance criteria**

```gherkin
Scenario: A short random token in a hinted value is masked
  Given env pass names REDIS_URL set to "redis://cache.local:6379/0?sig=Qm9vT2s3x9ZpL1aB"
  When Literals lists its strings
  Then "Qm9vT2s3x9ZpL1aB" is listed

Scenario: A UUID in a hinted value is not masked
  Given env pass names SERVICE_URL set to "https://svc.local/items?id=7d9f2c1e-3b4a-4c5d-8e6f-0a1b2c3d4e5f"
  When Literals lists its strings
  Then nothing from SERVICE_URL is listed

Scenario: A long number is not masked
  Given env pass names DATABASE_URL set to "postgres://db.local/app?ts=12345678901234567"
  When Literals lists its strings
  Then nothing from DATABASE_URL is listed

Scenario: The relaxed bar stays off a plain name
  Given env pass names BUILD_TAG set to "Qm9vT2s3x9ZpL1aB"
  When Literals lists its strings
  Then nothing from BUILD_TAG is listed

Scenario: The spike's corpus keeps its measured score
  Given the 65 labelled values in the hinted corpus fixture, each under a hinted name
  When Literals lists their strings
  Then 28 secrets have a listed string, and among the harmless values only the 2 hex digests do
```
Spec files: `spec/lain/sensitivity/entropy_spec.rb`, `spec/lain/sensitivity/literals_spec.rb`

**Interface**

```ruby
module Lain::Sensitivity::Entropy
  def self.hinted?(token)          # the relaxed bar measured for hinted names
end

class Lain::Sensitivity::Literals
  HINTED = /(?:_URL|_URI|_DSN)\z|DATABASE|CONN/i
end
```

**Stop and report if:**
- The corpus scenario cannot reach 28 and 2 with the stated rule; report the table rather than tuning past the spike.
- A dashed UUID, a semantic version or a pure-digit token passes `Entropy.hinted?` (a 32-hex UUID with no dashes passes, and
  `Regions` flags it too).

### T8: Journal each bash mask          [risk: medium]

**Depends on:** T6
**Files:** `lib/lain/telemetry/command_redacted.rb` (new), `lib/lain/middleware/redact_secret_reads.rb`,
`spec/lain/telemetry/command_redacted_spec.rb` (new), `spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `Telemetry::ReadRedacted`'s shape and the middleware's `record` path (`redact_secret_reads.rb:444-460`)
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#printed`, which writes the record to the journal `ToolGuard#read_kwargs` passes

A bash mask writes nothing today, unlike a `read_file` mask. One `command_redacted` record per masked bash result gives the
`tool_use_id` and the number of masked spans. It never holds bytes.

**Acceptance criteria**

```gherkin
Scenario: A masked bash result is journalled with its count
  Given a bash result printing an AWS key id and a passed DSN's password alone
  When the bash masker masks it
  Then the journal holds 1 command_redacted record for that tool_use_id, counting 2 regions

Scenario: An unmasked result writes nothing
  Given a bash result with nothing to mask
  When the bash masker passes it through
  Then the journal holds no command_redacted record

Scenario: The record carries no secret bytes
  Given the masked result above
  When the record is serialized
  Then neither secret appears in the JSON
```
Spec files: `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/telemetry/command_redacted_spec.rb`

**Interface**

```ruby
Lain::Telemetry::CommandRedacted = Data.define(:tool_use_id, :regions)   # regions: Integer
```

**Stop and report if:**
- A session reader or `Compare` enumerates record types in a closed list that would refuse the new one (grep `ReadRedacted`
  outside `lib/lain/telemetry/`).

### T9: Inspect the docker image for its ID on each call          [risk: high]

**Depends on:** none
**Files:** `lib/lain/exec/docker.rb`, `lib/lain/exec/docker/image.rb` (new), `spec/lain/exec/docker_spec.rb`,
`spec/lain/exec/docker/image_spec.rb` (new)
**Reuse:** `Docker`'s inner `exec` and its timeout handling (`docker.rb:88-98`, `:150-160`)
**Shared-file wiring:** none
**Reachable from:** `Exec::Docker#initialize`, built by `ExecBackend#docker` (`exec_backend.rb:121`), holds an `Image` over
its tag and its inner exec; `Docker#call` names `image.reference(timeout)` in the argv

`Image#pin` runs `docker image inspect` for the tag with a budget of `INSPECT_BUDGET` seconds (capped by the asking
deadline) and returns a `Pin` of the ID, the image's `Config.Env` and its `Config.Entrypoint`, or nil. It pulls nothing and
memoizes nothing, so a rebuilt tag takes effect on the next call. An ID that is not 64 hex chars (after stripping a `sha256:`
prefix) is nil. `Docker#call` runs the pinned ID when there is one and the tag otherwise, so a missing image is still pulled by
`docker run` as today. Nothing spawns at construction: `ExecBackend` must still build a backend without a subprocess.

**Acceptance criteria**

```gherkin
Scenario: The run names the inspected ID
  Given a fake docker client whose inspect prints an ID for alpine:latest
  When Docker runs "true"
  Then the docker run argv names that ID in place of alpine:latest

Scenario: A rebuilt tag takes effect on the next call
  Given a fake client whose inspect prints ID A, then ID B
  When Docker runs 2 commands
  Then the first argv names A and the second names B

Scenario: A missing image runs by tag and pulls nothing
  Given a fake client whose inspect exits 125
  When Docker runs "true"
  Then the argv names alpine:latest and the client saw no pull

Scenario: A malformed ID is not trusted
  Given a fake client whose inspect prints "not-an-id"
  When Docker runs "true"
  Then the argv names alpine:latest

Scenario: Building a backend spawns nothing
  Given a fake client that records every invocation
  When ExecBackend builds a docker backend
  Then the client recorded no invocation
```
Spec files: `spec/lain/exec/docker/image_spec.rb`, `spec/lain/exec/docker_spec.rb`

**Interface**

```ruby
class Lain::Exec::Docker::Image
  INSPECT_BUDGET = 5
  Pin = Data.define(:id, :env, :entrypoint)   # id: 64 hex; env: Hash; entrypoint: Array<String>
  def initialize(tag:, exec:)
  def pin(timeout)                             # Pin or nil, never memoized; not #inspect, which Object owns
  def reference(timeout)                       # pin(timeout)&.id || tag
  attr_reader :tag
end
```

**Stop and report if:**
- An inspect costs more than 0.1s on this machine. A call inspects 4 to 5 times (ComposedTerm's `decide` and `why_not`,
  `Facts::Resolving`, the bash tool's `journal_resolution`, the run), measured at 0.04s each, which is accepted; a memo that
  outlives the call would bring back the frozen tag.
- A spec pins the argv to name the tag after a successful inspect.

### T10: Answer the filesystem port from an image listing          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/shell/executable/listed_stat.rb` (new), `lib/lain/shell/executable/realpath_walk.rb` (new),
`spec/lain/shell/executable/listed_stat_spec.rb` (new)
**Reuse:** `Shell::Executable::Stat`'s 8 methods as the contract (`stat.rb`); `Resolver::Bound::MAX_LINKS` for the loop limit
**Shared-file wiring:** none
**Reachable from:** deferred: T13 constructs it at `Exec::Docker::Resolver#for`. The card is pure, and T13 is in this plan.

`ListedStat` answers every `Stat` method from a Hash of path to entry. An entry is a type (`file`, `directory`, `symlink`,
`hardlink`), a mode, a uid, a gid and a link target. Each method answers as `File` would for that entry:

- `lstat`, `readlink` and `realpath` raise `Errno::ENOENT` for a missing path; `realpath` raises `Errno::ELOOP` past
  `MAX_LINKS`.
- `executable?` and `directory?` follow symlinks and answer false for a missing path. A `hardlink` counts as a file with its
  own mode.
- `writable?` is false for every path: no call can change an image file for a later one.

`RealpathWalk` resolves a path 1 component at a time through `lstat` and `readlink`, so T11 can switch filesystems between hops.

**Acceptance criteria**

```gherkin
Scenario: A link chain resolves through the listing
  Given a listing where /usr/bin/awk links to /etc/alternatives/awk, which links to /usr/bin/mawk, a file
  When realpath("/usr/bin/awk") is asked
  Then it is "/usr/bin/mawk"

Scenario: A directory symlink resolves
  Given a listing where /bin links to usr/bin and /usr/bin/ls is a file
  When realpath("/bin/ls") is asked
  Then it is "/usr/bin/ls"

Scenario: A missing PATH directory does not stop the search
  Given a listing with no /usr/local/sbin
  Then executable?("/usr/local/sbin/ls") and directory?("/usr/local/sbin") are false
  And lstat("/usr/local/sbin") raises Errno::ENOENT

Scenario: executable? follows a symlink and honours the mode
  Given /bin/ls links to /bin/busybox, mode 0755, and /etc/motd is a file with mode 0644
  Then executable?("/bin/ls") is true and executable?("/etc/motd") is false

Scenario: A hard link is a file
  Given /usr/bin/perl5.38.2 is a hardlink entry with mode 0755
  Then executable?("/usr/bin/perl5.38.2") is true

Scenario: Nothing in the image is writable
  Given /usr/bin is a directory with mode 0777
  Then writable?("/usr/bin") is false

Scenario: A loop stops at the kernel's limit
  Given /a links to /b and /b links to /a
  When realpath("/a") is asked
  Then Errno::ELOOP is raised
```
Spec file: `spec/lain/shell/executable/listed_stat_spec.rb`

**Interface**

```ruby
class Lain::Shell::Executable::ListedStat
  Entry = Data.define(:type, :mode, :uid, :gid, :link) do
    def symlink? = type == "symlink"
  end
  def initialize(entries)          # {path => Entry}
  # lstat readlink realpath real children directory? executable? writable?
end

module Lain::Shell::Executable::RealpathWalk   # needs #lstat and #readlink
  def realpath(path)
end
```

**Stop and report if:**
- `Bound`, `RunFiles` or `Fresh` calls a method on `lstat`'s result other than `symlink?` and `ctime` (grep `lstat(` under
  `lib/lain/shell/`).

### T11: Route a mounted path to the host filesystem          [risk: low]

**Depends on:** T10
**Files:** `lib/lain/shell/executable/mounted_stat.rb` (new), `lib/lain/shell/executable/mounted_fresh.rb` (new),
`spec/lain/shell/executable/mounted_stat_spec.rb` (new), `spec/lain/shell/executable/mounted_fresh_spec.rb` (new)
**Reuse:** `RealpathWalk` (T10); `Stat` for the host side
**Shared-file wiring:** none
**Reachable from:** deferred: T13 constructs both at `Exec::Docker::Resolver#for`. The card is pure, and T13 is in this plan.

`MountedStat` answers each `Stat` method from the host for a path under 1 of its mounts, and from the image listing otherwise.
Its `realpath` walks hop by hop, so a project symlink to `/usr/bin/ruby` lands on the image's `/usr/bin/ruby`, which is what
the container would run. `MountedFresh` answers the session's freshness for a mounted path and `false` for an image path,
since every command starts a fresh container.

**Acceptance criteria**

```gherkin
Scenario: A mounted path reads the host
  Given a mount at the project root and a host file bin/tool under it
  When executable?("<root>/bin/tool") is asked
  Then the host's answer is given

Scenario: A link out of the mount lands in the image
  Given <root>/bin/ruby on the host links to /usr/bin/ruby, a file only the listing has
  When realpath("<root>/bin/ruby") is asked
  Then it is "/usr/bin/ruby"

Scenario: An image path is never fresh
  Given a session freshness that answers true for every path
  When MountedFresh is asked about /usr/bin/ls and about <root>/bin/tool
  Then it answers false and true
```
Spec files: `spec/lain/shell/executable/mounted_stat_spec.rb`, `spec/lain/shell/executable/mounted_fresh_spec.rb`

**Interface**

```ruby
class Lain::Shell::Executable::MountedStat
  include RealpathWalk
  def initialize(mounts:, image:, host: Stat.new)
end

class Lain::Shell::Executable::MountedFresh
  def initialize(mounts:, host:)   # host: #fresh?
  def fresh?(path)
end
```

**Stop and report if:**
- "Under a mount" cannot be decided lexically. The mounts are realpaths (`ExecBackend` resolves the root), so a lexical test
  should hold.

### T12: Fetch and cache an image's listing once per ID          [risk: high]

**Depends on:** T9, T10
**Files:** `lib/lain/exec/docker/image.rb`, `lib/lain/exec/docker/export.rb` (new), `lib/lain/paths.rb`,
`spec/lain/exec/docker/image_spec.rb`, `spec/lain/exec/docker/export_spec.rb` (new), `spec/lain/paths_spec.rb`
**Reuse:** the spike prototype (`~/tmp/lain/spike-evidence-2026-10-18/image-facts/image_facts.rb`): `docker create`,
`docker export`, `docker rm`, `Gem::Package::TarReader`; `AtomicFile.write`; `Image#pin` (T9); `ListedStat::Entry` (T10);
`Docker`'s cleanup pattern (`docker.rb:375-420`)
**Shared-file wiring:** none
**Reachable from:** `Exec::Docker::Image#listing(pin, paths:)`, called by `Exec::Docker::Resolver#for` (T13), which passes
`ExecBackend#paths` (T1)

`Image#listing(pin, paths:)` returns the image's entries, keeping every `PATH` directory's children (`PATH` from the pin's env, else
`/bin:/usr/bin`), every hop of every link chain they start, and every ancestor directory of those paths. The steps:

1. Read `Paths#exec_image_listing(pin.id)`. A malformed file counts as a miss.
2. On a miss, `docker create <id> true` (a dummy command, so an image with no `CMD` still creates), then
   `docker export -o <tmpfile> <cid>` with a budget of `LISTING_BUDGET` seconds, then `docker rm`. The export goes to a file
   under `TMPDIR`, so the existing `Exec::Local` deadline and kill apply and nothing streams through a pipe. The container and
   the file are removed on every path, interrupts included. The file is as large as the image, so a multi-GB image needs that
   much free space in `TMPDIR` for the moment it exists.
3. `Export.read(io)` reads every entry's metadata and skips file bodies. `Export.keep(entries, path:)` then filters with a pure
   function, because a link's target can come earlier in the tar than the link.
4. Write the cache with `AtomicFile.write`.

A timeout or an unreadable tar is cached on disk as a failure with its reason, since it would recur for that ID. A client or
daemon error is memoized only in the process. A fiber-aware `Mutex` around the fetch makes parallel subagents export once.

**Acceptance criteria**

```gherkin
Scenario: A listing is exported once and then read from cache
  Given a fake client whose export writes a small alpine-shaped tar built in the spec
  When 2 Image objects for the same ID ask for the listing
  Then the client saw 1 export and both listings are equal

Scenario: Parallel askers export once
  Given 3 fibers asking 1 Image for the same ID's listing at once
  Then the client saw 1 export

Scenario: The cache key is the image ID
  Given a cached listing for ID A
  When a pin for ID B asks for its listing
  Then it exports, and the file for A is untouched

Scenario: Link chains and ancestors are kept wherever they sit in the tar
  Given a tar where /usr/bin/mawk comes before /usr/bin/awk, which links through /etc/alternatives/awk, and /bin links to usr/bin
  When the listing is built
  Then it holds /bin, /usr/bin/awk, /etc/alternatives/awk, /usr/bin/mawk, /usr and /

Scenario: A slow export is cached as a failure
  Given a fake client whose export sleeps past the budget
  When the listing is asked for, and then asked for again by a new Image
  Then both answers are nil, the client saw 1 export, and the created container was removed

Scenario: A daemon error is retried in a new process
  Given a fake client whose export exits nonzero once
  When the listing is asked for, and then asked for again by a new Image
  Then the second Image exports again
```
Spec files: `spec/lain/exec/docker/image_spec.rb`, `spec/lain/exec/docker/export_spec.rb`, `spec/lain/paths_spec.rb`

**Interface**

```ruby
class Lain::Exec::Docker::Image
  LISTING_BUDGET = 60
  def listing(pin, paths:)          # {path => ListedStat::Entry} or nil; paths: where the cache lives
end

module Lain::Exec::Docker::Export
  def self.read(io)                 # tar -> {path => Entry}, metadata only
  def self.keep(entries, path:)     # the PATH children, their link hops and every ancestor
end

class Lain::Paths
  def exec_image_listing(id)        # cache_home/exec-images/v1/<id>.json, creating the directory
end
```

**Stop and report if:**
- `Gem::Package::TarReader` cannot be loaded without loading all of rubygems at boot; then require it inside the method with
  a `$LOADED_FEATURES` spec, per the repo `CLAUDE.md`'s Requires rule.
- A fiber-aware `Mutex` deadlocks under the reactor `Tools::Subagent` fans siblings out on; report rather than dropping it.
- The cache location cannot stay a `listing` argument without `Image` holding state about it; `Image.new` and
  `ExecBackend` stay untouched here, because T1 and T13 own `exec_backend.rb`.

### T13: Resolve container programs from the image listing          [risk: high]

**Depends on:** T1, T11, T12
**Files:** `lib/lain/exec/docker/resolver.rb` (new), `lib/lain/exec/docker.rb`, `lib/lain/cli/exec_backend.rb`,
`lib/lain/telemetry/exec_image.rb` (new), `spec/lain/exec/docker/resolver_spec.rb` (new),
`spec/lain/cli/exec_backend_spec.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/telemetry/exec_image_spec.rb` (new), `spec/lain/exec/docker_spec.rb`
**Reuse:** `Shell::Executable::Resolver.new(root:, fresh:, stat:, host_env:)` unchanged; `MountedStat` and `MountedFresh`
(T11); `ListedStat` (T10); `Image#pin` and `#listing` (T9, T12); `Docker#mount_points` and `#crossing`, made public;
`Resolver::CONTAINER` as the fallback; `ExecBackend#journal`, `#paths` and `#notice` (T1)
**Shared-file wiring:** none
**Reachable from:** `ExecBackend#resolver(fresh:)` returns `Exec::Docker::Resolver.new(docker:, root:, fresh:, journal:, paths:, notice:)` for
docker; `Wiring#exec_resolver` (T1) memoizes it for the bash tool, the ladder and the judge

`Docker::Resolver#for(worker_env)` inspects the image (`INSPECT_BUDGET`) and reads its listing (`LISTING_BUDGET`). On success
it builds a `Resolver` over the project root with `MountedStat` (the mounts for the worker's cwd, the image's `ListedStat`) and
`MountedFresh`, with `host_env` set to the image's env, and binds it to the worker with only the variables that cross into the
container. It answers `Resolver::CONTAINER.for(worker_env)`, so every stage stays unresolved with `container_backend` as
today, when the inspect fails, the listing fails, or the image declares an `ENTRYPOINT` (the argv would go to it, and the
listing cannot say what it runs). It journals 1 `exec_image` record per image ID per run: the tag, the ID, and whether the
listing was read, or why not. A failed listing writes 1 notice per image ID per run through `ExecBackend#notice`: container
programs could not be listed (the reason), so every docker bash call goes to the judge or to the human; for a cached failure it
names the cache file to delete to retry. `Observers` is not the seam, because its notices are read once at startup
(`wiring.rb:294`) and the listing fails later.

**Acceptance criteria**

```gherkin
Scenario: A judge approval of an image program goes through
  Given a fake docker client serving a small alpine-shaped listing, exec docker and judge-facts facts, with confine off
  And a judge that approves
  When the model asks bash to run "uname -a", which ComposedTerm's allowlist does not name
  Then the stage resolves to a path in the listing, class system, with no anomaly
  And the ruling comes from the judge rung and the call runs without parking

Scenario: ComposedTerm approves an allowlisted image program under confine classes
  Given the same launch with confine classes
  When the model asks bash to run "cat README.md"
  Then ComposedTerm approves it in the rules rung
  And the example at wiring_spec near :598, which expected it left to the rest of the ladder, now expects this

Scenario: A project script resolves on the host
  Given the same launch and an executable bin/check under the project root
  When "bin/check" is resolved
  Then the Executable has class project and the facts line names <root>/bin/check

Scenario: An image with an entrypoint keeps today's behavior
  Given a fake client whose inspect reports ENTRYPOINT ["/usr/local/bin/actionlint"]
  When "ls" is resolved
  Then the stage is unresolved with the container_backend anomaly
  And the exec_image record says why

Scenario: A listing failure keeps today's behavior and tells the human
  Given a fake client whose export fails
  When "ls" is resolved
  Then the stage is unresolved with the container_backend anomaly
  And the notice seam received 1 notice naming the failure

Scenario: The worker's PATH does not steer the search
  Given a worker env that lends PATH=/evil
  When "ls" is resolved
  Then the search uses the image's PATH

Scenario: Podman resolves image programs as system too
  Given a client that reports itself as podman
  When "ls" is resolved
  Then its class is system and it is not fresh
```
Spec files: `spec/lain/exec/docker/resolver_spec.rb`, `spec/lain/cli/wiring_spec.rb` (the docker examples near `:594-624`
change), `spec/lain/cli/exec_backend_spec.rb`, `spec/lain/telemetry/exec_image_spec.rb`

**Interface**

```ruby
class Lain::Exec::Docker::Resolver
  def initialize(docker:, root:, fresh:, journal:, paths:, notice:)
  def for(worker_env)              # Shell::Executable::Resolver::Bound, or CONTAINER's
end

class Lain::Exec::Docker
  attr_reader :image               # the Image, which answers #tag
  def mount_points(cwd)            # public now
  def crossing(env)                # public now
end

Lain::Telemetry::ExecImage = Data.define(:image, :id, :listed, :reason)
```

**Stop and report if:**
- `spec/lain/shell/executable/resolver_spec.rb:499-511` or `spec/lain/approval/judged_spec.rb` needs a change; they pin
  generic unresolved behavior, which stays.
- `WorkerEnv#with(env:)` does not exist or `WorkerEnv` is not a `Data` (`worker_env.rb:34`).
- `Docker#image` is read as a String anywhere (grep `.image` on a Docker instance, specs included); keep a `#tag` reader for
  those rather than breaking them.
- `Facts::Resolving` (`judge/facts.rb:105-115`) reaches the resolver through a path other than `Wiring#exec_resolver`.

### T14: Document container resolution          [risk: low]

**Depends on:** T13
**Files:** `ARCHITECTURE.md`, `planning/qa/scenarios/bash-confinement.md`, `planning/qa/scenarios/subagents-and-backends.md`,
`lib/lain/shell/executable/resolver.rb` (the `CONTAINER` comment only)
**Reuse:** `ARCHITECTURE.md` § Bounding a bash call, item 1 (`:904-916`) and the docker sentence at `:934`;
`bash-confinement.md:261-263`; `subagents-and-backends.md:3`, `:417-420`
**Shared-file wiring:** none
**Reachable from:** deferred: documentation, no construction site

ARCHITECTURE gains 1 paragraph: the inspect per call, the export and its cache, the mount routing, why image paths are
`system` and never fresh, and the 3 fallbacks (inspect, listing, entrypoint). Both scenario files replace "every docker stage is
unresolved" with what a QA pass should now see, including each fallback. The `CONTAINER` comment says it is the fallback and no
longer the docker answer.

**Acceptance criteria**

```gherkin
Scenario: The docs state what the code does
  Given the 4 edited files
  When a reader follows the docker sections of both scenario files
  Then every claim matches a T13 criterion, and bin/comment-census --check-tickets passes on resolver.rb
```
Spec file: `spec/lain/comment_census_spec.rb` (unchanged, must stay green)

**Stop and report if:**
- Either scenario file has other docker claims that T13 made false beyond the lines named.

### T15: Document passed-value masking          [risk: low]

**Depends on:** T7, T8, T14
**Files:** `ARCHITECTURE.md`, `planning/qa/scenarios/secret-boundary.md`, `lib/lain/config/builder.rb` (the `Builder#env`
comment only)
**Reuse:** `ARCHITECTURE.md` § The secret boundary (`:963`); the `Builder#env` comment (`builder.rb:165-173`); the
`secret-boundary.md` table near `:576`
**Shared-file wiring:** none
**Reachable from:** deferred: documentation, no construction site

The `Builder#env` comment stops saying a passed value is masked only when the detector recognises it, and states the 2 rules.
The secret-boundary scenario gains checks a QA pass can run: a passed DSN's password printed alone, a hinted token, a
non-hinted name left alone, and the `command_redacted` record. ARCHITECTURE's secret boundary names `Sensitivity::Literals` as
the place a literal is chosen.

**Acceptance criteria**

```gherkin
Scenario: The docs state what the code does
  Given the 3 edited files
  When a reader follows the secret-boundary passed-value checks
  Then every claim matches a T6, T7 or T8 criterion
```
Spec file: `spec/lain/comment_census_spec.rb` (unchanged, must stay green)

**Stop and report if:**
- `spec/docs_config_examples_spec.rb` parses the `Builder#env` comment's example.

## Integration checks

After the last card lands:

- `bundle exec rake pspec` 3 times: same example count each run, 0 failures. Check the count against the last close-out
  (25,198 at `edf27b5f`) plus this plan's new examples.
- `bundle exec rubocop`, `bin/comment-census --check-tickets --check-load-order`, `bin/zeitwerk-census --check`,
  `bin/spec-census --check` (ceilings unchanged or lower), `bin/runtime-census --record` then `--check`.
- `grep -rn resolver_for lib spec exe` returns nothing.
- `ls ~/.cache/lain/exec-images` shows nothing written by the suite.
- Manual pass the human owes, with real docker and podman if both are at hand:
  1. `lain chat --exec docker --exec-image alpine:latest --judge-facts facts`, then ask the agent to run `uname -a`: the
     judge approves it and no human prompt appears. The session file has 1 `exec_image` record with the ID, and
     `exec_resolution` names a listed path with class `system`.
  2. Put an executable `bin/hello` in the project and run it: the facts line says `project`.
  3. Run `docker build -t lain-probe .` from a 2-line Dockerfile (`FROM alpine`, `RUN touch /x`), chat with
     `--exec-image lain-probe`, rebuild with a change while the chat runs, and ask for 1 more command: a second `exec_image`
     record names the new ID.
  4. `--exec-image rhysd/actionlint:latest`: every stage is unresolved, and the `exec_image` record names the entrypoint.
  5. Make a listing fail (an `--exec-image` whose export the client refuses, or `LISTING_BUDGET` lowered in a scratch build):
     the chat shows the notice, naming the cache file to delete.
  6. Delete `~/.cache/lain/exec-images/` and run `--exec-image ubuntu:24.04`: the first call takes about 0.6s longer, and a
     second chat does not export again.
  7. With `env pass: %w[DATABASE_URL]` and `DATABASE_URL=postgres://app:<16 random chars>@db/x`, ask the agent to run
     `printenv DATABASE_URL | cut -d: -f3 | cut -d@ -f1`: the output is a placeholder, and the session file has a
     `command_redacted` record.
  8. Re-drive the docker sections of the bash-confinement and subagents-and-backends scenarios, and the passed-value checks
     in secret-boundary, as T14 and T15 left them.

## Execution log

- 2026-10-18 start. Base `main` at `0535a9f0`. `git worktree list`: `/home/tara/dev/lain 0535a9f0 [main]` only. Branches
  before the run: `flake/review`, `main`, `spike/combined`, `spike/combined2`.
- Hook (`.pre-commit-config.yaml`): file hygiene hooks, shellcheck, cargo fmt/clippy/test (Rust files only), `bundle exec rake
  compile check` (rubocop whole repo plus `rake pspec`, on any Ruby or Rust file), `bundle exec yard-lint --staged`,
  `bin/lint-gherkin-docs` (staged plan docs), `bin/lint-commit-msg`, `bin/lint-price-freshness`. A Ruby commit takes about
  70s and runs the full suite, so it must run alone on the box. Agent-runnable checks: `bundle exec rubocop <paths>`,
  `bundle exec yard-lint <paths>`, `bundle exec rspec <spec paths>`. No paths need user approval.
