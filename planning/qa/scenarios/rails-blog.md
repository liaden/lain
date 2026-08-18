# Scenario: a Rails blog (long-horizon, high-volume)

**Why this one exists:** bowling is a single small file. This scenario is the only one that
generates **hundreds of files, very large tool results, and dozens of turns**, so it is the natural
home for the three things the small scenarios structurally cannot reach:

1. **Compaction at scale** — filling the context until a compaction actually fires. Rounds 3 and 4
   both failed to reach this, making it the least-exercised path in the whole QA suite.
2. **Unbounded tool output.** `rails new` emits an enormous `bash` result; `list_files` on
   `app/`, `glob '**/*.rb'` and `read_file` on a schema are all large. Fourteen tools bound nothing
   today, and `arXiv:2508.21433` measures observation tokens at ~84% of an average agent turn.
3. **The approval gate under volume** — many `bash` calls per turn, which is exactly the shape that
   wedges on a second gated call in one turn.

**Cost:** expensive. Several sessions. Run it when the question is *context economics*, not when the
question is *does the loop work*.

**Needs:** `bench.md` up. Ruby with `rails` available — **check first**, and if it is absent do not
improvise a substitute mid-run:

```bash
gem list -i rails || echo "FALLBACK: use --minimal, or run rust-cli.md instead"
```

If `rails` is missing, `rails new blog --minimal --skip-bundle` still exercises the volume that
matters. A Sinatra app does **not** — it is too small to be this scenario.

---

## The subject

A blog with three features, stated to the model in one directive prompt:

1. **Posts** — title, body, published-at; index / show / create / update / destroy.
2. **Comments** — belonging to a post, with author name and body; created from the post's show page.
3. **Tags** — many-to-many with posts, and an index filtered by tag.

Plus: **a passing test for each feature**, in whatever framework the app was generated with.

**Definition of done:** `bin/rails test` (or `rspec`) exits 0 with at least one test per feature,
and the three routes resolve. The driver runs the suite — the model's claim that it passes is not
the grading instrument, exactly as in `bowling-ruby.md`.

This is deliberately more than a 3B-active MoE will finish. **That is fine and is not the
measurement.** The measurement is what the harness does across a long, file-heavy, failure-prone
run. Record how far it got; do not coax it past the mechanical escalation trigger.

## What to watch, in order of value

### 1. Compaction, at last

Do this **early in the act, not last** — it is the point of the scenario.

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next;
  puts "#{r["ts"]} win=#{r["window_tokens"]} used=#{r["used_tokens"].inspect} prov=#{r["provenance"].inspect} sig=#{r["signals"].inspect}" \
    if r["type"]=="compaction_decision"}' "$JOURNAL"
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts r["type"]}' "$JOURNAL" | sort | uniq -c
```

Expected once occupancy climbs: `signals` stops being `[]`, a compaction is warranted, and
`.lain/state.json` `compactions` increments. Then:

- Does the summarizer tier that fires match the one the flags asked for
  (`--compact-strategy`, `--summarizer-provider`, `--summarizer-model`)?
- Does a compaction **rewrite history more than once** for one crossing? (Round 2's F-series found
  compaction firing on a *provisional* window and rewriting three times.)
- Does occupancy actually fall afterwards, and does the HUD's `ctx N%` follow it down?
- Does the prompt cache go cold at the rewrite, and is that visible?

### 2. Tool-result volume

Capture the size of the largest tool results in the session:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="turn";
  Array(r["content"]).each{|b| next unless b["type"]=="tool_result";
    puts b["content"].to_s.bytesize }}' "$JOURNAL" | sort -rn | head
```

`rails new` alone should produce a result orders of magnitude past anything bowling generates. Note
which tools produced the top ten, and whether any of them disclosed a cap. Today only `grep`,
`ast_search`, `web_fetch` and `ast_dump` bound at all, and only by cap-and-disclose.

### 3. The approval gate under volume

A `rails new` run and a `bundle install` are both gated `bash`. Expect several approvals per turn —
which is the trigger shape for a second-approval wedge. If a prompt does not render, read
`lain://approval` over RPC (`method.md`) rather than answering blind, and record whether
`:LainApprove` is the only recovery.

Check `.lain/config.toml` between acts. A model that talks you into "always" for `bash` in a Rails
tree has just pre-approved arbitrary shell for the rest of the session.

### 4. Session lifetime

This scenario will hit the model-call ceiling. Track it deliberately:

```bash
ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="turn_usage"}; puts n' "$JOURNAL"
```

and check for `run_interrupted` records with nothing rendered. Restarting the session mid-scenario
is expected here; say in the findings which act boundary you restarted at, because it changes what
the compaction reading means.

## What this scenario does NOT test

`--isolation worktree`. A Rails tree is the obvious place real-`git` isolation seams would show,
and no scenario drives them. Worth its own scenario when isolation backends matter.
