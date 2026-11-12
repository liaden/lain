# Scenario: the session tree, labels, export and share

**What it exercises:** `lain://tree` (the turn tree, `<CR>` rewind, `L` label, fork rows, `:LainTreeRefresh`), the `/label`
command and its `turn_labeled` record, `lain export` as HTML and as JSONL, and `/share`.

**Status:** written 2026-10-29 from the code at HEAD (`69e8dc60`: `frontend/neovim/tree_view.rb`,
`runtime/64_tree.lua`, `cli/command/label.rb`, `cli/sessions/forks.rb`, `cli/export.rb` and `cli/export/`,
`cli/command/share.rb`, `docs/commands.md`). Nothing here has been driven. Every "Expect" is a prediction read off the
code, so a mismatch is either a defect or a stale line in this file, and the round says which.

**The question it answers:** does a session's shape stay true across every way it is shown or sent out? The tree must
draw the chain the head stands on and mark what a rewind abandoned. A label must survive a resume. An export or a gist
must carry the model's masked view of that chain, with the home directory and project root rewritten, and must refuse
rather than carry a read that was released in clear.

**Cost:** §1 to §4 need a cockpit and about 4 short completions on a local model. §5 and §6 are offline once a
session file exists, except the one released read, which is a fifth completion. No spend beyond the local model.

**Needs:** `../bench.md` up, tmux and nvim for §1 to §4, `lain up`. A stand-in `gh` first on `PATH` for §6 (below), and
**no real `gh` reachable**: `command -v gh` must print the stand-in, because `/share` publishes. Read `../method.md`
first, build the sandbox with `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, and start each Bash call that touches
files with `: "${QA:?}"`.

---

## 0: The subject

A throwaway repository at `$QA/proj` with one committed file `src/notes.txt` holding 3 lines. Launch a cockpit from it
(`lain up $QA/proj -- --provider ollama --model qwen3-coder:30b`), and work in the chat pane. Ask 2 plain questions with
"plain text only, no tools" in each (this model wraps answers in `todo_write` and wanders into `ask_human` otherwise), so
the session holds user and assistant turns. Name the session file once and keep it:

```bash
S=$(ls -t "$XDG_STATE_HOME"/lain/sessions/*/*.ndjson | head -1)
```

## 1: The tree at rest and after turns

In the editor, `:buffer lain://tree` (the buffer is one of the runtime's primed set; round 28's table in
`cockpit-surfaces.md` §1 lists 8 and the runtime now primes 9, adding `lain://todos`, and the tree).

| State | Expect |
|---|---|
| a fresh chat, before any turn | the buffer holds the one line `(no turns yet)` |
| after 2 asks | one trunk, one line per turn, `user: <first text>` then `assistant: <first text>`, at indent 0; the newest line ends `  [head]` |
| a turn whose content has no text block | `user: (tool_result)` or `assistant: (tool_use)`, never an empty `user: ` |
| a multi-line prompt | the preview is one line, newlines folded to spaces |

The tree is built from the `turn_usage` events the view has seen, each naming a chain, so it can only show turns the
chat has asked a model about. Record what it shows between a `--resume` and the first new ask (the labels and chain
should come back with that ask, not before it).

## 2: Rewind from the tree

1. Put the cursor on the first `assistant:` line and press `<CR>`. This sends the typed `/rewind <digest>` down the one
   command registry (`human_replies.rb`, `tree_rewind`), so the chat pane shows `/rewind`'s own sentence and the journal
   gains one `rewound` record. The tree redraws and `[head]` moves to the line you chose. The old continuation is marked
   `  [abandoned]`. With one abandoned child it is drawn at the SAME depth, after the `[head]` line; it is indented one level
   and listed before the trunk only once a turn has a second child (step 3), because only the non-last children of a turn
   indent (`TreeView#continuations`).
2. `<CR>` on an `[abandoned]` line: refused with `that turn is on an abandoned branch; the head cannot move there`; the head
   does not move and nothing is journaled.
3. Ask a new question, so a second branch grows. The tree now shows 1 abandoned subtree (2 branches in all), indented and
   listed before the trunk, which comes last. A second rewind and ask make 2 abandoned subtrees. The abandoned lines never change role: a turn is abandoned exactly when it is not an ancestor of the head, so a
   rewind forward onto it makes it live again.
4. `<CR>` on a line that names no turn (a `fork or resume:` row from §4, or a blank): refused `no turn on lain://tree line N`.
5. **A stale press.** The line rides with a generation stamp (`b:lain_view_generation`) because the buffer repaints on the
   drain thread's clock. Send the gesture with the stamp one behind, over nvim RPC (`method.md`, "driving nvim over RPC"):
   `vim.rpcrequest(chan, "lain_command", "tree_rewind", {line, vim.b.lain_view_generation - 1})`. Expect `the tree changed
   since it was drawn; look again and retry`, with no rewind.
6. The same gesture while a tool call is in flight takes `/rewind`'s in-flight refusal (`repl-commands.md` §3), because the
   tree reuses that command. Do not expect a tree-specific sentence.
7. `:LainTreeRewind` typed from another buffer refuses `:LainTreeRewind rewinds to the turn under the cursor in lain://tree`
   (the command is global, the check is on the current buffer).

## 3: Labels

| Do | Expect |
|---|---|
| in the tree, cursor on a turn, `L`, type `dead end`, Enter | the prompt reads `label: `; the chat pane says `labeled blake3:<64 hex>` (the tree prints the whole digest; only `/label` abbreviates); the line gains the suffix `  # dead end` after any `[head]` marker |
| `L` and Esc | nothing labeled, nothing journaled |
| `L` and an empty line | the label is cleared; the suffix disappears |
| `/label first answer` in the input pane | labels the head: `labeled blake3:<12 hex>...: first answer` |
| `/label <4 hex of an ancestor> text` | labels that turn |
| `/label dead end` (first word `dead` has digest shape) | labels the head `dead end` unless a turn's digest starts with `dead`, in which case it names that turn; check with a prefix that is not an ancestor first |
| `/label beef` where a turn's digest starts with `beef` | clears that turn's label, per `docs/commands.md`; it does not label the head |
| `/label x` before any turn | `nothing to label: this session has no committed turns` |
| `L` on a `fork or resume:` row | `no turn on lain://tree line N` |

The ambiguity refusal (a prefix 2 turns share, refused as `/pin` refuses it) is not drivable by hand: two blake3 digests share a
4-hex prefix about once in 65,536 pairs. It belongs to the unit specs, and a round does not list it as a step.

Journal: `ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; puts l if r["type"]=="turn_labeled"}' $S`
holds one record per change, `{digest, label}`, and an empty label is the clearing record. The last record for a digest
wins. `/quit`, `lain chat --resume $S`, ask once, then `:buffer lain://tree`: the labels that were standing are back,
and the one you cleared is not. A `--no-journal` chat accepts `/label` and keeps nothing (`Session::Null`).

## 4: Forks in the tree

Fork rows are the sessions that began from a turn of this one, found by the child's header `resumed_from`.

1. With the tree open, `/fork` from a turn you rewound to, or `lain chat --fork <file>@<digest>` from a shell. The
   child's file name appears under the parent turn it started at, as `fork or resume: <child>.ndjson`, indented one level
   deeper than that turn.
2. **It does not appear on its own.** Fork rows are read when the buffer is first drawn and on `:LainTreeRefresh`, never per
   event, because the read scans the session directory. Make a fork after the tree is open and confirm the row is missing
   until `:LainTreeRefresh`; then it is there and the buffer repaints.
3. A resume writes the same header pair as a fork (`--resume` of the parent), so it also shows as a row. A row is "began
   here", not "is a fork".
4. Promoting a chat renames its journal, so the scan names the parent by its current file each time. Start the child
   before the parent is promoted if you can, and record what the row says after.
5. A `/btw` child (ephemeral) also resumes from the head; record whether its row shows, since the scan reads every
   `.ndjson` in the project's session directories.

## 5: `lain export`

Use the §0 session (closed with `/quit`, or still open: the export reads the file as it stands). Run every `lain export` and
the `/share` comparison from `cd $QA/proj`: the project, and with it `<project>` and the bare-name selector, is resolved from
the current directory, so from elsewhere `<project>` is not written and `lain export <basename>` refuses.

| Do | Expect |
|---|---|
| `lain export $S > $QA/s.html` | one self-contained page: a `<section class="turn">` per turn of the chain the head ends on, with `<h3>` role and a `<pre>` per block |
| `lain export <basename without .ndjson>` | the same bytes; the selector resolves as `lain friction`'s does |
| `lain export nosuch` | refuses `no session found for "nosuch" -- looked at <every path tried>` |
| `lain export $S --html --jsonl` | refuses `--html and --jsonl are exclusive` |
| `--out $QA/s.html` twice | the first prints the path and `stat -c %a` reads `600`; the second refuses `<path> exists; pass --force to overwrite it`; with `--force` it succeeds |
| `--out` naming a symlink, with `--force` | the link is unlinked and a fresh 0600 file made; the link's target is untouched |

**What the page holds.** Run it over a session you rewound in §2: the abandoned turns are absent, because the page follows
only the head's chain. Compare it with the tree's `[abandoned]` lines. A compaction cut shows as `[compaction: earlier
turns elided]` (rails-blog's recipe makes one cheaply; skip it here and say so). Labels are not in the page; record that
as the shape, and file it only if a card says otherwise.

**A resumed session exports every turn the model saw.** Resume the §0 session once (`lain chat --resume <file>`, ask 1 question,
`/quit`) so the second file's header links to the first, then `lain export <the second file> > $QA/r.html`. The page holds the
turns from before the resume and the turns after it, in order: count the `<section class="turn">` elements, and expect the sum of
the two files' turns. The footer's masked and released counts also read the whole chain, so a read released in the first file
refuses the export of the second as it refuses the first (below), and a region masked there is counted in the footer. `lain
export <second file> --jsonl` still prints only that one file, byte for byte, because the JSONL is the record `lain verify`
checks and the chain is a view over several. Delete the first file and export the second as html: it refuses `an earlier file of
the resume chain is missing (<path>), so the released count cannot be read across the chain; nothing was exported or shared`
and writes nothing, and the `--jsonl` export still works. A page with only the second file's turns is the defect.

**A session with no turns exports nothing.** Start `lain chat`, `/quit` before asking anything, and `lain export` that file as
html: it refuses `this session has no turns; nothing was exported or shared`, exits 1 and writes no file, with `--out` too. A page
of headers over no turns is the defect.

**Paths.** `grep -c "$HOME" $QA/s.html` prints 0, the home appearing as `~`; the project root appears as `<project>`.
The rewrite is at word boundaries, so a path inside a longer one (`$HOME-backup`) stays. `lain export $S --jsonl | grep
-c "$HOME"` is greater than 0: the JSONL keeps the system prompt, absolute paths and approval records, which is why it
is a local record and not for sharing.

**Markup.** Have a tool result or a prompt hold `<script>alert(1)</script>`. In the HTML it is text (`&lt;script&gt;`), and
`grep -c '<script>' $QA/s.html` prints 0. The page's own markup has a `<style>` and no script.

**Masked reads.** Plant `src/creds.env` holding `AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKE1234` and ask the model to read it;
under `auto` the read parks, answer `n` (masked). The session holds a `source_masked` record. **Positive control:** the
read must really have happened, so the session file holds a `read_file` call naming `creds.env` and the `source_masked`
record, and the placeholder appears in the tool result. If the model paraphrased or never read it, the "0 hits" below
pass vacuously: the step is voided, not passed. Then:

- the fake value has 0 hits in `$QA/s.html` and 0 in the `--jsonl` output. The JSONL holds `<redacted:1>`; the HTML
  escapes it, so grep `&lt;redacted:1&gt;` there (a grep for the raw form in the page finds 0);
- the HTML footer reads `1 region were masked as <redacted:n>; the session was not re-scanned.` (the grammar is the
  template's, `regions(1)` gives `1 region`, so the exact sentence is `1 region were masked ...`; say what it prints);
- the footer counts masked reads, commands and searches together (`source_masked`, `command_redacted`, `search_redacted`).

**A released read refuses.** Create `src/late.env` with a fake credential after launch, ask for the read, answer `y` at the
release prompt (a file that existed at launch is `secret-boundary.md`'s g28-3, so avoid it here). The positive control is
the `read_released` record itself: without it the model did not read the file and nothing below applies. Then:

- `lain export $S` refuses `1 regions were released to the model in this session and appear in clear; pass
  --include-released to export them in the html`, writes nothing, and exits 1;
- `lain export $S --include-released` writes the page, and the footer gains `1 region were released to the model and appear
  in clear.`;
- `lain export $S --jsonl` is not refused (it is already the local record).

**The JSONL.** Use a second session that never rewound (the §0 session did, in §2): `lain export $S2 --jsonl | diff - $S2`
prints nothing. After a rewind whose
turn never landed it drops that retreat line, so `lain verify` on the export flags the chain, as `docs/commands.md` says.
Run `lain verify $S` as the control: it passes.

## 6: `/share`

Never run this against the real `gh`. Stand-in:

```bash
cat > $QA/shim/gh <<'EOF'
#!/bin/sh
{ echo "argv: $*"; cat > "$QA/gist-body.html"; } >> "$QA/gh.log"
case "$GH_MODE" in fail) echo "gh: not logged in" >&2; exit 1;; empty) exit 0;; *) echo "https://gist.example/abc123";; esac
EOF
chmod +x $QA/shim/gh
```

A pane inherits the tmux SERVER's environment, not the shell that ran `lain up` (`method.md`, "Cap a cockpit's memory" and the
`tmux set-environment` notes). Put `$QA/shim` on `PATH` and `GH_MODE` in the environment of the shell that starts the server,
or set them with `tmux set-environment -g`; relaunching `lain up` on a running server keeps the old values, so kill the
server between modes.

| Do (in the chat) | Expect |
|---|---|
| `/share extra` | the usage line `/share -- publish this session's masked export as a secret gist`; `gh.log` has no new line |
| `/share` over the §0 session | 2 lines: `shared the model's masked view of <file> as a secret gist` and `https://gist.example/abc123 (N regions masked)`; `gh.log` holds `argv: gist create --public=false --filename <basename>.html -`; `gist-body.html` equals `lain export` of the same file, byte for byte |
| the journal afterwards | one `session_shared` record with `url`, `format html` and the same `masked` count |
| after the `read_released` of §5 | refuses `1 region was released to the model and sit in the transcript in clear, so nothing was shared; `lain export` writes a local copy`; `gh.log` unchanged (the sentence's grammar is the code's; copy what prints) |
| `/share` over a session with no turns (a fresh chat) | refuses `this session has no turns; nothing was exported or shared`; `gh.log` has no new line and no `session_shared` record |
| `/share` over a resumed session | the gist body holds the turns of the whole chain, as `lain export` of the same file does |
| `GH_MODE=fail` | `gh gist create failed: gh: not logged in`; no `session_shared` record |
| `GH_MODE=empty` | `gh answered no gist url, so nothing was recorded` |
| no `gh` on `PATH` | `gh is needed to share a session; `lain export` writes a local copy` |
| a `--no-journal` chat | `/share needs the session file, and this chat has none (--no-journal)` |

A secret gist is unlisted, not private (`docs/commands.md`). The scenario never checks that a real gist is unreadable,
because it never makes one.

## 7: `lain usage` *(round 3, free, offline)*

`lain usage SESSION` folds a session's `turn_usage` records into input and output tokens per command and role. Run it over a session
that used a skill with reviewers (`/plan-epic` with `epic_review`) and over one recorded before this change. Expect a table headed
`COMMAND  ROLE  INPUT  OUTPUT`, sorted by command then role; the reviewers' tokens under the skill's command, not under `-`; a turn
with no command under `-` (every row of an old session); and, when the approval judge spent anything, an `auto_approver` row and
a note that its spend is not split by command. The totals equal the sum of the session's `turn_usage` records (read them with
the `ruby -rjson` one-liner in `failure-injection.md` §7), so nothing is counted twice, and `lain usage nosuch` fails by naming
the selector. **Wrong looks like:** a judge turn counted under a command, or a child's turns under `-` when the parent ran a skill.

## What this scenario cannot answer

- **Whether a real gist renders.** The stand-in proves what lain sends, not what GitHub shows.
- **Whether the tree stays usable at size.** The walk is preorder without recursion, written for chains thousands deep;
  no round has drawn one. A 2,000-turn session (a scripted provider writes one cheaply) is the missing check.
- **`/release PATH`** is `secret-boundary.md`'s (g28-1), and `lain://todos` belongs to `cockpit-surfaces.md`.
