# Simplify 06 — one config parse, one path authority, one refusal per input source

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Three cross-cutting duplications, each of which the code already complains about in its own comments.
`.lain/config.toml` is parsed **seven times** per `lain chat` startup, and the one method that would
share the parse is `private_class_method`, so `Project::Resolver` reimplements it byte-for-byte.
`ProjectDir` exists to own path composition and its own docstring lists five names it does not own —
sixteen sites compose their own. And seven config-table readers each invented the same refusal family,
31 error classes for one concept, with `NotATable` written seven times.

This plan lands one resolved config value, one path authority with its guard extended to match, and one
`Config::Refusal` — then deletes the pure-taxonomy error classes the new rule makes redundant.

Delivers: one `Tomlrb.load_file` per process; `ProjectDir` owning all sixteen `.lain/` and state-path
compositions with the Ripper guard extended to enforce it; one gem-asset path owner; one `SILENT`;
31 refusal classes collapsed to one; and roughly 134 never-rescued error classes removed with their
reasons moved to their raise sites.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**Seven parses of one file per startup.** Each of these does its own `path_for` + `File.exist?` +
`Tomlrb.load_file` on the same `<root>/.lain/config.toml`:

| # | call | reader |
|---|---|---|
| 1 | `Config.shell_exclusions` | `cli/wiring/board_build.rb:133` |
| 2 | `Config.test_layout` | `board_build.rb:155` |
| 3 | `Config.sensitivity` | `board_build.rb:226` |
| 4 | `Config.load` | `project/consent.rb:213` |
| 5 | `Config.load` | `cli/wiring/handback.rb:67` |
| 6 | `Config.load` | `cli/epic_mount.rb:105` |
| 7 | `Tomlrb.load_file` | `project/resolver.rb:337` — **before all six** |

`Config.load` has eleven call sites in total, eight of which are keyword *defaults* in an
`initialize`/factory signature. `Config.sensitivity` has three (`survey.rb:137`,
`command/survey.rb:273`, `board_build.rb:226`); `shell_exclusions` one; `test_layout` five.

**The design reason for the three-way split is sound and must survive.** `config.rb:94-121` argues
that `.load` **tolerates** a typo in a GRANTING table while `.sensitivity`/`.shell_exclusions`/
`.test_layout` refuse loudly because those tables **restrict**. That is a posture difference, not a
parse difference — one parse, three interpreters.

**`Config.read` is private, so the resolver duplicates it verbatim.** `config.rb:186` is
`path_for`, `:190-196` is `read`, and `:198` is `private_class_method :path_for, :read`. So
`project/resolver.rb:336-340`:

    def declared_root(path)
      Tomlrb.load_file(path)["root"]
    rescue Tomlrb::ParseError, ArgumentError, SystemCallError => e
      raise Config::Malformed.new(path, e)
    end

is `Config.read`'s body, its three-class rescue and its `Malformed` rename, copied. A fourth TOML
error class added to `Config.read` would not reach the resolver. And `resolver.rb:162-164`'s comment
calls itself *"The ONE spelling of a project's config file"* while being one of three.

**The degrade logic is copied three times.** `rescue Config::Malformed → notice → fall back` at
`board_build.rb:132-137` (`NO_EXCLUSIONS`, degrades to a permissive `Shell::Verdict`), `:154-159`
(`IGNORED_LAYOUT`, degrades to `TestLayout::None`), `:225-230` (`UNREADABLE`, degrades to
`Rules.empty`). All three call `(notice || SILENT).call(...)`, with `SILENT` at `:32`.

**`SILENT = ->(_message) {}` is defined seven times**, byte-identically:
`project/consent.rb:70`, `frontend/reline.rb:66`, `frontend/prompt_composer.rb:62`,
`frontend/neovim/compose.rb:83`, `frontend/neovim/question_view.rb:97`, `cli/epic_mount.rb:39`,
`cli/wiring/board_build.rb:32`. `consent.rb:69` even names its sibling: *"matching
{CLI::EpicMount::SILENT}"*.

**`ProjectDir` is 17 code lines and confesses its gap.** `project_dir.rb:46-53`:

> `{#state_path}` is the ONE resolver for the state feed, and `spec/lain/project_dir_spec.rb` parses
> every file in `lib/` and fails on any expression that composes the path again, in any spelling.
> **This class does not yet own every `.lain/` name** (`config.toml`, `SLOTS_DIR`, `USER_DIR`,
> `prompt.toml` and `epics` each still compose their own), and it stands on both sides of the line it
> draws.

Members: `DIR = ".lain"` `:66`, `STATE_FILE` `:69`, `STATE_KIND` `:75`, `self.join` `:80`,
`#dir` `:95`, `#state_path` `:97`, private `#state_dir` `:101`.

**Three sites use it; eleven compose their own.** Using it: `summarizer.rb:35`,
`isolation/services.rb:19`, `project/resolver.rb:168`. Open-coded: `config.rb:186`,
`approval/remembered.rb:76` (`WHERE = ".lain/config.toml"` — a **third** spelling, as a string) and
`:186`, `prompt/slots.rb:20` + `:49`, `skill/catalog.rb:29-30` + `:39`,
`frontend/prompt_composer.rb:169`, `epic/home.rb:67`, `cli/command/meta.rb:46`, `:63`.
So `config.toml` is composed **three** independent ways and `epics`/`slots`/`skills`/`prompt.toml`/
`meta`/`summarizers` each once.

**The `<state_home>/<kind>/<key>` recipe appears in eight places outside `ProjectDir`**:
`paths.rb:230`, `epic/home.rb:66`, `cli/isolation_backend.rb:95`,
`workspace/snapshot/scope/shadow_git/repository.rb:46`, `cli/worktrees.rb:92` (flattened into a
**filename**, not a segment), `cli/gc_schedule.rb:84` + `:86` (**split across two methods**),
`isolation/worktree.rb:164`, and **`project/consent.rb:165`, which uses a full 64-char
`Digest::SHA256.hexdigest(root)` where every sibling uses the 12-char `project_hash`.** That one is
commented as intentional at `:113`, so it is a deliberate exception — findable only by reading all
eight.

**Eleven `__dir__`-relative shipped-asset paths have no owner**, at three different depths:
`core/child.rb:23` (`../../../target/debug/lain-core` — pinning the Cargo profile),
`paths.rb:166` (`NVIM_PLUGIN_ROOT`, whose comment says it is *"located the same way
{Core::Child::BINARY} is"*), `prompt/slots.rb:26`, `frontend/neovim/runtime_loader.rb:34` and `:37`,
`frontend/prompt_composer.rb:154`, `structural/queries.rb:88` (the only per-call one),
`bench/sweep.rb:53` and `:54`, `skill/catalog.rb:25`. `Paths::NVIM_PLUGIN_ROOT` is the accidental
precedent — one already lives in `Paths`, so the seam is half-cut.

**The Ripper guard is a data change, not a code change.** `spec/lain/project_dir_spec.rb` is 593 lines.
Its anchors: `STATE_NAME = "state.json"` `:37` (**the anchor**), `PROJECT_NAME = ".lain"` `:38`,
`CWD_READERS` `:39`, `KIND_NAME = "status"` `:48`, `XDG_READERS = %w[state_home project_hash]` `:53`,
`CONSTANTS = {DIR, STATE_FILE, STATE_KIND}` `:57`, `BINDABLE` `:62`, `EXEMPT` `:66`,
`COMPOSITIONS` `:73`. The rule is `#violation` `:184-189`:
`return [] unless names.include?(STATE_NAME) && names.length > 1` — *an expression naming the file
together with any other ingredient of its location has rebuilt the path.* The ingredient dispatch is
`#named_here` `:200-204`. **It watches one file: the status feed.** `config.toml`, `slots`, `skills`,
`epics`, `meta`, `summarizers`, `prompt.toml` and `services.rb` are all unwatched.

Extending it means adding names to `:37/:38/:48/:53/:57` and a `KIND_NAMES` list — plus one
`named_here` entry only if a new *kind* of ingredient appears, not for a new literal.

**Five raw `$HOME` reads bypass the sanctioned one.** All `ENV.fetch("HOME", nil)`:
`isolation/null.rb:27`, `cli/worktrees.rb:36`, `cli/isolation_backend.rb:124`,
`cli/gc_schedule.rb:57` (bare `rubocop:disable`, **no reason**), `project/resolver.rb:387`
(**no rubocop comment at all**). The sanctioned reader is `paths.rb:194-196`, which reads the
**injected** `@env` and raises `NonAbsoluteHome` (`paths.rb:49`) on a non-absolute value, with a
12-line comment on why degrading is wrong. Only the resolver's downstream (`Resolver::Home`,
`:176-181`) refuses a bad value by name; the other four pass it on unexamined.

**`$HOME` is never *inferred* as a root — verified true.** It becomes one only via an explicit
`--root` (rung 1, `kind: :home`) or rung `:none` (`resolver.rb:429`, which returns the **cwd**, a fact
rather than an inference). Sharp edge, documented and pinned by `resolver_spec.rb:219-221`, `:234`:
`$HOME` is in `Refusals` (`resolver.rb:224`), so `Walk` cuts ancestry **at** `$HOME` and a
`~/.lain/config.toml` declaring a `root` is **never honoured**. Also: **ARCHITECTURE.md has no section
on `Project` root resolution at all** — the 191-code-line resolver's only account is CLAUDE.md's one
line plus the file's own prose.

**405 error classes, 332 of them bodiless.** By superclass as written: `Error` 320, `Lain::Error` 40,
a family-local `Refusal` 25, `StandardError` 10, `DeclarationError` 3, `::Lain::Error` 2, plus
singletons inheriting `KeyError`, `HTTP::Error`, `Timeout` and `IntervalPartition::NotAPartition`.
Bodiless: **332 of 405, 82%**.

**The seven config-table refusal families — 31 classes, 235 code lines, for one concept:**

| family | base? | classes | entry |
|---|---|---|---|
| `config/answers.rb` | **yes** `:51-59` | `NotATable` 64, `UnknownKeys` 76, `NotAList` 88, `MalformedEntry` 103 | `.from` `:116-122`, `.check!` `:134-141` |
| `config/epics.rb` | **NO** | `NotATable` 31, `UnknownKeys` 44, `InvalidHome` 60 | `.from` `:76-84`; **no `check!`** |
| `config/gates.rb` | **yes** `:27-35` | `NotATable` 40, `UnknownStages` 52, `UnknownPolicies` 65 | `.from` `:78-82`, `.check!` `:98-111` |
| `config/isolation.rb` | **NO** | `NotATable` 43, `UnknownKeys` 55, `InvalidValue` 68 | `.from` `:91-101`, `.check!` `:106-110` |
| `shell/exclusions.rb` | **yes** `:48-56` | `NotATable` 59, `UnknownKeys` 70, `NotAList` 80, `MalformedPattern` 92 | `.from` `:104-112`, `.check!` `:139-144` |
| `test_layout/refusals.rb` | **yes** `:8-15` | `NotATable` 18, `UnknownKeys` 30, `MissingPreset` 41, `InvalidValue` 46, `AmbiguousDefaultLevel` 64 | `test_layout.rb` `.from` `:94-102`, `.shaped!` `:113-118` |
| `sensitivity.rb` (`Rules`) | **yes** `:193-201` | `NotATable` 204, `UnknownKeys` 215, `NotAList` 225, `MalformedPattern` 239 | `.from` `:252-260`, `.check!` `:290-295` |

**`NotATable` appears seven times, `UnknownKeys` six.** Every `.from` has the identical three-line
skeleton (nil → `{}`; not a Hash → `NotATable`; `keys - KEYS` → `UnknownKeys`).
**The two lacking a base** re-declare `attr_reader :path` on every class and re-derive the
`path ? "#{path}: " : ""` prefix — `epics.rb:66` inline, `isolation.rb:86` hoisted into `self.located`.
**Only one of the 31 is ever rescued in production** — `TestLayout::Refusal`, at
`board_build.rb:156`, and only to degrade.

**Five prose comments cross-reference each other's "posture", forming a cycle:**
`config/answers.rb:50` → `{Epics::Gates::Refusal}`; `sensitivity.rb:191-192` →
`{Config::Answers::Refusal}`; `shell/exclusions.rb:45-47` → `{Sensitivity::Rules::Refusal}`;
`config/gates.rb:64` → `{Epics::InvalidHome}`. Three hops describing one shape nobody extracted.

**`declare raising:` is the mechanism, and it is under-used.** `declarative.rb:91-100` threads one
refusal class through a whole validation block; the default is `ArgumentError` (`:115`). **Six live
sites pass a custom class** — `tool.rb:242`, `approval/rule.rb:92`, `epic/intake.rb:104`, `:163`,
`epic/stage.rb:56`, `epic/intake/delta.rb:86` — plus a docstring example at `declarative.rb:18`. So
the DSL generates ~6 of the 405, not hundreds: **there is no DSL-level lever, but `declare raising:`
is the right mechanism for the consolidation.**

**`Tool::ContractViolation` must survive.** `tool.rb:28`, raised at `contracts.rb:188`, with **29
`raise_error` assertions across 7 spec files** and a special case in `effect/handler/live.rb:78-80`.
Note it has **zero named rescues in `lib/`** — it is caught only by the generic `StandardError` arm at
`live.rb:69` — so a naive "never rescued, therefore delete" rule would take it. That is why the rule
below counts spec assertions too.

**Where docs and code disagreed.** `ARCHITECTURE.md:498`'s `Filter.new` claim is simplify-02's T1
scope and is not restated here. `project/resolver.rb:162-164`'s "The ONE spelling" comment and
`project_dir.rb:46-53`'s confession are both corrected by this plan's cards. ARCHITECTURE.md's missing
`Project` section is noted and left — writing it is not a simplification.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- T1 adds `lib/lain/config/resolved.rb` and T3 adds a gem-asset owner; both need a manifest line in
  `lib/lain.rb`, and **T1's must come before `project/resolver.rb`'s entry** because the resolver will
  call `Config.read`. A load-time `NameError` means the entry is too early or too late.
- **T2 must land its moves and its guard extension in ONE commit.** The extended guard fails on all
  sixteen current sites, so a guard-first commit is red on arrival and a moves-first commit leaves the
  guard unable to see what it now owns.
- This plan assumes **simplify-01 has landed** for T1 and T5, both of which produce a class larger than
  the current `Metrics/ClassLength` permits.
- **simplify-02's T1 edits `board_build.rb`'s `rules` method, which T1 here also touches.** Sequence
  02 before this plan, or T1's Escalation trigger fires.

## Open decisions

- **How far T6 goes.** The grounding puts 157 classes in the "never rescued, never asserted" bucket,
  of which ~20 are deliberate abstract bases or `declare raising:` targets, leaving ~134. That count is
  a ceiling derived from a reference sweep that could not attribute 176 bare tokens; the card works
  file-by-file and reports its actual total rather than promising 134.
- **Whether the `path ? "#{path}: " : ""` prefix belongs on `Config::Refusal` or on the reader.** T5
  puts it on the refusal, following the five families that already have a base. If the panel prefers it
  at the raise site, T5's diff changes and nothing else does.

## Waves

Wave 1: T3, T5
Wave 2: T4 (←T3), T6, T7 (←T3)
Wave 3: T1 (←T4)
Wave 4: T2 (←T1, T3)
Critical path: T3 → T4 → T1 → T2

**The waves here are narrow because four card pairs write the same file, and each pair is serialized
rather than coordinated**: T3 and T4 both edit `frontend/prompt_composer.rb`; T3 and T7 both edit
`paths.rb`; T4 and T5 both edit `cli/wiring/board_build.rb`; T1 and T2 both edit `config.rb` *and*
`project/consent.rb`. T4 precedes T1 on merit too — `Config::Resolved` will own one degrade path and
wants the single `SILENT` to hand to it — and T3 precedes T2 so the gem-asset paths leave `lib/` before
the Ripper guard's anchor set grows, or the guard flags eleven sites T3 is about to move anyway.

## Tasks

### T1 — Parse the config once per process   [wave 3] [risk: medium]

**Depends on:** T4
**Files:** create `lib/lain/config/resolved.rb`, `spec/lain/config/resolved_spec.rb`; modify
`lib/lain/config.rb`, `lib/lain/cli/wiring/board_build.rb`, `lib/lain/cli/wiring/handback.rb`,
`lib/lain/cli/epic_mount.rb`, `lib/lain/project/consent.rb`, `lib/lain/project/resolver.rb`
**Reuse:** the six table classes already exist and stay — `Config::Epics`, `Config::Answers`,
`Config::Isolation`, `Sensitivity::Rules`, `Shell::Exclusions`, `TestLayout`.
`config.rb:190-196`'s `read` is the one parse; `board_build.rb:71-86`'s hoisting comment is the
argument, applied one level up.
**Shared-file wiring:** `require_relative "config/resolved"` in `lib/lain.rb`, positioned so it loads
after `config` and before `project` (the resolver will call `Config.read`)
**Reachable from:** `CLI::Wiring` builds the board from `CLI::ChatLaunch#constructed`
(`chat_launch.rb:134`); AC 1 counts parses across a full chat launch, driven through `ChatLaunch`

One value object, built once from one `Tomlrb.load_file`, holding the six existing table objects, with
the degrade applied **once** at construction. `Config.load`/`.sensitivity`/`.shell_exclusions`/
`.test_layout` become readers on it.

Un-privatize `Config.read` and `Config.path_for` (`config.rb:198`) so
`Project::Resolver::Declarations#declared_root` (`:336-340`) can stop reimplementing them.

**Keep the three-way posture split.** `config.rb:94-121` argues that `.load` tolerates a typo in a
granting table while the three restricting readers refuse loudly. One parse, three interpreters — the
postures live on the readers, not on the parse.

The line delta here is near zero. **That is the point**: this is a correctness-per-line change, and it
is where simplify-02's classifier threading naturally lands.

**Acceptance criteria**

```gherkin
Scenario: one chat launch parses the config file once
  Given a project with a config file
  When a chat is launched
  Then the file was read once

Scenario: a granting table tolerates an unknown key
  Given a config whose approval table holds an unknown key
  When the config is resolved
  Then it resolves
  And a notice names the unknown key

Scenario: a restricting table refuses loudly
  Given a config whose sensitivity table is not a table
  When the config is resolved
  Then it refuses, naming the file

Scenario: the resolver reads a declared root through the shared parse
  Given a config declaring a root
  When the project is resolved
  Then that root is used
  And the file was read once
```
→ spec files: `spec/lain/config/resolved_spec.rb` (AC 2, AC 3), `spec/lain/cli/chat_launch_spec.rb`
(AC 1), `spec/lain/project/resolver_spec.rb` (AC 4)

**Escalation triggers**
- **`project/resolver.rb:337` parses *before* the six others**, during root resolution — so a
  process-lifetime memo keyed on root cannot be warm yet when the resolver needs it. If the honest
  shape is "the resolver's parse seeds the memo", say so; if it is "two parses, not seven", say that
  instead. Do not claim one parse if the resolver still makes its own.
- Eight of `Config.load`'s eleven callers are **keyword defaults** evaluated at call time.
  `epic_mount.rb:65` carries a comment about default-argument evaluation preceding a rescue. If
  replacing a default with an injected value changes *when* a refusal fires, stop.
- simplify-02's T1 rewrites `board_build.rb`'s `rules` method. If that plan has not landed, this card
  will collide with it — sequence after, or coordinate the same edit once.
- `Config::EMPTY` (`config.rb:240-241`) is a frozen instance and `private_constant`. If `Resolved`
  needs an empty counterpart, it needs one too — and a *mutable* resolved config would break the
  "session-fixed snapshot" property `DslCatalog` establishes elsewhere.

### T2 — Make `ProjectDir` the only thing that knows where `.lain/` is   [wave 4] [risk: medium]

**Depends on:** T1, T3
**Files:** modify `lib/lain/project_dir.rb`, `spec/lain/project_dir_spec.rb`; modify
`lib/lain/config.rb`, `lib/lain/approval/remembered.rb`, `lib/lain/prompt/slots.rb`,
`lib/lain/skill/catalog.rb`, `lib/lain/frontend/prompt_composer.rb`, `lib/lain/epic/home.rb`,
`lib/lain/cli/command/meta.rb`, `lib/lain/paths.rb`, `lib/lain/cli/isolation_backend.rb`,
`lib/lain/workspace/snapshot/scope/shadow_git/repository.rb`, `lib/lain/cli/worktrees.rb`,
`lib/lain/cli/gc_schedule.rb`, `lib/lain/project/consent.rb`, `lib/lain/isolation/worktree.rb`
**Reuse:** `ProjectDir.join` (`:80`) already exists for exactly this and has three users;
`spec/lain/project_dir_spec.rb`'s `Scanner` (`:80-260`) already walks the AST correctly and ignores
prose — **extending it is a data change at `:37/:38/:48/:53/:57`**, not new machinery
**Shared-file wiring:** none
**Reachable from:** `ProjectDir#state_path` is read by `StatusFeed#default_path`
(`status_feed.rb:513`) on the live chat path; AC 4 is the guard itself, which runs in the suite

Two moves and one guard extension:

1. Every `.lain/` name becomes a named reader on `ProjectDir` — `#config`, `#epics`, `#slots`,
   `#skills`, `#prompt`, `#meta`, `#summarizers`, `#services`. Eleven open-coded sites become calls,
   including the **three redundant spellings** (`config.rb:186`, `remembered.rb:76`'s string constant,
   `remembered.rb:186`) and `command/meta.rb`'s two.
2. The `<state_home>/<kind>/<key>` recipe becomes one method. Eight sites call it, and
   **`consent.rb:165`'s full 64-char digest becomes an explicit argument** so the deliberate exception
   is visible at the call rather than discoverable by reading all eight.
3. The Ripper guard's anchor set grows to cover the eight names and the four kind segments (`epics`,
   `worktrees`, `workspace`, `gc`).

`project_dir.rb:46-53`'s confession becomes a statement. `resolver.rb:162-164`'s "The ONE spelling"
comment becomes true.

**Acceptance criteria**

```gherkin
Scenario: every .lain name resolves through one authority
  Given a project root
  When the config, epics, slots, skills, prompt, meta, summarizers and services paths are asked for
  Then each is under that root's .lain directory

Scenario: a state container is composed one way
  Given a project root and a kind
  When its state container is asked for
  Then it is under the state home, named by kind, keyed by the project hash

Scenario: the consent store's full digest is asked for explicitly
  Given a project root
  When the consent container is asked for
  Then its key is the full digest
  And the call names that choice

Scenario: recomposing a governed path is refused
  Given a library file composing a .lain name together with a root
  When the path discipline check runs
  Then that file is reported
```
→ spec file: `spec/lain/project_dir_spec.rb` (AC 1-4; AC 4 is the guard itself)

**Escalation triggers**
- **The moves and the guard extension must be ONE commit.** The extended guard fails on all sixteen
  current sites; a guard-first commit is red on arrival, and a moves-first commit leaves the guard
  blind to what it now owns.
- `spec/lain/project_dir_spec.rb:106-136` documents what the scanner **cannot** see. If any of the
  sixteen sites composes its path in a shape the scanner misses, moving it is still right but the
  guard will not hold it — say which sites are guarded and which are merely moved.
- `project_dir.rb:88-91`'s `#initialize` takes `paths:` **defaulted**, with a YARD note explaining why.
  `spec/lain/project/root_defaults_spec.rb` (544 lines) allowlists cwd-reading defaults; if growing
  `ProjectDir` adds one, that spec fires.
- `worktrees.rb:92` flattens the key into a **filename** (`worktrees-<hash>.<kind>`) and
  `gc_schedule.rb` splits it across two methods (`:84`, `:86`). Neither is the `<kind>/<key>` shape. If
  one recipe cannot serve both without a second parameter, report it — forcing them into one shape
  would be the special-casing this plan exists to remove.
- `isolation/worktree.rb:164` hashes a **worker id**, not a root, under an injected root. That is a
  different composition wearing the same helper; do not fold it in without saying so.

### T3 — One owner for the eleven shipped-asset paths   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/paths/shipped.rb` (or extend `Paths` — the card chooses and says why),
`spec/lain/paths/shipped_spec.rb`; modify `lib/lain/core/child.rb`, `lib/lain/paths.rb`,
`lib/lain/prompt/slots.rb`, `lib/lain/frontend/neovim/runtime_loader.rb`,
`lib/lain/frontend/prompt_composer.rb`, `lib/lain/structural/queries.rb`,
`lib/lain/bench/sweep.rb`, `lib/lain/skill/catalog.rb`
**Reuse:** `Paths::NVIM_PLUGIN_ROOT` (`paths.rb:166`) is the accidental precedent — one of the eleven
already lives in `Paths`, and its comment says `Core::Child::BINARY` is *"located the same way"*
**Shared-file wiring:** `require_relative "paths/shipped"` in `lib/lain.rb` if a new file
**Reachable from:** `Core::Child::BINARY` is read when the daemon spawns; `RuntimeLoader::MODULES` is
read when the editor runtime is injected; `Structural::Queries` is read by four tier-1 tools. AC 2
drives the runtime loader, AC 3 the query lookup.

Eleven `__dir__`-relative paths at **three different depths** (`../`, `../..`, `../../..`) plus two
zero-depth, with no shared notion of the gem root. `core/child.rb:23` is the worst: it pins both the
repo layout **and** the Cargo profile (`target/debug`).

Note simplify-01's T6 also touches `core/child.rb:23` — to make it consult `CARGO_TARGET_DIR`. **If 01
has landed, build on that change rather than reverting it**; if not, this card's owner should
accommodate the environment variable so 01's T6 becomes a one-line addition.

**Acceptance criteria**

```gherkin
Scenario: every shipped asset resolves from one root
  When each shipped asset path is asked for
  Then each is under the gem's own directory

Scenario: the editor runtime modules are found
  When the runtime loader reads its modules
  Then it finds them

Scenario: a structural query file is found for a supported language
  Given a supported language and a query name
  When its query file is asked for
  Then the file exists

Scenario: the daemon binary path honours a configured target directory
  Given a target directory named in the environment
  When the daemon binary path is asked for
  Then it resolves inside that directory
```
→ spec files: `spec/lain/paths/shipped_spec.rb` (AC 1, AC 4),
`spec/lain/frontend/neovim/runtime_loader_spec.rb` (AC 2),
`spec/lain/structural/queries_spec.rb` (AC 3)

**Escalation triggers**
- `structural/queries.rb:88` is the only one computed **per call** (`File.join(__dir__, "queries", ...)`)
  rather than as a constant. If folding it into a constant-based owner means eager-loading a directory
  listing at boot, stop — a tier-1 tool's lookup should stay lazy.
- The gem is installed as a gem, not only run from a checkout. If any of the eleven resolves
  differently under an installed gem than under a checkout, the owner must too — and `bench/sweep.rb`'s
  corpus paths are the likeliest divergence, since `spec/fixtures` is not shipped.
- `paths.rb:166`'s `NVIM_PLUGIN_ROOT` points at `plugin/nvim`, which is **outside `lib/`**. Confirm the
  gemspec ships it before assuming a `lib/`-relative root reaches it.

### T4 — One `SILENT`   [wave 2] [risk: low]

**Depends on:** T3
**Files:** modify `lib/lain.rb` (a constant on the `Lain` module) or create
`lib/lain/silent.rb`; modify `lib/lain/project/consent.rb`, `lib/lain/frontend/reline.rb`,
`lib/lain/frontend/prompt_composer.rb`, `lib/lain/frontend/neovim/compose.rb`,
`lib/lain/frontend/neovim/question_view.rb`, `lib/lain/cli/epic_mount.rb`,
`lib/lain/cli/wiring/board_build.rb`
**Reuse:** `Sink::Null` and `Channel::Null.instance` are the existing Null-Object precedents in this
codebase; the card should say why a lambda is right here rather than a Null object, or use one
**Shared-file wiring:** a manifest line in `lib/lain.rb` if a new file, placed before the first user
**Reachable from:** each of the seven sites is a `notice:` keyword default on a production
constructor; AC 2 drives a board build with no notice supplied

Seven byte-identical `-> (_message) {}` definitions, one of which (`consent.rb:69`) names its sibling
in a comment. One definition, seven references.

**Acceptance criteria**

```gherkin
Scenario: a notice with no listener is discarded
  Given a component constructed with no notice
  When it emits a notice
  Then nothing is raised

Scenario: a board built with no notice still degrades on a bad config
  Given a malformed config and no notice
  When the board is built
  Then it degrades to the built-in rules

Scenario: a supplied notice receives the message
  Given a component constructed with a notice collector
  When it emits a notice
  Then the collector holds that message
```
→ spec file: `spec/lain/cli/wiring/board_build_spec.rb` (AC 2), plus one of the frontend specs for
AC 1 and AC 3

**Escalation triggers**
- A shared frozen lambda is process-global mutable-adjacent state. If any of the seven sites
  **compares** its notice against `SILENT` by identity to decide behaviour, sharing one instance
  changes that comparison's meaning — grep for `== SILENT` and `equal?(SILENT)` first.
- `board_build.rb:32`'s `SILENT` is used in three `(notice || SILENT).call(...)` expressions. T1 folds
  one degrade path; if T1 has landed, two of the three call sites may already be gone.

### T5 — One `Config::Refusal` for seven config-table families   [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/config/refusal.rb`, `spec/lain/config/refusal_spec.rb`; modify
`lib/lain/config/answers.rb`, `config/epics.rb`, `config/gates.rb`, `config/isolation.rb`,
`lib/lain/shell/exclusions.rb`, `lib/lain/test_layout/refusals.rb`, `lib/lain/test_layout.rb`,
`lib/lain/sensitivity.rb`, `lib/lain/cli/wiring/board_build.rb`; modify the seven families' spec files
**Reuse:** **`Declarative#declare raising:`** (`declarative.rb:91-100`) already threads one refusal
class through a whole validation block — this is the mechanism, and it is under-used at six live sites.
The five families that already have a `Refusal` base establish the `path ? "#{path}: " : ""` prefix.
**Shared-file wiring:** `require_relative "config/refusal"` in `lib/lain/config.rb`'s require block,
before the four `config/*` tables
**Reachable from:** every one of the seven readers is called during a chat launch (see T1's table);
AC 1 and AC 2 drive refusals through `CLI::Wiring::BoardBuild`

**31 classes in 235 code lines for one concept.** `NotATable` seven times, `UnknownKeys` six. Every
`.from` shares the same three-line skeleton. **Only one of the 31 is rescued in production.**

One `Config::Refusal` carrying `path`, `table`, `key` and a detail, raised through
`declare raising: Config::Refusal` in each of the seven readers. This also **gives the two families
that lack a base one** — so `board_build.rb:156` can name one class instead of
`Lain::TestLayout::Refusal, Config::Malformed`.

The five prose cross-references (`answers.rb:50`, `sensitivity.rb:191-192`, `exclusions.rb:45-47`,
`gates.rb:64`) collapse into one docstring on `Config::Refusal`. That is the point: the codebase
documented its own duplication three times rather than extracting it.

**Acceptance criteria**

```gherkin
Scenario: a table that is not a table is refused, naming the file and the table
  Given a config whose sensitivity entry is a string
  When the config is read
  Then it refuses
  And the message names the file and the sensitivity table

Scenario: an unknown key is refused, naming the key and the keys that exist
  Given a config whose shell table holds an unknown key
  When the config is read
  Then it refuses
  And the message names the unknown key and the permitted keys

Scenario: a refusal built by hand carries no path
  Given a table built in memory rather than loaded
  When it is refused
  Then the message names no file

Scenario: one rescue catches every config table's refusal
  Given a malformed epics table and a malformed isolation table
  When each is read inside a rescue of the one refusal class
  Then both are caught
```
→ spec file: `spec/lain/config/refusal_spec.rb` (AC 3, AC 4), plus the seven families' own specs for
AC 1 and AC 2

**Escalation triggers**
- **The two postures must survive.** `config.rb:94-121` argues granting tables tolerate and restricting
  tables refuse. One refusal *class* is fine; one refusal *policy* is not. If collapsing the classes
  tempts collapsing the postures, stop.
- `board_build.rb:156` rescues `Lain::TestLayout::Refusal, Config::Malformed` as a **pair**.
  `Config::Malformed` is the parse failure and stays distinct from a table-shape refusal — do not merge
  those two, or a TOML syntax error and a wrong key become one message.
- **The 31 classes appear in spec assertions.** Each family's spec asserts `raise_error(Foo::NotAList, /…/)`.
  Rewriting those to name `Config::Refusal` while keeping the message matcher is correct — but if any
  spec asserts on the **class alone** with no message, that assertion becomes vacuous. Report the count.
- `test_layout/refusals.rb`'s `AmbiguousDefaultLevel` (`:64`) has no counterpart in the other six. If it
  carries a field the shared refusal does not, it is not the same concept — keep it and say so.

### T6 — Delete the error classes nothing discriminates on   [wave 2] [risk: medium]

**Depends on:** T5
**Files:** modify roughly 40 files across `lib/`, each deleting one to six bodiless error classes and
moving its reason to the raise site; modify the corresponding spec files
**Reuse:** the surviving classes and `Lain::Error` itself; `declare raising:` for anything that needs a
per-declaration refusal
**Shared-file wiring:** none
**Reachable from:** every deletion is verified by the suite still distinguishing the failures callers
actually discriminate on; AC 1 drives a real refusal through `exe/lain`'s renderer

**The rule, stated so an author can apply it:**

> A failure mode earns its own class only when some caller `rescue`s it **by name** to do something
> different from what it does with its sibling.

Three corollaries:

1. **A message is not a class.** If the only thing distinguishing two failures is the sentence, they
   are one class with two messages. `raise_error(Klass, /sentence/)` in a spec is evidence *against* a
   separate class — it proves the spec was reading the sentence.
2. **One `Refusal` per input source, not one per way of being wrong.** T5 is this corollary applied.
3. **Exactly one root: `Lain::Error`, written bare.** No `StandardError` (simplify-02's T6 handles the
   seven), and no `::Lain::Error` unless a real shadow exists at that site — neither current use has
   one (`isolation/worker_id.rb:37`, `declarative/types.rb:58`).

A reviewer applies it with one grep: if `rescue <Name>`, `<Name> ===` and `is_a?(<Name>)` are all
absent from `lib/` and `exe/`, **and** no spec asserts on the class alone, the class is not carrying
its weight.

**`Tool::ContractViolation` is the test case for the rule's second clause.** It has **zero named
rescues in `lib/`** — caught only by the generic `StandardError` arm at `effect/handler/live.rb:69` —
so the first clause alone would delete it. But it has **29 `raise_error` assertions across 7 spec
files** and `live.rb:78-80` special-cases it in a comment. It stays. Any rule that takes it is wrong.

**Move every reason, never delete one.** Most of these classes carry a 2-4 line comment explaining the
failure. CLAUDE.md's standing rule is that the reason survives in words even when the citation does
not — so the prose moves to the raise site rather than going with the class.

**Acceptance criteria**

```gherkin
Scenario: a refusal still reaches the user as a message
  Given a command that fails on a malformed config
  When it is run through the CLI
  Then the failure is reported as a message naming the file

Scenario: a caller that discriminates still can
  Given a store missing an object
  When a timeline walk reaches it
  Then the missing-object failure is caught by name

Scenario: every surviving error class has a discriminating caller or a spec assertion
  When the project's error classes are enumerated
  Then each is either rescued by name or asserted by name in a spec

Scenario: a contract violation is still distinguishable
  Given a tool whose precondition is violated
  When it is called
  Then a contract violation is raised
  And it is caught by name
```
→ spec file: `spec/lain/error_taxonomy_spec.rb` (AC 3 — extending the file simplify-02's T6 creates,
or creating it if 02 has not landed), plus existing specs for AC 1, 2, 4

**Escalation triggers**
- **176 bare tokens could not be attributed** by the grounding's reference sweep (mostly stdlib and
  third-party: `Array`, `String`, `Async::TimeoutError`, `VCR::Errors::*`). Those unattributed
  references can only *undercount* usage, so the 157 figure is a **ceiling**. Work file-by-file and
  report the actual total; do not delete to hit a number.
- A class reached **only via `declare raising:`** shows as "never raised by name" to a scan. Six live
  sites pass a custom class (`tool.rb:242`, `approval/rule.rb:92`, `epic/intake.rb:104`, `:163`,
  `epic/stage.rb:56`, `epic/intake/delta.rb:86`). Those are false positives — check each before
  deleting.
- Some of the 405 are `Refusal` bases with **real bodies** (the path-prefix constructor) in
  `config/answers.rb:51`, `config/gates.rb:27`, `sensitivity.rb:193`, `shell/exclusions.rb:48`,
  `test_layout/refusals.rb:8`. T5 collapses those; do not double-delete.
- The singletons inheriting something other than `Error` — `frontend/theme.rb:44` (`KeyError`),
  `exec.rb:73` (`Timeout`), `cli/prompt_breaker.rb:25` (`Interrupt`),
  `compaction/strategy/composed.rb:43` (`IntervalPartition::NotAPartition`) — each inherit for a
  **behavioural** reason (a `KeyError` is rescued by `Hash#fetch` idiom; an `Interrupt` is not caught
  by `rescue StandardError`). Leave all four and say why.

### T7 — One reader for `$HOME`   [wave 2] [risk: low]

**Depends on:** T3
**Files:** modify `lib/lain/paths.rb`, `lib/lain/isolation/null.rb`, `lib/lain/cli/worktrees.rb`,
`lib/lain/cli/isolation_backend.rb`, `lib/lain/cli/gc_schedule.rb`,
`lib/lain/project/resolver.rb`; modify `spec/lain/paths_spec.rb`
**Reuse:** `Paths#home` (`paths.rb:194-196`) is the sanctioned reader — it reads the **injected**
`@env` and raises `NonAbsoluteHome` (`paths.rb:49`) rather than degrading, with a 12-line comment on
why
**Shared-file wiring:** none
**Reachable from:** `Paths#home` is reached from `ProjectDir#state_dir` and from every XDG path;
AC 3 drives a command that needs `$HOME` with it unset

Add a non-raising `Paths#home_or_nil` for the four sites that legitimately want a nil, and route all
five raw `ENV.fetch("HOME", nil)` reads through `Paths`. That retires five `rubocop:disable Style/EnvHome`
comments and five copies of the same justification — one of which (`gc_schedule.rb:57`) has **no
reason at all** and one (`resolver.rb:387`) has **no disable comment at all**.

**Acceptance criteria**

```gherkin
Scenario: a non-absolute home is refused by name
  Given an environment whose home is a relative path
  When the home is read
  Then it is refused, naming the value

Scenario: a site that tolerates no home gets nil
  Given an environment with no home set
  When the tolerant reader is used
  Then it answers nothing
  And nothing is raised

Scenario: a command needing a home reports clearly when it is absent
  Given an environment with no home set
  When the worktrees command runs
  Then it reports that no home is available

Scenario: the environment is injected, not read from the process
  Given a paths object constructed with an explicit environment
  When its home is read
  Then it comes from that environment
```
→ spec file: `spec/lain/paths_spec.rb`

**Escalation triggers**
- `resolver.rb:387` is `new(home: ENV.fetch("HOME", nil)).call.project` — a **class-level default** on
  `Resolver.default_project`. Routing it through `Paths` means constructing a `Paths` there; if that
  creates a circular load between `paths` and `project`, stop and report the cycle rather than
  reordering `lib/lain.rb`.
- Four of the five sites currently pass the raw value **onward unexamined**, so today a bad `$HOME`
  fails later and elsewhere. Routing them through the sanctioned reader makes them fail **earlier and
  by name**, which is better but is a behaviour change — say so, and check no spec asserts the late
  failure.
- `paths.rb:194-196` reads `@env["HOME"]` then `Dir.home`, and its docstring records why `Dir.home`
  also goes through `#present`. A `home_or_nil` must keep both arms or it is a different reader.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. T5 and T6 rewrite a large number
  of `raise_error` assertions in place and T6 deletes some — write the arithmetic out.
- `bundle exec rubocop` clean, and **five fewer `Style/EnvHome` disables** than before T7. If the count
  did not drop, the reads were not routed.
- `bundle exec rspec spec/lain/project_dir_spec.rb` — T2's guard extension is the card's deliverable
  and this is where it lives.
- `bundle exec rspec spec/lain/project/root_defaults_spec.rb` — T1, T2 and T3 each touch a constructor
  that could acquire a cwd-reading default, and this 544-line Ripper spec is the guard.
- `bundle exec rspec spec/lain/config spec/lain/sensitivity spec/lain/shell spec/lain/test_layout` as a
  focused config-table run for T5.
- **Measure the parse count.** T1's AC 1 is a counting assertion; run it and record the before and
  after numbers in the commit message. "One parse" is the plan's headline claim and it should be a
  measurement, not an aspiration.
- **Manual, human:** `lain chat` in a project with a deliberately malformed `.lain/config.toml`, then
  the same with a valid one. T1 and T5 both change what a broken config says, and the degrade postures
  (`board_build.rb`'s three notices) are user-facing prose no spec reads aloud.
- **Manual, human:** one `lain worktrees gc` run with `$HOME` unset, for T7's AC 3. That path reaches
  the filesystem and a wrong answer deletes directories.
- Update `planning/qa/scenarios/` for any changed refusal sentence — T5 rewrites 31 classes' worth of
  messages, and several are the first thing a user sees on a typo.
