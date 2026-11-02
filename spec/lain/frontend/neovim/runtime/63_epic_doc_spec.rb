# frozen_string_literal: true

# `runtime/63_epic_doc.lua` -- an epic document drawn read-only in the planning
# tab's main window, beside the roadmap sidebar, without moving the human.
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
        current_tab = vim.api.nvim_get_current_tabpage(),
        tabs = #vim.api.nvim_list_tabpages(),
      }
    LUA
  end

  def session_windows
    inspector.exec_lua("return #vim.api.nvim_tabpage_list_wins(vim.g.human_tab)", [])
  end

  def planning_windows
    inspector.exec_lua(<<~LUA, [])
      local tab = _G.__lain_planning_tab()
      return tab and #vim.api.nvim_tabpage_list_wins(tab) or 0
    LUA
  end

  def main_window_buffer_name
    inspector.exec_lua(<<~LUA, [])
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[2])) do
        if vim.w[win].lain_slot == "main" then
          return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        end
      end
    LUA
  end

  def remember_human
    inspector.exec_lua(<<~LUA, [])
      vim.g.human_buf = vim.api.nvim_get_current_buf()
      vim.g.human_tab = vim.api.nvim_get_current_tabpage()
      _G.__lain_planning_tab = function()
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          if vim.t[tab].lain_planning then
            return tab
          end
        end
      end
    LUA
  end

  it "opens research.md read-only in the planning tab while the human stays in the session tab" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      remember_human
      name = "lain://epic/frugirl/research.md"

      set_epic_doc(name, ["# Research", "findings"])
      wait_until_editor { buffer_lines(name) == ["# Research", "findings"] }

      state = state_of(name)
      expect(state).to include("filetype" => "markdown", "modifiable" => false, "windows" => 1,
                               "current_is_human" => true, "tabs" => 2)
      expect(state["current_tab"]).to eq(inspector.exec_lua("return vim.g.human_tab", []))
    end
  end

  it "opens no window in the human's tab for 33 issue writes, and the planning tab keeps 2" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      remember_human
      before = session_windows

      set_epic_doc("lain://epic/demo/epic.md", ["# demo"])
      33.times { |n| set_epic_doc("lain://epic/demo/issues/i#{n}.md", ["# i#{n}"]) }
      wait_until_editor { buffer_lines("lain://epic/demo/issues/i32.md") == ["# i32"] }

      expect(session_windows).to eq(before)
      expect(planning_windows).to eq(2)
      expect(state_of("lain://epic/demo/epic.md")["tabs"]).to eq(2)
    end
  end

  def roadmap(*ids)
    rows = ids.map { |id| "[ ] `#{id}` the #{id} issue -- issue_plan, draft" }
    inspector.exec_lua("_G.__lain.set_view(...)", ["lain://planning", ["# roadmap", "", *rows]])
    wait_until_editor { buffer_lines("lain://planning").size == rows.size + 2 }
  end

  def press_enter_on(line)
    inspector.exec_lua(<<~LUA, [line])
      local sidebar = vim.fn.win_findbuf(vim.fn.bufnr("lain://planning"))[1]
      vim.api.nvim_win_set_cursor(sidebar, { ..., 0 })
      vim.api.nvim_win_call(sidebar, function() _G.__lain.planning_open() end)
    LUA
  end

  it "opens the issue under the cursor in the planning tab's main window on enter" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      remember_human
      set_epic_doc("lain://epic/demo/issues/a.md", ["# a"])
      set_epic_doc("lain://epic/demo/issues/b.md", ["# b"])
      roadmap("a", "b")
      expect(main_window_buffer_name).to eq("lain://epic/demo/issues/b.md")

      press_enter_on(3)

      expect(main_window_buffer_name).to eq("lain://epic/demo/issues/a.md")
    end
  end

  it "says so, and leaves the main window alone, for an issue with no document yet" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      remember_human
      set_epic_doc("lain://epic/demo/issues/a.md", ["# a"])
      roadmap("a", "c")

      press_enter_on(4)

      expect(inspector.exec_lua("return vim.fn.execute('messages')", [])).to include("issue c has no document")
      expect(main_window_buffer_name).to eq("lain://epic/demo/issues/a.md")
    end
  end

  it "puts a closed roadmap window back on the next render, and marks the buffer for the lain filetype" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      wait_until_editor { buffer_lines("lain://status").any? }
      remember_human
      set_epic_doc("lain://epic/demo/issues/a.md", ["# a"])
      inspector.exec_lua(<<~LUA, [])
        for _, win in ipairs(vim.fn.win_findbuf(vim.fn.bufnr("lain://planning"))) do
          vim.api.nvim_win_close(win, true)
        end
      LUA

      roadmap("a")

      shown = inspector.exec_lua("return #vim.fn.win_findbuf(vim.fn.bufnr('lain://planning'))", [])
      expect(shown).to eq(1)
      expect(inspector.exec_lua("return vim.bo[vim.fn.bufnr('lain://planning')].filetype", [])).to eq("lain")
    end
  end

  it "refreshes the same buffer in place on a second write without opening another window" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

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
end
