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
}
