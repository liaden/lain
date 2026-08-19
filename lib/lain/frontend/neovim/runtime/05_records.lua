-- I7 motions: ]]/[[ jump between "records", but the three bespoke buffers
-- pack records differently, so each gets its own boundary TEST rather than
-- one shared regex. lain://timeline is one turn per LINE (Buffers#turn_line);
-- lain://inbox is one item per LINE, marked by InboxView#line_for's own
-- two-space-padded age; lain://journal is the odd one out -- one tool-output
-- RUN can span several wrapped LINES sharing an "[id stream]" prefix
-- (JournalView#attribute_lines), so its boundary is a PREFIX CHANGE, not
-- "next line" -- else every wrapped line would present as its own record.
local function journal_prefix(line)
  return line:match("^%[([^%]]*)%]")
end

-- A record that SPANS lines, and the one convention every view drawing one
-- shares: the RUBY side indents every line after a record's first, so a
-- boundary test never has to parse the record's own text -- which for
-- lain://approval is an arbitrary command, and for lain://inbox is a human's
-- arbitrary prose. Anchored, and the ONE spelling of it: ApprovalView::INDENT
-- is the same two spaces on the drawing side, pinned against this line by
-- approval_view_spec so the two languages cannot drift apart in silence.
--
-- IT IS A KEYPRESS RULE BEFORE IT IS A FOLD RULE. Every gesture on these
-- buffers rides a LINE, so the moment a record spans two of them a cursor on
-- the second answers the NEIGHBOUR (Ruby resolving `rendering[line - 1]`) or
-- answers nothing at all (an editor-side `line <= rows` test). Marking the
-- continuations is what lets both sides say "this line belongs to the record
-- above" without either one guessing.
local CONTINUATION = "^  "

-- Does line `i` START a record? Every line does, except a continuation.
--
-- A TRAILER MUST ANSWER TRUE, and that was measured rather than reasoned.
-- 10_folds' at-rest default closes every fold and then RE-OPENS the one holding
-- the buffer's LAST line. So a trailer under a list -- a blank, a hint, a
-- placeholder -- that answers FALSE carries foldexpr level "=", joins the fold
-- of the last ITEM, and makes that at-rest re-open open the last item, every
-- time. Live reading with the trailer swallowed: `foldclosed()` was -1 on every
-- line of a rendered approval, i.e. nothing folded at all. With the trailer
-- answering true: [1, 1, 1, 1, 5, -1] -- the item closed onto its summary, the
-- blank its own closed one-line fold, only the hint open. A one-line fold
-- displays as its own text (10_folds' foldtext), so a trailer loses nothing by
-- getting one.
--
-- `rows` -- the last line that may be a continuation -- is how a view whose
-- TRAILER IS ITSELF INDENTED still answers true there, and it is nil for
-- lain://approval, whose drawing side indents nothing outside the list: the
-- blank and the hint fail the pattern on their own, so the bound would be dead
-- code. Passing one is the exception, not the shape. (An earlier draft made it
-- mandatory and read the count out of a buffer variable, which cost a
-- `nvim_get_current_buf()` this predicate has no business asking for -- it is
-- handed `lines`, and the buffer those came from is nobody's contract here.)
local function spanning_record(lines, i, rows)
  return (rows ~= nil and i > rows) or lines[i]:match(CONTINUATION) == nil
end

-- lain://question's record is one QUESTION, and its start is the heading
-- Question::Document writes: "## `id` (arity)". The ARITY WORD rides in the
-- heading, so this is the same line the `x` keymap recovers a question's
-- boundary from -- one shape read by both, never two.
--
-- The arity is captured and looked up rather than spelled into the pattern:
-- lua patterns have no alternation, so a set of the three labels
-- Question::Document::KIND_LABELS emits is how the disjunction is expressed at
-- all. A body line wearing this shape cannot forge a boundary here --
-- Question::DOCUMENT_HEADING refuses one where the body is BUILT.
--
-- The VALUE is how many ticks the question may carry, which is the other thing
-- the arity word says and the only thing `x` needs from it: "write your answer
-- below" is Question::Document::FREE_TEXT -- a question with no options at all,
-- so nothing under that heading is ever tickable.
local QUESTION_ONE, QUESTION_ANY, QUESTION_NONE = "one", "any", "none"
local QUESTION_ARITIES = {
  ["choose one"] = QUESTION_ONE,
  ["choose any"] = QUESTION_ANY,
  ["write your answer below"] = QUESTION_NONE,
}

-- The question's tick arity, which doubles as the "this line is a heading"
-- predicate the motions and folds ride -- nil for every other line.
local function question_heading(line)
  local arity = line:match("^## `[^`]+` %((.+)%)$")
  return arity ~= nil and QUESTION_ARITIES[arity] or nil
end

local RECORD_START = {
  [TIMELINE] = function(lines, i) return lines[i]:match("^%a+:") ~= nil end,
  -- Not anchored at column 1: `from` is a variable-length sender name
  -- (InboxView::Item), so the age's COLUMN moves per line and there is no
  -- fixed position to anchor to. Anchored on BOTH sides against the
  -- separator instead -- exactly InboxView#line_for's two-space padding
  -- around the age (`"#{from}  #{age}  #{question}"`) -- which is tighter
  -- than "digits followed by s/m/h" alone: a question's free text would need
  -- to independently contain that exact double-space-padded shape to
  -- false-positive, an accepted low-probability risk for an ergonomic (not
  -- correctness-critical) motion.
  [INBOX] = function(lines, i) return lines[i]:match("  %d+[smh]  ") ~= nil end,
  [JOURNAL] = function(lines, i)
    return i == 1 or journal_prefix(lines[i]) ~= journal_prefix(lines[i - 1])
  end,
  [QUESTION] = function(lines, i) return question_heading(lines[i]) end,
  -- lain://approval's entry is NOT here, and it is the one view whose absence
  -- is deliberate rather than a gap: its NAME belongs to 62_approval, which
  -- registers itself into this table with `spanning_record` above. Same
  -- argument 20_buffers makes for `compose_buf` and `question_buf` living with
  -- their round trips -- a capability stays deletable with its file -- and it
  -- keeps 00_constants from having to name a buffer nothing else there needs.
}
