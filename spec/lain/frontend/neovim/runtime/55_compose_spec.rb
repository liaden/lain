# frozen_string_literal: true

require "timeout"

# `runtime/55_compose.lua` -- the composing buffer the human types a reply into,
# and what the editor announces about it on the way through.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-compose-spec") { example.run } }

  describe "the compose round trip" do
    let(:compose) { frontend.compose }
    let(:frontend) { described_class.new(channel:, socket_path: @socket) }

    it "opens the current draft in a writable, named lain://compose buffer" do
      frontend.run do
        wait_until_editor { buffer_lines("lain://journal").any? }
        expect(compose.open("draft text")).to eq(compose.marker)

        state = wait_until_editor { compose_state }
        expect(buffer_lines("lain://compose")).to eq(["draft text"])
        expect(state["name"]).to eq("lain://compose")
        # E382 (nofile refuses :write, so BufWriteCmd never fires) and E32 (an
        # unnamed acwrite buffer) are the two ways this setup goes wrong.
        expect(state["buftype"]).to eq("acwrite")
        expect(state["modifiable"]).to be(true)
        expect(state["modified"]).to be(false)
        expect(state["lain_view"]).to eq("lain://compose")
        expect(state["generation"]).to eq(1)
      end
    end

    it "returns the edited text to the prompt when the buffer is written" do
      frontend.run do
        compose.open("draft text")
        wait_until_editor { compose_state }

        edit_compose(["edited text", "second line"])
        # include, not `["ok"]).to be(true)`: on failure this prints nvim's own
        # message (E382 when buftype regresses to nofile) instead of discarding
        # it behind "Expected false to equal true".
        expect(write_compose).to include("ok" => true)

        expect(compose.settle(compose.marker)).to eq("edited text\nsecond line")
        # The write is answered, not persisted: the buffer is clean again so
        # nvim never asks the human about unsaved changes on the way out.
        expect(compose_state["modified"]).to be(false)
      end
    end

    # PANEL BLOCKER 1: unloading the buffer must send NOTHING. The draft is
    # kept for recovery, never dispatched -- the human decided against it.
    it "sends nothing when the buffer is unloaded without being written" do
      frontend.run do
        compose.open("draft text")
        wait_until_editor { compose_state }

        unload_compose

        expect(compose.settle(compose.marker) { :re_prompted }).to eq(:re_prompted)
        expect(compose.draft).to eq("draft text")
      end
    end

    # PANEL BLOCKER 2: clearing 'modified' before the rpcrequest meant a write
    # that never reached lain still looked saved, so nvim would not warn on :q
    # and the text was simply gone. The buffer must stay dirty when the write
    # fails.
    it "leaves the buffer dirty when the write cannot reach lain" do
      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do
        frontend.compose.open("draft")
        wait_until_editor { compose_state }
      end
      # frontend.run has returned: the RPC thread is stopped, the channel gone.

      edit_compose(["text the human typed and thinks is saved"])
      result = write_compose

      expect(result["ok"]).to be(false)
      expect(compose_state).to include("modified" => true)
    end

    # The precise consequence of BLOCKER 2's fix, measured rather than claimed:
    # a failed write leaves the buffer 'modified', so nvim refuses to DISCARD
    # it (E89) -- but plain :q still succeeds, because bufhidden = "hide" makes
    # quitting a window a hide, not an abandon. My first comment here said :q
    # was refused; it is not.
    it "refuses to discard an unsaved compose buffer, though :q still hides it" do
      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do
        frontend.compose.open("draft")
        wait_until_editor { compose_state }
      end

      edit_compose(["text the human typed and thinks is saved"])
      write_compose

      discard = inspector.exec_lua(<<~LUA, [])
        local buf = vim.fn.bufnr("lain://compose")
        local ok, err = pcall(vim.cmd, "bdelete " .. buf)
        return { ok = ok, err = tostring(err) }
      LUA
      expect(discard["ok"]).to be(false)
      expect(discard["err"]).to include("E89")
      expect(compose_state).to include("modified" => true)
    end

    # Panel should-fix: the generation stamped on the buffer is what lets a
    # late answer from an earlier compose be dropped rather than mistaken for
    # this one's.
    it "stamps each compose with its own generation, and reuses the one buffer" do
      frontend.run do
        compose.open("draft A")
        wait_until_editor { compose_state }
        expect(compose_state["generation"]).to eq(1)
        buffers = live_buffer_names

        compose.settle("changed my mind")
        compose.open("draft B")
        wait_until_editor { buffer_lines("lain://compose") == ["draft B"] }

        expect(compose_state["generation"]).to eq(2)
        expect(live_buffer_names).to match_array(buffers)
      end
    end

    # Panel probe: renders and the compose post share ONE queue and ONE thread, so
    # a compose racing a flood of renders must neither reorder nor touch the
    # session off-thread. The compose post is also the only non-blocking push
    # onto that queue, which is exactly what a flood would otherwise stall.
    it "survives a compose posted into a flood of concurrent renders" do
      frontend.run do
        wait_until_editor { buffer_lines("lain://journal").any? }
        flood = Thread.new do
          400.times do |i|
            channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t#{i}", stream: :stdout, bytes: "render #{i}"))
          end
        end
        marker = compose.open("draft under load")
        flood.join

        wait_until_editor { buffer_lines("lain://compose") == ["draft under load"] }
        edit_compose(["answer under load"])
        expect(write_compose).to include("ok" => true)
        expect(Timeout.timeout(10) { compose.settle(marker) }).to eq("answer under load")
      end
    end

    # PANEL P3overlap: the second #open reuses the SAME nvim buffer (found by
    # name), so the first compose's BufUnload never fires and only the
    # generation separates the two round trips.
    it "runs two round trips in a row without crossing their answers" do
      frontend.run do
        %w[A B].each do |round|
          marker = compose.open("draft #{round}")
          wait_until_editor { buffer_lines("lain://compose") == ["draft #{round}"] }
          edit_compose(["answer #{round}"])
          expect(write_compose).to include("ok" => true)
          expect(Timeout.timeout(10) { compose.settle(marker) }).to eq("answer #{round}")
        end
      end
    end

    it "keeps lain://compose out of the primed buffer set, so nothing opens it uninvited" do
      install_recorder

      frontend.run do
        wait_until_editor do
          names = seen["LainRender"].map { |data| data["name"] }
          names if (all_views - names).empty?
        end

        expect(seen["LainAttach"].first["buffers"]).to match_array(all_views)
        expect(compose_state).to be_nil
      end
    end

    # Panel should-fix, recorded rather than defended against: `:wall` and
    # autosave plugins DO fire BufWriteCmd, and the round trip takes that as
    # the human's answer. Pinned so the behaviour is a known limitation rather
    # than a surprise -- lain attaches to the human's own nvim, plugins and all.
    it "settles on a :wall mid-compose, half-typed text and all (known limitation)" do
      frontend.run do
        compose.open("draft")
        wait_until_editor { compose_state }
        edit_compose(["half a thought, still typ"])
        inspector.exec_lua("pcall(function() vim.cmd('wall') end)", [])

        expect(compose.settle(compose.marker)).to eq("half a thought, still typ")
      end
    end

    # The positive half of the same axis: bufhidden=hide plus nvim's default
    # 'hidden' means autowriteall + a buffer switch does NOT fire a write, so
    # the compose is still in flight and the buffer still dirty. Asserted on
    # the EDITOR's state rather than through #settle, which would (correctly)
    # block for the whole bound with no answer to find.
    it "does not settle when autowriteall meets a buffer switch" do
      frontend.run do
        compose.open("draft")
        wait_until_editor { compose_state }
        inspector.exec_lua("vim.o.autowriteall = true", [])
        edit_compose(["half a thought, still typ"])
        inspector.exec_lua(<<~LUA, [])
          vim.api.nvim_buf_call(vim.fn.bufnr("lain://compose"), function()
            vim.cmd("buffer lain://journal")
          end)
        LUA
        sleep 0.3

        expect(compose_state).to include("modified" => true)
        expect(compose).to be_pending
      end
    end
  end

  # The compose round trip against a REAL editor. lain://compose is the
  # one lain:// buffer nvim must be able to `:write`, and the two escalation
  # triggers the card names are both setup errors that show up here as nvim's
  # own E382/E32 -- so the buffer options are asserted, not assumed.
  # nil until the buffer exists at all, which is also how the "nothing opens it
  # uninvited" example asserts its absence.
  def compose_state
    inspector.exec_lua(<<~LUA, %w[buftype modifiable modified])
      local buf, out = vim.fn.bufnr("lain://compose"), {}
      if buf == -1 then return nil end
      for _, option in ipairs({ ... }) do out[option] = vim.bo[buf][option] end
      out.name = vim.api.nvim_buf_get_name(buf)
      out.lain_view = vim.b[buf].lain_view
      out.generation = vim.b[buf].lain_compose_generation
      return out
    LUA
  end

  # `:w` from inside the compose buffer -- the human's own gesture. Returned as
  # the pcall pair so a failing write (E382 on nofile, E32 unnamed) surfaces as
  # its message rather than as a mystery timeout.
  def write_compose
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://compose")
      local ok, err = pcall(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
      end)
      return { ok = ok, err = tostring(err) }
    LUA
  end

  def edit_compose(lines)
    inspector.exec_lua(<<~LUA, [lines])
      local lines = ...
      local buf = vim.fn.bufnr("lain://compose")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return true
    LUA
  end

  def unload_compose
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://compose")
      vim.api.nvim_buf_delete(buf, { force = true })
      return true
    LUA
  end
end
