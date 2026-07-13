# Spec — Prompt Slots

> Status: `[exp]`, specced. Attaches to the M3c `Context` combinator band (3c-2). Companion to
> `ROADMAP.md` (M3c fold-in) and `remaining-work.md` (the committed 3c-2 units it builds on).
> Unit IDs `PS-<n>` mirror the acceptance-criteria style of `remaining-work.md`.

## What it is

Named **holes** in Lain's base prompt that the user fills with **markdown partials** — the mental
model is a **Rails view partial**, not a scripting language. A slot fill is "inject this markdown
doc here." The purpose is **durable, rarely-changed, freeform adjustment of the system prompt** — the
user's high-level guidance that gets the agent into *their* perspective quickly and then mostly sits
still.

This is distinct from mechanisms other agents already have (AGENTS.md / `.mdc` files / reusable
prompts via skills & commands). Those inject *task* context. Prompt slots are for **freeform
system-prompt-level behavior**, including **per-role behavior** — how the `test-engineer` or the
`orchestrator` behaves at a high level (ties to the M5 agent role catalog).

**Design consequence of "changed rarely":** because fills are durable, a system slot can live *in the
cached prefix* safely — it is not volatile content that busts the cache each turn. Rare mutation is
what makes the expensive (above-the-cache-line) placement acceptable.

## Model

- **Base templates render named partials.** Lain ships base ERB prompt templates with `render :slot`
  holes and a shipped default per slot. The user overrides a slot by placing a markdown file at
  `.lain/slots/<slot-name>.md` in the project (the `.lain/` convention, like `.git/`). Missing file →
  the shipped default.
- **Rendered in a purity-enforcing locked binding.** ERB is the mechanism (so a partial *can*
  interpolate a whitelisted local), but the binding exposes **only pure, content-addressed locals** —
  `Time.now`, IO, and network are not in scope, so an impure reference fails **loudly** (`NameError`),
  never silently non-deterministic. `Context#render` stays pure: same inputs → identical bytes.
- **Content-addressed + journaled.** Each slot file's digest is recorded per turn and the rendered
  prompt is content-addressed, so a run records exactly which slot versions produced it — replayable,
  diffable, and (later) a swept axis.

## Audience & location

A **lain user** feature: `.lain/slots/` lives in the *user's* project and personalizes *their* agent.
When the **lain dev** dogfoods (develops Lain with Lain), the slots live in this repo's `.lain/slots/`
and shape Lain's own agent — same mechanism, different project.

## Slot regions (scope decided: system-level only, not tool/workspace/per-turn)

| Slot | File | Renders into |
|---|---|---|
| `system` | `.lain/slots/system.md` | the system prompt — freeform high-level adjustment |
| role behaviors | `.lain/slots/role/<name>.md` | a named subagent role's system block (M5 role catalog) |
| compaction extension | `.lain/slots/compaction.md` | steers/extends the `Compact` combinator's summary guidance (3c-2.3) |

Tool-description framing, the workspace tail, and per-turn/recall regions are **out of scope** for the
first cut (user chose system-level only).

## Transparency (CLI now, Neovim later)

A plain-text render of the *whole* prompt with slot boundaries and cache breakpoints annotated, shown
as a diff against the base template — now, in M3c. The richer annotated `lain://request` buffer comes
with the Neovim frontend (M4, unit 4-2.3).

## Units

- **PS-1 — `Prompt::Slots` combinator.** Loads `.lain/slots/*.md`, renders each into its named hole in
  the base ERB templates via a locked pure binding; missing file → shipped default. *Builds on:*
  3c-2.1 (combinator base), `lib/lain/context.rb` (pure `#render`). **Acceptance:** a `system.md`
  override appears verbatim in the rendered system prompt; a missing slot yields the default; a slot
  referencing an out-of-scope local (`Time.now`) raises `NameError` at render, not a silent value;
  identical inputs render byte-identical output.
- **PS-2 — Content-addressing + journaling of slots.** Record each used slot's digest per turn; the
  rendered prompt is content-addressed. *Builds on:* `lib/lain/journal.rb`, `Canonical`.
  **Acceptance:** the Journal records the slot digests for a turn; dry-replay (3c-5.1) reproduces the
  byte-identical prompt from the recorded slot snapshot — recall/render is pure.
- **PS-3 — Role slots.** `.lain/slots/role/<name>.md` renders into the matching subagent role's system
  block. *Needs:* M5 role catalog / `Tool::Subagent` (5-1). **Acceptance:** a `role/test-engineer.md`
  adjusts only the test-engineer subagent's prompt; sibling roles are unaffected.
- **PS-4 — Compaction-extension slot.** The `Compact` combinator (3c-2.3) exposes a user slot that
  extends/steers its summarization guidance. *Needs:* 3c-2.3. **Acceptance:** the compaction summary
  prompt includes the user's extension when `.lain/slots/compaction.md` exists; base behavior when it
  does not; purity held. *(Coordinate with `planning/specs/cache-aware-compaction.md`.)*
- **PS-5 — CLI transparency view.** `lain --show-prompt` (and a REPL command) renders the whole prompt
  with slot boundaries and cache breakpoints annotated, diffed against the base template. *Builds on:*
  3c-2.4 (`CacheBreakpoints`, to know the cache line). **Acceptance:** output labels each slot region,
  marks which sit above/below the cache line, and the diff shows only overridden slots.
- **PS-6 — Neovim-annotated transparency `[M4]`.** The same view in `lain://request`. *Cross-ref:*
  4-2.3. **Acceptance:** deferred to M4.

## Swept axis (deferred)

Slot fills are content-addressed, so different fills are arms `Compare` can diff and guard. Because
fills change rarely, the sweep is "does this persona/role adjustment help," not a per-turn search. The
GEPA optimizer over slot contents is **parked** (see `first-class-concepts.md`), so no automated search
in this cut.

## Dependencies

3c-2.1 (combinator base) · 3c-2.4 (`CacheBreakpoints`, for PS-5's cache line) · 3c-2.3 (`Compact`, for
PS-4) · M5 5-1 (subagents, for PS-3) · M4 4-2.3 (for PS-6).

## Open questions

- **User-level defaults?** Project `.lain/slots/` only, or also `~/.lain/slots/` with project
  overriding user? (Onboarding writes the persona — where?)
- **Are role slots and the compaction slot "slots," or their own mechanisms** that happen to reuse the
  partial-render machinery? Leaning: one machinery, three namespaced locations.
- **Onboarding hand-off:** the M1b/Interface onboarding interview writes the persona into
  `.lain/slots/system.md` (or a dedicated `persona.md` partial the base `system` template renders).
