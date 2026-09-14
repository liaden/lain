# frozen_string_literal: true

# `runtime/20_buffers.lua` -- the shared `lain` filetype and its syntax. The six
# documented lain* groups have to be live on a REAL buffer in a REAL editor: a
# `syntax match` that does not compile is a runtime error nvim swallows, so
# reading the pattern back out of the Lua source would pass over a filetype that
# highlights nothing.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-buffers-spec") { example.run } }

  describe "richer highlighting" do
    it "links all six documented lain* groups and defines their matches on lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }

        links = group_links
        syntax_groups.each { |group| expect(links.fetch(group)).to be_a(String), "#{group} is not linked" }

        # The matches attach to the "lain" filetype buffers (timeline here).
        defined = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://timeline")
          return vim.api.nvim_buf_call(buf, function()
            return vim.fn.execute("syntax list")
          end)
        LUA
        syntax_groups.each { |group| expect(defined).to include(group) }
      end
    end

    # `highlight default link`'s observable contract (nvim_get_hl does not
    # surface the default flag): a link the human's config already made wins;
    # the runtime's defaults must never clobber it.
    it "yields to a user's pre-existing links for every group" do
      syntax_groups.each { |group| inspector.command("highlight link #{group} ErrorMsg") }
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://timeline").any? }
        group_links.each { |group, link| expect(link).to eq("ErrorMsg"), "#{group} was clobbered (links to #{link})" }
      end
    end
  end

  def group_links
    inspector.exec_lua(<<~LUA, [syntax_groups])
      local groups = ...
      local out = {}
      for _, group in ipairs(groups) do
        out[group] = vim.api.nvim_get_hl(0, { name = group }).link
      end
      return out
    LUA
  end
end
