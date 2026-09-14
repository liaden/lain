# frozen_string_literal: true

# `runtime/99_attach.lua` -- the surface a human's own config attaches to, and the
# last chunk to load so that everything it announces already exists. User
# LainAttach carries the protocol and the buffer list; User LainRender fires per
# named view; `b:lain_view` marks every lain:// buffer.
#
# Observed through a SECOND connection, and through a recorder installed BEFORE
# the frontend attaches, because the claim is what a stranger's autocmd sees --
# not what the frontend believes it sent.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-attach-spec") { example.run } }

  describe "user autocmds get a stable surface" do
    it "fires User LainAttach and User LainRender with buffer names in the payload" do
      install_recorder
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { seen["LainAttach"].any? && seen["LainRender"].any? }

        attach = seen["LainAttach"].first
        expect(attach["protocol"]).to eq(described_class.protocol)
        expect(attach["buffers"]).to match_array(all_views)

        # Priming posts every view at attach, so each named buffer announces
        # its own render, name in the payload.
        rendered = wait_until_editor do
          names = seen["LainRender"].map { |data| data["name"] }
          names if (all_views - names).empty?
        end
        expect(rendered).to include(*all_views)
      end
    end

    it "sets b:lain_view on every lain:// buffer" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        views = wait_until_editor do
          found = inspector.exec_lua(<<~LUA, [])
            local out = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              local name = vim.api.nvim_buf_get_name(buf)
              if name:match("^lain://") then out[name] = vim.b[buf].lain_view end
            end
            return out
          LUA
          found if found.size == primed_views.size && found.values.none?(&:nil?)
        end

        expect(views.keys).to match_array(primed_views)
        views.each { |name, view| expect(view).to eq(name) }
      end
    end

    # Panel probe G: the advertised dispatch pattern is
    #   autocmd FileType lain -> read vim.b.lain_view
    # and setting 'filetype' fires FileType SYNCHRONOUSLY, so the claim must
    # land BEFORE the filetype assignment in the buffer constructors -- a
    # claim after it leaves every FileType callback reading nil.
    it "sets b:lain_view before the FileType autocmd fires" do
      inspector.exec_lua(<<~LUA, [])
        _G.__ft_views = {}
        vim.api.nvim_create_autocmd("FileType", {
          pattern = "lain",
          callback = function(ev)
            table.insert(_G.__ft_views, vim.b[ev.buf].lain_view or "NIL-AT-FILETYPE-TIME")
          end,
        })
        return true
      LUA
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # The four "lain"-filetype buffers: journal, timeline, workspace, inbox.
        views = wait_until_editor do
          found = inspector.exec_lua("return _G.__ft_views", [])
          found if found.size >= 4
        end
        expect(views).to all(start_with("lain://"))
      end
    end
  end

  # What is on SCREEN at attach, which since the approval prime is one more than
  # the set above: lain://approval is primed by Surfaces#prime but is deliberately
  # NOT in the runtime's BUFFERS table, because that table is the User LainAttach
  # payload a human's config iterates and the runtime creates this buffer itself.
  # It carries zero rows, so it takes no window.
  def primed_views = all_views + [Lain::Frontend::Neovim::ApprovalView::BUFFER]
end
