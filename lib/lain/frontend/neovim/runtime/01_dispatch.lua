-- ONE DOOR for every render rail, and the reason there is only one.
--
-- Ruby reaches this runtime by `nvim_exec_lua` NOTIFY, so the chunk it sends is
-- a string Ruby holds. Thirteen rails once meant thirteen such strings, each
-- spelling out `local a, b = ...; if _G.__lain then _G.__lain.fn(a, b) end` --
-- identical but for the names, and each one a place a parameter could be
-- dropped or transposed with nothing said, because nvim discards a notify's
-- error. Now the chunk is ONE string naming an entry point and carrying its
-- arguments as a list, and the binding happens HERE, where `unpack` can neither
-- lose an argument nor reorder one. {Lain::Frontend::Neovim::RenderQueue::RAILS}
-- is the other half; its spec compares every row against the `function
-- _G.__lain.<name>(<params>)` declarations in this directory.
--
-- `args` never has a hole, which is what makes `#args` the arity Ruby sent: a
-- Ruby nil crosses msgpack and arrives as `vim.NIL`, a truthy userdata, never
-- as a lua nil. That is the same fact `RenderQueue#post_view` relies on when it
-- varies ARITY rather than passing nil for an absent rendering stamp.
--
-- AN UNKNOWN NAME RAISES rather than no-opping, and it is worth being exact
-- about what that does and does not buy. It does NOT reach the cockpit: on the
-- rail's own path the call is a notify, and a failing notify is discarded with
-- nothing left in `:messages` -- measured against a live nvim, which came back
-- empty. What it buys is that every caller on the REQUEST path -- a spec's
-- `exec_lua`, a human's own `:lua` -- is told, and that the no-op cannot be
-- mistaken for the design. The gate that actually catches a wrong name is on
-- the Ruby side, comparing each row against the declarations above.
--
-- The `if _G.__lain then` guard in the chunk Ruby sends asks a different
-- question and keeps its no-op: that one is a render racing a not-yet-injected
-- runtime, which is real, transient, and nobody's defect.
--
-- `do ... end` because every module in this chunk shares ONE function scope: a
-- top-level local declared here is in scope for all 22 modules below it and
-- counts against lua's 200-local ceiling, which the runtime already sits at 86
-- of. Nothing below needs this one, so nothing below should carry it.
do
  local unpack_args = table.unpack or unpack

  -- @param name string the `_G.__lain` entry point to call
  -- @param args table its arguments, in the order the entry point declares them
  function _G.__lain.dispatch(name, args)
    local entry = _G.__lain[name]
    if type(entry) ~= "function" then
      error(("lain: this runtime has no entry point named %q"):format(tostring(name)), 0)
    end
    return entry(unpack_args(args, 1, #args))
  end
end
