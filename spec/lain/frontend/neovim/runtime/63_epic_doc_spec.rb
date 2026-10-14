# frozen_string_literal: true

# `runtime/63_epic_doc.lua` -- an epic document drawn read-only beside the
# human's window, without moving the cursor.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-epic-doc-spec") { example.run } }

  def set_epic_doc(name, lines)
    inspector.exec_lua("_G.__lain.set_epic_doc(...)", [name, lines])
  end

  def state_of(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      return {
        filetype = vim.bo[buf].filetype,
        modifiable = vim.bo[buf].modifiable,
        windows = #vim.fn.win_findbuf(buf),
        total_windows = #vim.api.nvim_list_wins(),
        current_is_human = vim.api.nvim_get_current_buf() == vim.g.human_buf,
      }
    LUA
  end

  it "opens research.md read-only in a split while the cursor stays in the human's buffer" do
    frontend = described_class.new(channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      inspector.exec_lua("vim.g.human_buf = vim.api.nvim_get_current_buf()", [])
      name = "lain://epic/frugirl/research.md"

      set_epic_doc(name, ["# Research", "findings"])
      wait_until_editor { buffer_lines(name) == ["# Research", "findings"] }

      state = state_of(name)
      expect(state).to include("filetype" => "markdown", "modifiable" => false, "windows" => 1,
                               "current_is_human" => true)
    end
  end

  it "refreshes the same buffer in place on a second write without opening another window" do
    frontend = described_class.new(channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      name = "lain://epic/frugirl/research.md"
      set_epic_doc(name, ["old"])
      wait_until_editor { buffer_lines(name) == ["old"] }
      before = state_of(name)

      set_epic_doc(name, %w[new text])
      wait_until_editor { buffer_lines(name) == %w[new text] }

      expect(state_of(name)).to include("windows" => 1, "total_windows" => before["total_windows"])
    end
  end

  it "names an issue plan by its home path" do
    frontend = described_class.new(channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      set_epic_doc("lain://epic/frugirl/plans/a1.md", ["# plan"])

      wait_until_editor { buffer_lines("lain://epic/frugirl/plans/a1.md") == ["# plan"] }
    end
  end
end
