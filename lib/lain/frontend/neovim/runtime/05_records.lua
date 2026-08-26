-- Record motions: ]]/[[ jump between "records", but the bespoke buffers pack
-- records differently, so each gets its own boundary TEST rather than one shared
-- regex. lain://timeline is one turn per LINE; lain://inbox is one question SET
-- per item, spanning as many lines as its question needs, so it rides the
-- continuation convention below; lain://journal is the odd one out -- one
-- tool-output RUN can span several wrapped LINES sharing an "[id stream]"
-- prefix, so its boundary is a PREFIX CHANGE, not "next line", or every wrapped
-- line would present as its own record.
local function journal_prefix(line)
  return line:match("^%[([^%]]*)%]")
end

-- A record that SPANS lines, and the convention every view drawing one shares:
-- the RUBY side indents every line after a record's first, so a boundary test
-- never has to parse the record's own text -- an arbitrary command on
-- lain://approval, a human's arbitrary prose on lain://inbox.
-- ApprovalView::INDENT is the same two spaces on the drawing side, pinned
-- against this line by approval_view_spec.
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
-- TRAILER IS ITSELF INDENTED still answers true there, and it is nil for both
-- views drawing spanning records today: neither indents anything outside its
-- list, so their blanks and keys fail the pattern on their own. Passing one is
-- the exception, not the shape, and it is an ARGUMENT rather than a buffer
-- variable because this predicate is handed `lines` and has no business asking
-- for `nvim_get_current_buf()`.
local function spanning_record(lines, i, rows)
  return (rows ~= nil and i > rows) or lines[i]:match(CONTINUATION) == nil
end

-- lain://question's record is one QUESTION, starting at the heading
-- Question::Document writes: "## `id` (arity)". The ARITY WORD rides in the
-- heading, so this is the same line the `x` keymap recovers a question's
-- boundary from -- one shape read by both.
--
-- The arity is captured and LOOKED UP rather than spelled into the pattern: lua
-- patterns have no alternation, so a set of the three labels
-- Question::Document::KIND_LABELS emits is how the disjunction is expressed at
-- all. A body line wearing this shape cannot forge a boundary --
-- Question::DOCUMENT_HEADING refuses one where the body is BUILT.
--
-- The VALUE is how many ticks the question may carry, the only thing `x` needs
-- from it: "write your answer below" is a question with no options at all, so
-- nothing under that heading is ever tickable.
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
  -- lain://inbox's items SPAN lines, so its boundary is the continuation
  -- convention above -- unwrapped, because the drawing side indents nothing
  -- outside the list and its trailer answers true on the pattern alone.
  --
  -- "Is this line an answerable ROW" is a DIFFERENT question and lives in
  -- 70_inbox: keys are a record and are not a row.
  [INBOX] = spanning_record,
  [JOURNAL] = function(lines, i)
    return i == 1 or journal_prefix(lines[i]) ~= journal_prefix(lines[i - 1])
  end,
  [QUESTION] = function(lines, i) return question_heading(lines[i]) end,
  -- lain://approval's absence is deliberate: its NAME belongs to 62_approval,
  -- which registers itself into this table with `spanning_record` above, so a
  -- capability stays deletable with its file.
}

-- WHICH RECORD IS LIVE AT REST, the table 10_folds' `open_at_rest` reads. The
-- doctrine lives there; the DECLARATION lives here, beside RECORD_START and for
-- its reason. A module loading BETWEEN the declaration and a registration sees
-- no local at all, so `FORM_VIEWS[x] = true` would quietly create a GLOBAL that
-- the later `local` then shadows: the registration is lost, nothing errors, and
-- no lint reports it.
local FORM_VIEWS = { [QUESTION] = true }
