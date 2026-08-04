-- Whole-buffer replace for the ONE editable view, lain://request (4-2.3). It
-- writes WITHOUT the nomodifiable flip set_view does, so the buffer stays
-- editable for the human after the render. Like set_view it never focuses or
-- jumps to the buffer, so a re-render can't steal the cursor mid-edit.
function _G.__lain.set_request(name, lines)
  local buf = editable_buf(name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  announce_render(name, buf)
end

-- The current lain://request bytes, for :LainResend to hand back to Ruby -- read
-- HERE, in the lua callback, so the resend rpcrequest carries the edited lines
-- as its argument and the Ruby side never has to nest a buffer read inside its
-- inbound dispatch. Empty when nobody has rendered a request yet.
local function request_lines()
  local buf = vim.fn.bufnr(REQUEST)
  if buf == -1 then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- :LainResend carries the edited buffer along, so it can't reuse agent_command
-- (which sends only the verb): it reads lain://request and passes the lines as
-- the command's second argument. Still enqueue-and-ack -- the Ruby side queues
-- the resend and answers in microseconds, exactly like the bare commands.
define("LainResend", function()
  vim.rpcrequest(chan, "lain_command", "resend", request_lines())
end)
define("LainSend", agent_command("send"))
define("LainContext", agent_command("context"))
