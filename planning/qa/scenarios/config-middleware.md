# Scenario: user middleware from config.rb, and the trust that gates it

**Round 26 is the re-check** for the round 25 fixes stated in the refusal at step 3 (j25-3: one sentence naming every missing method).

**Why this one exists:** a `middleware` table in `$XDG_CONFIG_HOME/lain/config.rb` or a project's
`.lain/config.rb` puts the user's own Ruby around every model call, tool call, turn, repl line and
HTTP attempt. The specs drive each seam with a double on the far side. What they cannot see is
whether a refused file stops a real launch before a session exists, whether a real cockpit runs the
member outermost, whether a spawned child gets its own instance, and whether an `http` entry sees a
real streamed request.

**Cost:** cheap. Steps 1 to 3 need no model call. Steps 4 to 6 spend local ollama completions.
**Needs:** the sandbox from `method.md`, so `$XDG_CONFIG_HOME` is the round's own and never your
real `~/.config`; the local bench from `bench.md` for steps 4 to 6; a throwaway project directory
`$REPO` that is a git checkout with at least one small file in it.

Set the trace path once. A member writes there, so the file is the oracle and the model's words are
not:

```bash
TRACE="$QA/mw-trace.txt"; : > "$TRACE"
```

---

## 1. an untrusted user file refuses before a session exists

```bash
mkdir -p "$XDG_CONFIG_HOME/lain"
cat > "$XDG_CONFIG_HOME/lain/config.rb" <<RUBY
class Trace < Lain::Middleware::Base
  def call(env, &app)
    File.open("$TRACE", "a") { |f| f.puts "tool #{object_id} #{env.fetch(:effect).name}" }
    downstream(env, &app)
  end
end
middleware do
  tool Trace
end
RUBY
find "$XDG_STATE_HOME/lain/sessions" -type f 2>/dev/null | wc -l      # baseline
cd "$REPO" && lain chat --provider ollama --model qwen3-coder:30b < /dev/null; echo "exit=$?"
find "$XDG_STATE_HOME/lain/sessions" -type f 2>/dev/null | wc -l      # unchanged
```

Expected: exit non-zero, and the message ends with the constant `these bytes have not been trusted.
Read it, then run: lain trust --user`. The session file count equals the baseline: the refusal came
before the record opened. The same launch from a project with no `.lain/config.rb` and **no user
file** starts normally, so delete the user file once to confirm a missing file is never a refusal.

## 2. `lain trust --user` shows the bytes, records them, and the launch then runs

```bash
echo n | lain trust --user; echo "exit=$?"     # prints the file, then "not trusted; nothing recorded"
lain trust --user < /dev/null; echo "exit=$?"  # end of input is also a no
echo y | lain trust --user                     # "trusted: <path>"
echo y | lain trust --user                     # "already trusted: <path>"
lain trust --user /tmp; echo "exit=$?"         # refused: --user takes no PATH
```

Expected: the two declines exit non-zero and record nothing; `$XDG_STATE_HOME/lain/trust/` gains one
entry after the grant and none after the repeat. With the user file deleted, `lain trust --user`
says `the user config does not exist (<path>), so there is nothing to trust`.

**Automated by** `spec/lain/cli/trust_spec.rb` for the strings and
`spec/lain/project/trust_spec.rb` for the digest. **Still needs a human:** reading the file listing
on a real terminal, and that the mark lands under the sandbox state home rather than the real one.

## 3. a changed byte, a project mark, and a bad registration each refuse by name

```bash
echo '# edited' >> "$XDG_CONFIG_HOME/lain/config.rb"
cd "$REPO" && lain chat --provider ollama --model qwen3-coder:30b < /dev/null; echo "exit=$?"
```

Expected: refused again with the same `lain trust --user` sentence: trust is for those exact bytes.
Then check that a project's mark does not stand in for the user's: with the user file edited back
to its trusted bytes plus one comment line, run `lain trust` (no `--user`) in `$REPO` over a project
`.lain/config.rb` holding **the same bytes**; the user launch must still refuse.

Then re-trust the user file and write a project file with one wrong line:

```bash
mkdir -p "$REPO/.lain" && printf 'middleware do\n  modle String\nend\n' > "$REPO/.lain/config.rb"
echo y | lain trust "$REPO"
cd "$REPO" && lain chat --provider ollama --model qwen3-coder:30b < /dev/null; echo "exit=$?"
```

Expected: refused naming `.lain/config.rb:2`, with `has no verb :modle; known verbs: model, tool,
turn, repl, http`. Repeat with `turn SomeClass`, where `SomeClass` is a class with neither method (a named class prints as its plain name, `<Name>`: classes defined in the `instance_eval`'d builder live under its singleton class, and the `#<Class:0x…>::` prefix that showed in round 26 is stripped (j26-4 fixed, T73); an unnamed one prints
`an anonymous class`). The refusal reads `<name> has no instance #call or #settle`, one sentence naming both missing methods (round 25, j25-3,
fixed); a `tool` or `repl` class lacking `#call` reads `has no instance #call`. A module (define `module Hooks; end` in the user file and write `turn Hooks`) is refused as
`a middleware is a Class, not a Module: Hooks`, before the missing-method check and never as `has no instance #call` (j27-1, open in round 28: `turn Hooks` and `http M2` read `a Class, not a Module: #<Class:0x...>::Hooks`, because `config/middleware.rb:37` still uses `klass.inspect` where `describe` is used one line below); a value that is neither (`turn 5`) reads `a middleware is a Class or a block, got 5`. Also try `http { }` (a block): `http takes a Faraday middleware class, not a block`; each is refused at its own line. A class defined in the user file is not
visible to a project file, so naming one from there refuses as `uninitialized constant`, for the wrong reason. j28-2, open: a project mark follows a loader into any repo with the same bytes. With `.lain/config.rb` = `load File.join(__dir__, "extra", "x.rb")` and a benign `x.rb`, `lain trust` the repo, then in a second, never-trusted repo with the identical `config.rb` and its own `extra/x.rb` that writes a marker file, `LAIN_PREFLIGHT=1 lain chat` constructs with no refusal and the payload runs (trust keys on the top-level `.lain/*.rb` bytes only, `project/trust.rb:13-19`; the prompt names one project). Control: a repo with different `config.rb` bytes refuses. Today expect the payload to run.

Remove the project file before step 4.

## 4. a tool middleware in a live cockpit runs outermost

```bash
lain up --provider ollama --model qwen3-coder:30b       # in the sandbox, per method.md
```

At the chat pane, ask the model to read one small file in `$REPO`, and approve nothing else.

Expected: `grep -c '^tool ' "$TRACE"` is at least 1, and every line names a tool the journal also
shows as a `tool_use`. Then ask it to read a file the `sensitivity` table denies (put
`sensitivity denied: %w[secret.txt]` in a trusted project config): the trace **still has a line for
that call**, because configured middleware runs ahead of lain's guards, and the model's result is
the refusal, never the file. The trace is a record of calls offered, not calls allowed.

Also read the session journal's header: it carries `"middleware":{"user":<digest>,"project":<digest>}`, matching the trust mark file names, and the key is absent when nothing is registered (round 26, j25-2 fixed).

## 5. a subagent gets its own instance

In the same session ask the model to spawn a one-shot subagent that reads the small file.

Expected: `awk '{print $2}' "$TRACE" | sort -u | wc -l` is at least 2, and at least one `read_file`
line carries a different `object_id` from the parent's. The child ran the member (inheritance), and
on a fresh instance (no shared state). Round 28: this model's first one-shot children answered with a prose `<function=read_file>` and called no tool, so spawn again until a child's `tool_use` is in the journal before judging the count (the third spawn passed). If the count is 1 while the child's `tool_use` is in the
journal, the child's stack was built without the configured members: file it.

## 6. an `http` entry sees a real streamed Ollama request

Add to the trusted user file, then re-trust it:

```ruby
class Wire < Faraday::Middleware
  def call(env)
    File.open("TRACEPATH", "a") { |f| f.puts "http #{env.method} #{env.url.path} #{env.body.class}" }
    @app.call(env)
  end
end
middleware do
  http Wire
end
```

Put this entry and any other you added in this step in ONE `middleware do` block: a second block is refused as `declares
middleware twice`.

(Replace `TRACEPATH` with the value of `$TRACE`.) Drive 1 ordinary turn.

The load-time probe for `#call` (and `#settle` for `turn`) skips `http` entries, because a Faraday handler is constructed by Faraday and has no such contract here: an `http` class lacking `#call` is accepted at load, so do not expect a method refusal for one (a non-class or a Module still refuses, and so does a block). Expected: a line `http post /api/chat Hash`: the body is still the caller's Hash because the
entry sits ahead of JSON encoding, and the request is the streamed one. Force a retry with a closed `--api-base` port or a severing proxy, never by killing the shared model server, and confirm the line repeats for each attempt: entries run on every
attempt. j27-2, open: against an accept-and-RST listener the user `http` entry ran for the 4 `POST /api/chat` attempts (4 trace lines) but never for the 4 launch probe requests (`/api/ps`, `/api/tags`, `/api/show`, `/api/ps`), because `provider/ollama/transport.rb:239` clears `http_middleware` and the comment at `:233-235` still says only two numbers are overwritten.

## 7. a member that raises (j28-4, open)

Register two raising members in a trusted config, one per run: `model` calling a method `Lain::Middleware::Env` lacks (`env.keys`), and `class Boom < Lain::Middleware::Base; def call(env, &app) = raise "qa boom"; end` as `tool Boom`.

```bash
cd "$REPO" && lain chat --provider ollama --model qwen3-coder:30b --non-interactive --prompt 'read small.txt' ; echo "exit=$?"
```

Today (round 28): exit 1 with a raw Ruby backtrace (through `agent/model_caller.rb:39` for the `model` member, `agent/tool_runner.rb:460` for the `tool` one); the session file ends `session_closed reason "exit"` with no `run_interrupted` and no error record, the user turn unanswered (the tool_use turn committed with no tool_result in the `tool` case); in a cockpit the chat pane dies `Pane is dead (status 1)` and the journal again says `reason exit`. The control is a chat that quits normally, which writes the same record, so the journal cannot tell a crash from a quit. Neither stack contains a member's exception (`middleware.rb:132-134`). Re-check: the expected shape is one call failing, or the run ending with a named interruption.

## 8. a `model` and an `http` member together over an eagerly summarized result (j28-5, open)

Register `model Mtrace` and `http Wire` (both writing to `$TRACE`) in one `middleware do` block, run a local chat, and have it list a directory of about 1000 entries so the result is eagerly summarized.

Expected today: the journal holds 3 `request_sent` (the agent's two and the summarizer's, `max_tokens` 1024) and 1 `oracle_answer`; the trace holds 3 `http post /api/chat` lines but only 2 `model` lines. The judge's call (escalation `auto`, allow) does pass through `model` on a fresh instance. So "around every model call" holds for the agent and the judge, not for the summarizer, the handoff or the secret oracle (`Oracle::Model` round trips outside the agent's stack, `cli/wiring.rb:696`, `tools/subagent.rb:1771`). Record the counts; a `model` line per `request_sent` would be the fix.

## Close-out

Run the sandbox negative from `method.md`: the real `~/.config/lain/` and
`~/.local/state/lain/trust/` must be byte-identical to the baseline taken before step 1.
