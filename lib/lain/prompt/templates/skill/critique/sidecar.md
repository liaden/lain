## The findings sidecar

When the subject is **code** — a diff, a PR/MR, staged changes, the changes after a plan lands —
write one extra file beside the prose: the prose's own path with its extension replaced by
`.findings.jsonl`, so `.critique-core.md` gets `.critique-core.findings.jsonl`.

The prose is for a human and nothing parses it. The sidecar is the same findings in a form the
review surface can place in the editor, where the human triages them **one at a time** — each one
is a suggestion until he edits it, and editing it is what makes it his. Two files, because a
format an author has to keep valid mid-sentence is a format that ruins the prose.

NDJSON: one JSON object per line, nothing else in the file.

```jsonl
{"path":"lib/lain/review/session.rb","line":248,"rank":"BLOCKER","text":"mark journals before the mark set is updated, so a crash between the two leaves a record no replay can reconcile"}
{"path":"lib/lain/review/marks.rb","side":"old","line":31,"rank":"SHOULD-FIX","text":"reconcile and states both re-derive valid_keys; the second pass is O(changeset) for a fact the first already had"}
{"path":"lib/lain/review/wire.rb","line":90,"rank":"NIT","text":"unquote answers ASCII-8BIT and the caller scrubs; say so in the @return rather than in the prose above it"}
```

- `path` — repository-relative, spelled exactly as the diff spells it.
- `line` — **one** line number: the line the problem starts on. There is no range field *yet*, so
  a finding that spans a range says its extent in its own `text` ("lines 170-182 …"). Nothing this
  sidecar feeds can carry a second number today, and one written here would be dropped on the way
  rather than honoured.
- `side` — `old` for a finding about a line the change deleted. Leave it out for the ordinary
  case; a critique reviews the change as it now stands, so silence means the new side.
- `rank` — `BLOCKER`, `SHOULD-FIX` or `NIT`: the same three ranks the prose ranks by, and the only
  three. They map onto the severities the editor renders at, so a fourth spelling is refused
  rather than shown at whatever severity an unknown word sorts to.
- `text` — what you would have written in the margin. One finding's worth, plain prose, no
  markdown headings.

**Every line is read, and a line that cannot be read refuses the whole sidecar, naming its
number.** Nothing is skipped: a finding dropped in silence is a finding the human never gets to
disagree with, and the count still looks right afterwards. So write no blank lines, no comments
and no trailing prose — and if you found nothing worth placing, write no sidecar at all rather
than an empty one.
