# Scenario: failure injection and record integrity

**Why this one exists:** these probes are **deterministic, fast, and need no model**, which makes
them the cheapest real signal in the whole QA suite. Round 4 ran the lot in a few minutes and all
of it passed. They are held apart from the subject scenarios so a broken machine cannot contaminate
a main pass — and so they can be run alone, as a regression gate, after any chunk touching the
journal, the store, or the transport.

**Cost:** minutes. **Needs:** a project with at least one recorded multi-turn session. No cockpit,
no nvim, no model call for most of it.

---

## 1 — Record integrity, at rest

Every journal line parses; no `journal_error`; occupancy reconciles against `input_tokens` and the
served window; compaction decisions carry their denominator.

```bash
ruby -rjson -e 'bad=0; n=0; ARGF.each_line{|l| n+=1; (JSON.parse(l) rescue (bad+=1))}; puts "#{n} lines, #{bad} unparseable"' "$JOURNAL"
```

Remember token counts are nested: `turn_usage.usage.input_tokens`, not top-level.

## 2 — A torn `turn` record

**Tear a `turn` record specifically.** Skipping unparseable lines is `Journal.records`' documented
contract (the fd can be shared with Rust tracing spans), so tearing an arbitrary line proves nothing
— it is invisible by design. Halve an actual `turn` record and the loss becomes legible.

```bash
ruby -rjson -e '
src, dst = ARGV
lines = File.readlines(src)
idx = lines.each_index.find { |i| (JSON.parse(lines[i])["type"] rescue nil) == "turn" && i > 10 }
lines[idx] = lines[idx][0, lines[idx].bytesize / 2] + "\n"
File.write(dst, lines.join)' "$GOOD" "$TORN"
lain sessions
```

Expected: **one fewer turn, under the SAME head digest, plus `1 line unparsed`.** Then fork the
damaged session at that advertised head:

    cannot fork <session>: turn record 3 (user) recorded as blake3:6dbf0c8b… re-commits to
    blake3:6aaa90f1…; its content no longer matches its content address

Exit 1, no backtrace, naming the record index, its role, and **both** digests. Corruption is meant
to be **invisible at rest but unforgeable on use** — check both halves, not just the first.

## 3 — A dangling causal edge

Remove a record that a later record depends on, then try both entry points.

**Which key to break depends on what ran.** A session of plain turns links via `parent`;
`causal_parents` appears only once a spawn or a message has landed. Round 4's journals had **no**
`causal_parents` at all, so a probe written only against that key silently tests nothing — check
first:

```bash
ruby -rjson -e 'k=Hash.new(0); ARGF.each_line{|l| r=JSON.parse(l) rescue next; k["parent"]+=1 if r["parent"]; k["causal_parents"]+=1 if r["causal_parents"]}; p k' "$JOURNAL"
```

Then remove a turn a later turn names, and expect **the same clean refusal from both**:

```
cannot fork <session>: turn record 0 (assistant) recorded as blake3:53f6b032… re-commits to blake3:465e9071…
cannot resume <session>: turn record 0 (assistant) recorded as blake3:53f6b032… re-commits to blake3:465e9071…
```

Both exit 1. An earlier follow-up recorded this as "fixed for `--fork` only"; that is now stale in
the good direction — `--resume` is equally clean and carries its own `cannot resume` prefix.

A bad digest **prefix** must also refuse by name: `no turn matching "<prefix>" recorded in <session>`.

## 4 — A severed transport

**Use a severing proxy, not a killed server.** Put a small TCP forwarder in front of the model
endpoint and have it `SO_LINGER 0`-close (a hard RST) after N bytes of response, then point
`--api-base` at it. Deterministic where killing a service is a timing race, and it leaves the
operator's model server untouched — which matters on a shared machine.

`lain bench record <taskfile> -n 1 --out <dir>` is the non-interactive vehicle. **Always take a
control run against the real endpoint in the same session**, because the whole finding is the gap
between them (this is how a 1.9s control vs >400s hang was found; a bare "kill the server" would
almost certainly not have).

## 5 — An unreachable endpoint

**`--api-base` probes are TURN-level, not launch-level** — judging by launch records is a false
pass. The launch-time window probe falls back cleanly and the chat starts normally at `you>`; the
failure is on the first turn. `--prompt '<text>'` is the cheap vehicle, in a window with
`remain-on-exit on`.

- An unroutable address (`http://10.255.255.1:11434`): expect a **fast, named** failure — ~26s at
  the default 5s connect timeout, ~8s under `LAIN_CONNECT_TIMEOUT=1` — with retries rendered live.
  Not the ~20 minutes of silence this used to cost.
- A scheme-less typo (`localhost:11434`), the mistake a human actually makes: must refuse at
  construction naming `--api-base`, **not** crash with a Faraday backtrace. It is a *valid* URI —
  scheme `localhost`, opaque `11434` — so a `URI::InvalidURIError` guard does not catch it.

Count the real attempts with a counting TCP listener (`method.md`) rather than trusting the rendered
ordinals.

## 6 — Ctrl-C during a parked `ask_human`

Known uncovered: signals are routed to a null handler outside an ordinary turn's ask, so either the
process dies outright or the ask stays parked. Both are the documented gap; **the actual check is
that the session journal still parses afterwards.**

## 7 — The iteration ceiling

Drive past the loop ceiling and confirm what happens **after** it:

```bash
ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="turn_usage"}; puts n' "$JOURNAL"
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts "#{r["ts"]} #{r["type"]}" if r["type"]=="run_interrupted"}' "$JOURNAL"
```

Expected once fixed: the ceiling bounds **one ask**, a later prompt starts a fresh count, and any
refusal is rendered. The round-4 failure to regress against is a per-session counter that, once
spent, accepted every later prompt, committed it, immediately `run_interrupted` it, and **rendered
nothing at all** while the HUD kept reading `idle 0s`.

**A refusal is not a crash.** Whatever the ceiling does, it should not arrive as an Async
`Task may have ended with unhandled exception` plus a 27-frame backtrace, with the clean one-line
message underneath it.
