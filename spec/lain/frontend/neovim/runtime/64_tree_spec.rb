# frozen_string_literal: true

# `runtime/64_tree.lua` -- the gestures of lain://tree: <CR> rewinds to the turn under the cursor and L labels
# it. What is asserted is the verb and arguments each key puts on the editor's command rail.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-tree-spec") { example.run } }

  # Primed at attach, so the buffer already exists and only needs lines worth a cursor.
  def open_tree
    wait_until_editor { buffer_lines("lain://tree") == ["(no turns yet)"] }
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://tree")
      vim.b[buf].lain_view_generation = 7
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user: one", "assistant: two", "user: three" })
    LUA
  end

  it "sends the cursor line on <CR>" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      press("lain://tree", "<CR>", cursor: [2, 0])

      expect(next_command(frontend)).to eq(["tree_rewind", [2, 7]])
    end
  end

  it "sends the cursor line and the typed text on L" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      press("lain://tree", "Lidea 2<CR>", cursor: [3, 0])

      expect(next_command(frontend)).to eq(["tree_label", [3, "idea 2", 7]])
    end
  end

  it "sends the generation the buffer had when L was pressed, not the one it has when the prompt answers" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      inspector.exec_lua("vim.ui.input = function(_, callback) _G.held_prompt = callback end", [])
      press("lain://tree", "L", cursor: [3, 0])
      inspector.exec_lua("vim.b[vim.fn.bufnr('lain://tree')].lain_view_generation = 8; _G.held_prompt('late')", [])

      expect(next_command(frontend)).to eq(["tree_label", [3, "late", 7]])
    end
  end

  it "sends nothing when the prompt is cancelled, so the next command on the rail is the next gesture" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      inspector.exec_lua("vim.ui.input = function(_, callback) callback(nil) end", [])
      press("lain://tree", "L", cursor: [3, 0])
      press("lain://tree", "<CR>", cursor: [1, 0])

      expect(next_command(frontend)).to eq(["tree_rewind", [1, 7]])
    end
  end

  it "sends the refresh verb with no arguments on :LainTreeRefresh" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      press("lain://tree", ":LainTreeRefresh<CR>")

      expect(next_command(frontend)).to eq(["tree_refresh", []])
    end
  end

  it "refuses :LainTreeRefresh off the tree buffer, without a traceback, and sends nothing" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      open_tree
      inspector.command("LainTreeRefresh")

      text = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
      expect(text).to include("lain:").and include(":LainTreeRefresh")
      expect(text).not_to include("stack traceback")
      expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
    end
  end
end
