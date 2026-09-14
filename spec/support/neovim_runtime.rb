# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# What every spec of `runtime.lua` and of a `runtime/*.lua` module needs once
# {HeadlessEditor} has taken the spawn: the contract surface those modules
# publish, the two ways a spec reads an editor's state back, and the recorder a
# human's own config would have installed.
#
# These were file-scope helpers in one 3,612-line spec whose eighteen groups each
# targeted a different Lua module. Once each module had a spec at its own mirror
# path, the helpers were the only thing the old filename had been holding
# together -- so they are here, and `include NeovimRuntime` is the line each of
# those specs begins with.
#
# An {RSpec::SharedContext} rather than a plain module because `channel` is a
# `let`: every one of those specs builds a frontend on a fresh {Lain::Channel},
# and a memoised `def` would be that `let` wearing a worse name.
#
# `wait_until_editor` rather than `wait_until`, and the rename is load-bearing.
# {WaitUntil#wait_until} is included into EVERY example group in this suite and
# means something else: it returns nil rather than the value the condition
# produced, it gives up after 3 seconds rather than 8, and its failure names
# nothing about the editor. A file that forgot this `include` would silently get
# that one and fail somewhere downstream of the reason. Under a distinct name the
# same mistake is a NoMethodError at the call site. It keeps the `wait_until`
# PREFIX deliberately: `.rubocop.yml` allowlists that prefix for
# `RSpec/NoExpectationExample`, because a helper that raises at its deadline IS
# the assertion in the examples that make no other -- and a name outside the
# prefix would have bought this rename an edit in a shared config file.
module NeovimRuntime
  extend RSpec::SharedContext

  let(:channel) { Lain::Channel.new }

  # Every buffer the runtime owns -- the contract surface these specs pin.
  def all_views
    %w[lain://journal lain://timeline lain://workspace lain://diff lain://inbox lain://request lain://status]
  end

  # The six documented lain* groups: tool attribution, digests,
  # roles, event kinds, ages, sender attribution.
  def syntax_groups
    %w[lainToolName lainDigest lainRole lainEventKind lainAge lainSender]
  end

  # The failure NAMES the buffers the editor actually has. A bare "timed out"
  # is unreadable when the cause is a buffer that was never created or was
  # created under the wrong name (E32 territory) -- the panel broke
  # nvim_buf_set_name deliberately and got three identical mystery timeouts.
  def wait_until_editor(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state; nvim has #{live_buffer_names.inspect}" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  def live_buffer_names
    inspector.exec_lua("return vim.tbl_map(vim.api.nvim_buf_get_name, vim.api.nvim_list_bufs())", [])
  rescue StandardError => e
    "unreadable (#{e.class})"
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  # Record every User LainAttach / LainRender payload BEFORE the frontend
  # attaches, exactly as a human's config would from their own dotfiles.
  def install_recorder
    inspector.exec_lua(<<~LUA, [])
      _G.__seen = { LainAttach = {}, LainRender = {} }
      for pattern, log in pairs(_G.__seen) do
        vim.api.nvim_create_autocmd("User", {
          pattern = pattern,
          callback = function(ev) table.insert(log, ev.data) end,
        })
      end
      return true
    LUA
  end

  def seen
    inspector.exec_lua("return _G.__seen", [])
  end

  # Feeds keys through nvim's OWN mapping resolution (feedkeys, never
  # `:normal!`, which bypasses mappings) so the buffer-local map is what runs.
  #
  # `"x"` is what makes the keys land BEFORE this returns, which is the whole of
  # why an example may look straight at the result: a map that fires a blocking
  # `rpcrequest` has already been answered by the frontend's RPC thread by the
  # time the next line runs, so there is nothing to wait for and no race to lose.
  def press(bufname, keys, cursor: [])
    inspector.exec_lua(<<~LUA, [bufname, keys, cursor])
      local bufname, keys, cursor = ...
      vim.cmd("buffer " .. bufname)
      if cursor[1] then
        vim.api.nvim_win_set_cursor(0, cursor)
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    LUA
  end

  def next_command(frontend)
    wait_until_editor do
      frontend.command_inbox.pop(true)
    rescue ThreadError
      nil
    end
  end

  # lain://question against a REAL editor. It is `acwrite` for
  # lain://compose's reason -- `:w` IS the submit -- and it is the one lain://
  # buffer whose write can be REFUSED, because the grammar reads the document
  # back BEFORE the ack. nil until the buffer exists at all.
  #
  # expandtab/shiftwidth ride here rather than being assumed: the comment slot
  # is two-space-indented prose and {Question::Document} refuses a tab-indented
  # line BY NAME rather than dedenting it, so a human whose own config indents
  # with tabs would write a comment the grammar then rejects on `:w`.
  def question_state
    inspector.exec_lua(<<~LUA, %w[buftype filetype modifiable modified expandtab shiftwidth])
      local buf, out = vim.fn.bufnr("lain://question"), {}
      if buf == -1 then return nil end
      for _, option in ipairs({ ... }) do out[option] = vim.bo[buf][option] end
      out.name = vim.api.nvim_buf_get_name(buf)
      out.lain_view = vim.b[buf].lain_view
      out.digest = vim.b[buf].lain_question_digest
      return out
    LUA
  end

  def null_tty
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new, input: StringIO.new,
                            history_path: File.join(Dir.tmpdir, "lain-open-gesture-history"))
  end

  # The production consumer, wired the way `Repl#run` wires it -- the rail AND
  # the view set its gestures resolve through -- running for the block's
  # duration and stopped in an ensure.
  #
  # IT RUNS ON ITS OWN THREAD, AND THE INSPECTOR MUST NOT: the neovim gem
  # decides "block on the socket" vs "yield the fiber" by comparing
  # `Fiber.current` against the fiber that BUILT the session
  # (neovim-0.10.0/lib/neovim/session.rb:24,59). A gem call issued from inside
  # an Async task therefore takes the yielding branch and tries to `Fiber.yield`
  # across a fiber ASYNC owns, which on ruby 4.0.6 / async 2.42 RAISES
  # `FiberError` rather than parking. `FiberError < StandardError`, so it is
  # swallowed and retried: measured while writing this example, 7m28s for one
  # example with both processes idle at ~0% CPU. (Two earlier diagnoses of that
  # run -- a mutex cycle across the RPC boundary, then a parked reactor sitting
  # in epoll -- were both WRONG, and are recorded here only so neither is
  # rediscovered as an explanation.) It
  # is a harness hazard only; production's consumer never calls nvim (it pushes
  # onto the render queue, and the RPC thread owns every nvim call), which is
  # exactly the rule this file exists to hold.
  #
  # Bounded on both ends -- `wait_until_editor` raises at its deadline, the join is
  # capped -- because a hung editor spec is indistinguishable from a slow one,
  # and under parallel_rspec a hung worker reports as "fewer examples, zero
  # failures".
  def with_consumer(frontend)
    stop = Thread::Queue.new
    conductor = instance_double(Lain::CLI::Conductor)
    worker = Thread.new { serve_editor(frontend, conductor, stop) }
    yield
  ensure
    stop.close
    raise "the editor consumer thread never stopped" unless worker.join(5)
  end

  def serve_editor(frontend, conductor, stop)
    Sync do |task|
      replies = Lain::CLI::HumanReplies.new(tty: null_tty, conductor:,
                                            ask_human: Lain::Tools::AskHuman::Directory.new,
                                            questions: Async::Queue.new)
      replies.bind_editor(frontend.command_inbox, views: frontend.buffers)
      # session_surfaces: the editor rail is the conversation's.
      surfaces = replies.session_surfaces(task)
      pumped_until(task, reason: "the stop channel closing") { stop.closed? }
      surfaces.each(&:stop)
    end
  end
end
