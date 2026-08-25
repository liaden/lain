# Scenario: the project extension API — slots, roles, and the cache floor

**What it exercises:** `Prompt::Slots`' three-level override surface — `.lain/slots/system.md`
(top-level, one hole), `.lain/slots/role/<name>.md` (one per built-in role, hyphen-mapped), and
`.lain/slots/skill/<skill>/<hole>.md` (per-skill, many holes) — its `UnknownSlot` refusals
(`slots.rb:103` top-level filename, `slots.rb:114` role-namespace filename, `slots.rb:164`
role-render-time), and the 4096-token minimum-cacheable-prefix floor
(`CacheProfile::ANTHROPIC.min_prefix_tokens`) the shipped default sits well under.

**The question it answers:** does a project's own `.lain/slots/` tree actually reach the model —
does an override land verbatim, does a typo'd filename refuse loudly and **by name** at every
level rather than being silently ignored, and does the shipped default actually miss Anthropic's
cache the way the code comments predict, or only look like it should?

**Cost:** cheap. §1–§5 are zero-model-turn paths — launch-level refusals (like
`session-and-window.md` §1) and `/ruby` inspection (no provider round trip). **§6 is the one paid
step**: two real completions against a live Anthropic key, spending real quota, because "eligible
for the cache" and "cached" are two different claims and only the wire's own `usage` block can
settle which one holds for a shipped default this short. If this round has no Anthropic budget,
skip §6 and say so plainly in the findings — do not let the free half stand in for it.

**Needs:** a throwaway project directory you write `.lain/slots/` fixtures into. No nvim required,
tmux not required for §1–§5. §6 needs `ANTHROPIC_API_KEY` exported and spends real quota.

---

## 0 — the three levels, and the one rule that holds at all of them

None of the three levels silently ignores a typo — every one of them raises
`Lain::Prompt::UnknownSlot`, naming the file and the known set, rather than treating an unrecognized
filename as extra data nobody reads. This scenario drives the first two directly (§1–§4); the
skill level's own render-time refusal is unit-spec covered (`Prompt::SkillSlots#source`,
`slots_spec.rb`'s `#render_skill` describe block) and is not one of the three line numbers this
scenario was written to cover, so it is not driven here.

## 1 — a top-level override lands verbatim, and is journaled once

```bash
mkdir -p .lain/slots
echo 'PROJECT GUIDANCE 42: prefer terse commit messages.' > .lain/slots/system.md
lain chat --root "$(pwd)" --provider ollama --model qwen3-coder:30b < /dev/null
```

Confirm two things, neither needing a model call:

- The journal carries exactly **one** `slot_fills` record (session-start attribution, PS-2), and
  its `fills["system"]` is the override verbatim while `digests["system"]` is
  `Canonical.digest` of the rendered bytes:

  ```bash
  ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
    puts r.to_json if r["type"]=="slot_fills"}' "$JOURNAL"
  ```

- The first `request_sent`'s system blocks contain the override text — the record is attribution,
  not a second copy of the prompt, so this is where the actual rendered bytes live.

## 2 — an unknown top-level slot filename refuses at launch, by name (`slots.rb:103`)

```bash
mv .lain/slots/system.md .lain/slots/systemm.md
lain chat --root "$(pwd)" --provider ollama --model qwen3-coder:30b < /dev/null
```

Must refuse **before the chronicle opens**, exit 1, no backtrace:

```
unknown slot file ".../.lain/slots/systemm.md"; known slots: system
```

This is a launch-level refusal exactly like `session-and-window.md` §1's — the project's
`Skill::Library` (which owns the one session `Prompt::Slots`) loads early in wiring, well before
any turn is dispatched. Restore the filename before moving on.

## 3 — a role override lands, and touches exactly one role

```bash
mkdir -p .lain/slots/role
echo 'OVERRIDE 42: bias toward property tests.' > .lain/slots/role/test-engineer.md
```

Then, in a live session (`/ruby` journals nothing, so a short quiet window is enough):

```bash
$QA/drive.sh '/ruby Lain::Prompt::Slots.load(root: Dir.pwd).render_role(:test_engineer)' 6 30 >/dev/null
$QA/peek.sh 6
$QA/drive.sh '/ruby Lain::Prompt::Slots.load(root: Dir.pwd).render_role(:dev)' 7 30 >/dev/null
$QA/peek.sh 7
```

Confirm `OVERRIDE 42` appears in `test_engineer`'s render and in **no** sibling's —
`role_spec.rb`'s own unit example ("an override touches one role only") pins this at the object
level; this drives the same claim through the real cockpit against a real `.lain/` tree. Delete
the fixture before §4.

## 4 — an unknown role slot filename refuses at launch, naming the known roles (`slots.rb:114`)

```bash
echo 'cook something' > .lain/slots/role/chef.md
lain chat --root "$(pwd)" --provider ollama --model qwen3-coder:30b < /dev/null
```

Must refuse:

```
unknown role slot file ".../.lain/slots/role/chef.md"; known roles: dev, test-engineer, ...
```

naming all 14 shipped roles, not a truncated sample. Delete the fixture and confirm the session
launches clean again before moving on — a refusal that leaves the tree in a state the NEXT launch
also refuses from is its own small finding.

## 5 — every built-in role ships a template, and none is orphaned (spec-covered, not driven here)

This is the drift guard, and it needs no manual drive: `role_spec.rb`'s "the catalog and the
shipped role templates cannot drift" example already compares `Role::Catalog.names` against
`Prompt::Slots.shipped_role_templates.keys` in **both** directions, so an orphaned template file
(shipped but naming no catalog role) fails it exactly as loudly as a role with no template. Read
its pass/fail off the suite, not off this scenario.

`slots.rb:164`'s render-time `UnknownSlot` (a role name with neither an override nor a shipped
template) is **unreachable for a built-in** through this project-config surface — every built-in
ships a default, so hitting it would mean the packaging itself is broken, not a project's `.lain/`
tree. Spec-covered, not driven here.

## 6 — the 4096-token cache floor *(the one paid step — 2 completions, real Anthropic quota)*

The free two-thirds of this section first:

```bash
wc -c lib/lain/prompt/templates/system.md.erb    # 364 bytes shipped, no override
$QA/drive.sh '/ruby Lain::CacheProfile::ANTHROPIC.min_prefix_tokens' 8 30 >/dev/null; $QA/peek.sh 8
```

364 bytes is ~91 tokens at the ~4-bytes-per-token estimate this project uses elsewhere
(`Lain::ProxyBytes::BYTES_PER_TOKEN`) — well under the 4096-token floor
`CacheProfile::ANTHROPIC.min_prefix_tokens` reports. That much costs nothing, and it is real
evidence: the shipped default is provably, cheaply, below the floor before a single dollar is
spent.

Whether it actually **misses the cache on the wire** is a different claim — "eligible for the
cache" and "cached" are not the same thing, and only a real round trip's `usage` block settles it:

```bash
ANTHROPIC_API_KEY=sk-... lain chat --provider anthropic --model claude-haiku-4-5 --prompt 'say hi' < /dev/null
ANTHROPIC_API_KEY=sk-... lain chat --provider anthropic --model claude-haiku-4-5 --prompt 'say hi again' < /dev/null
```

Read both turns' usage off the journal:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "cache_creation=#{r.dig("usage","cache_creation_input_tokens")} cache_read=#{r.dig("usage","cache_read_input_tokens")}" \
    if r["type"]=="turn_usage"}' "$JOURNAL"
```

Expected: **zero on both fields, on both turns** — no write, no read, at a shipped default this
short. A non-zero reading on either turn is a real finding (either the default has grown past 364
bytes since this was measured — check `wc -c` again first — or Anthropic's published floor moved),
not a flake to retry.

**Budget: 2 completions, real quota, the cheapest priced model (`claude-haiku-4-5`).** Skip this
half of §6 and say so in the findings if the round has no Anthropic budget — reporting only the
free half settled the byte count, not the wire behavior, and the two must not be conflated.

## What this scenario does not cover

The skill-level slot region's own render-time refusal (`Prompt::SkillSlots#source`) — unit-spec
covered, not one of this scenario's three line numbers. And growing an override **past** the
4096-token floor to observe an actual cache **hit** — that needs a bigger fixture and a third
completion, and is a natural follow-up for `rails-blog.md`'s cache-economics work rather than
something this scenario's budget covers.
