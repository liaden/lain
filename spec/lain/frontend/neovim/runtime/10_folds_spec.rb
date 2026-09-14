# frozen_string_literal: true

# `runtime/10_folds.lua` -- `foldexpr` and `foldtext` over the records
# `05_records.lua` writes, read back from a real editor because a foldexpr is
# only ever right about a buffer nvim has actually folded.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-folds-spec") { example.run } }

  describe "folds" do
    let(:turns) { ["user: hi", "assistant: hello there", "user: and then?", "assistant: done"] }

    it "installs the foldexpr surface on record-shaped lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        display("lain://timeline")

        options = wait_until_editor do
          opts = window_fold_options
          opts if opts["method"] == "expr"
        end
        expect(options["expr"]).to include("__lain.foldexpr")
        expect(options["text"]).to include("__lain.foldtext")
      end
    end

    # The amended contract: the older-closed/newest-open DEFAULT applies once,
    # at first display; a render may at most re-open the newest record. The
    # editor itself preserves per-fold open/closed state across a whole-buffer
    # replace (panel probe I), so preservation -- not re-defaulting -- is what
    # a render must exhibit.
    it "defaults once at display, then preserves fold state across re-renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until_editor { fold_closes(4) == [1, 2, 3, -1] }

        # A new turn arrives open; the closed older turns stay closed, the
        # previously-open turn stays open -- no forced re-close.
        render_timeline(turns + ["user: one more"])
        wait_until_editor { fold_closes(5) == [1, 2, 3, -1, -1] }
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to match(/E\d+/)
      end
    end

    # Panel probe H: a turn the human opened by hand must survive the agent's
    # next render -- the stomp this fix round exists to kill.
    it "keeps a manually opened turn open across a re-render" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until_editor { fold_closes(4) == [1, 2, 3, -1] }

        fold_open_at(2)
        wait_until_editor { fold_closes(4) == [1, -1, 3, -1] }

        render_timeline(turns + ["user: one more"])
        wait_until_editor { fold_closes(5) == [1, -1, 3, -1, -1] }
      end
    end

    # Probe H's zR case: opening everything is a foldlevel statement, and a
    # render must not write foldlevel back down.
    it "lets zR stick across renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until_editor { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.cmd('normal! zR'); return true", [])
        render_timeline(turns + ["user: one more"])
        wait_until_editor { buffer_lines("lain://timeline").size == 5 }
        expect(inspector.exec_lua("return vim.wo.foldlevel", [])).to be >= 1
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "groups journal lines by attribution run and preserves runs across appends" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "a\nb"))
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t2", stream: :stdout, bytes: "c\nd"))
        wait_until_editor { buffer_lines("lain://journal").size == 4 }
        display("lain://journal")

        # One fold per [id stream] run: t1's two lines closed together, t2's open.
        wait_until_editor { fold_closes(4) == [1, 1, -1, -1] }

        # An append never re-closes what the display state holds (probe H).
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t3", stream: :stdout, bytes: "e"))
        wait_until_editor { buffer_lines("lain://journal").size == 5 && fold_closes(5) == [1, 1, -1, -1, -1] }
      end
    end

    # Panel probe J: window-local fold options are sticky per window -- when
    # the human navigates the window away to a normal buffer, lain's expr
    # surface must not ride along and flatten their own folds. The :vsplit is
    # the probe's sharpest case: a split copies window OPTIONS but NOT window
    # VARIABLES, so the new window carries lain's foldexpr with no saved
    # prior options -- an orphaned surface that must self-heal on leave.
    it "restores the window's prior fold options when it leaves the lain view, split windows included" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until_editor { window_fold_options["method"] == "expr" }

        options = inspector.exec_lua(<<~LUA, [])
          vim.cmd("vsplit")
          local buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def outer", "  a = 1", "end" })
          vim.api.nvim_win_set_buf(0, buf)
          return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr }
        LUA

        expect(options["method"]).to eq("manual")
        expect(options["expr"]).not_to include("__lain")
      end
    end

    # Panel probe I: the kill switch must un-install LIVE -- flipping
    # vim.g.lain_fold mid-session restores the window and drops lain's folds
    # on the next fold event, not merely at the next fresh display.
    it "un-installs live when vim.g.lain_fold flips to false mid-session" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until_editor { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        render_timeline(turns + ["user: one more"])

        wait_until_editor { window_fold_options["method"] == "manual" }
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "stays hands-off when vim.g.lain_fold is false" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        display("lain://timeline")
        render_timeline(turns)

        wait_until_editor { buffer_lines("lain://timeline") == turns }
        expect(window_fold_options["method"]).to eq("manual")
        expect(fold_closes(4)).to eq([-1, -1, -1, -1])
      end
    end
  end

  # The operational half of
  # `spec/refusal_delivery_discipline_spec.rb`. `define`
  # (`runtime/30_commands.lua:8-11`) does not rescue -- its only `pcall` guards
  # the idempotent delete -- so an `error()` inside a user-command callback
  # escapes into nvim, which appends its own `stack traceback:` and, with a UI
  # attached, raises the hit-enter prompt the block above measures. Behind that
  # prompt every non-fast RPC request queues, so the editor answers nothing at
  # all while a refusal naming the recovery is on screen. An earlier QA round
  # fixed that at `:LainNoteDone`; a later one found the same defect at
  # `:LainNote`, and `:LainReviewMark` and `:LainAnnotate` carried it too.
  #
  # THE OTHER DOOR IS `vim.notify`, and it reaches the same prompt by WIDTH
  # rather than by a raise -- `51_thread.lua` carries the measurement, roughly
  # `#sentence + 12 > columns`. Six such refusals were converted with the
  # raising ones, so the last example here drives one of those instead.
  #
  # THE UI ATTACH IS LOAD-BEARING for the reason the width block records:
  # measured on nvim 0.12, with no UI attached nvim never raises the prompt, so
  # a headless assertion here would be a pass taken over nothing. TYPED rather
  # than sent for the neighbouring reason -- an error escaping an
  # `nvim_exec_lua` NOTIFY is dropped on the floor, and only keys fed to the
  # main loop put a callback's failure where a human sees it.

  # Show a lain:// buffer in the (sole headless) window -- what a human's
  # :buffer lain://timeline does -- so the window-local fold surface applies.
  def display(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      vim.api.nvim_win_set_buf(0, buf)
      return buf
    LUA
  end

  # foldclosed() per line in the displaying window: -1 for open, else the
  # closed fold's first line -- the observable the fold examples assert on.
  def fold_closes(count)
    inspector.exec_lua(<<~LUA, [count])
      local count, out = ..., {}
      for lnum = 1, count do out[lnum] = vim.fn.foldclosed(lnum) end
      return out
    LUA
  end

  def fold_open_at(line)
    inspector.exec_lua(<<~LUA, [line])
      local line = ...
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.cmd("silent! foldopen!")
      return true
    LUA
  end

  def window_fold_options
    inspector.exec_lua("return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr, text = vim.wo.foldtext }", [])
  end

  def render_timeline(lines)
    inspector.exec_lua("local lines = ...; _G.__lain.set_view('lain://timeline', lines); return true", [lines])
  end
end
