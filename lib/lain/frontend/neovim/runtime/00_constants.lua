-- Every lain:// buffer this runtime knows the name of ahead of time -- named
-- once here (I7) so the filetype table, the motion table, and every autocmd
-- pattern below share ONE spelling instead of five copies of the string.
local JOURNAL = "lain://journal"
local TIMELINE = "lain://timeline"
local WORKSPACE = "lain://workspace"
local DIFF = "lain://diff"
local INBOX = "lain://inbox"
local REQUEST = "lain://request"
local COMPOSE = "lain://compose"
local QUESTION = "lain://question"

-- The full buffer set, in render order, as ONE value user config can iterate
-- (it rides the User LainAttach payload below). WORKSPACE joining the set is
-- T5's fix: Ruby (Buffers::WORKSPACE) always rendered it, but no lua table
-- named it, so set_view built it as an orphan -- filetype "" (the nil lookup
-- landed as an unset option), no syntax, outside the lain contract.
--
-- COMPOSE is deliberately NOT in the set (T15), and QUESTION is out for the
-- same reason (T12). Every name here is a projection primed at attach;
-- lain://compose exists only while the human is composing, lain://question only
-- while a set is open, each is created by a gesture, and each takes focus --
-- priming either would open an empty editor window at every attach.
--
-- The converse does NOT hold since T7: lain://approval is primed at attach too
-- and is still not in this set. It is created by 62_approval's own set_approval
-- rather than by set_view, so nothing here needs its name, and its prime takes
-- no window because that function opens one only `if rows > 0`.
local BUFFERS = { JOURNAL, TIMELINE, WORKSPACE, DIFF, INBOX, REQUEST }

-- I7: filetype attached at buffer CREATION (see `named_buf`/`editable_buf`
-- below), never re-set on re-attach -- both constructors already return
-- early for a buffer that exists, so this runs exactly once per buffer ever.
-- lain://diff reuses nvim's own "diff" filetype so whatever treesitter/syntax
-- a human's config attaches to it just works -- no grammar shipped. The other
-- read-only buffers are not an existing filetype's shape (a turn log, a
-- tool-output journal, a pending-question list, a reminders projection), so
-- they share ONE small namespaced regex syntax ("lain", set up further down)
-- -- the recorded default: a single lain filetype, with b:lain_view naming the
-- view, never per-view filetypes.
local READONLY_FILETYPES = {
  [DIFF] = "diff",
  [TIMELINE] = "lain",
  [JOURNAL] = "lain",
  [INBOX] = "lain",
  [WORKSPACE] = "lain",
}
