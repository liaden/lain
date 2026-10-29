# frozen_string_literal: true

require "async"

# `runtime/66_notice.lua` -- a sentence that is news and not a refusal. It rides
# the same fitting as the refusal rail, so a UI is attached for the same reason
# (see 65_review_spec.rb): a headless nvim never raises hit-enter.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-notice-spec") { example.run } }

  def attach_ui(columns:)
    inspector.session.request(:nvim_ui_attach, columns, 20, { "rgb" => true, "ext_linegrid" => true })
  end

  def capture_echoes
    inspector.exec_lua(<<~LUA, [])
      _G.echoed = {}
      local real = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(_G.echoed, { chunks = chunks, history = history })
        return real(chunks, history, opts)
      end
      return true
    LUA
  end

  def echoed = inspector.exec_lua("return _G.echoed", [])

  def mode_after(sentence)
    inspector.session.notify(:nvim_exec_lua, "_G.__lain.notice(...)", [sentence])
    sleep 0.3
    inspector.session.request(:nvim_get_mode)
  ensure
    inspector.session.request(:nvim_input, "\r")
  end

  it "echoes the sentence prefixed, in the Normal highlight, and records it" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      attach_ui(columns: 110)
      capture_echoes

      shown = inspector.exec_lua("return _G.__lain.notice(...)", ["done in 12s, 3 turns"])

      expect(shown).to eq("lain: done in 12s, 3 turns")
      expect(echoed).to eq([{ "chunks" => [["lain: done in 12s, 3 turns", "Normal"]], "history" => true }])
    end
  end

  it "does not raise a hit-enter prompt for a sentence wider than the message area" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      attach_ui(columns: 60)

      expect(mode_after("done #{"and still going " * 12}end")).to include("blocking" => false)
    end
  end

  it "fits a wide sentence to the message area, keeping both ends" do
    frontend = described_class.new(forks: no_forks, channel:, socket_path: @socket)

    frontend.run do
      attach_ui(columns: 60)
      sentence = "done #{"and still going " * 12}end"

      shown = inspector.exec_lua("return _G.__lain.notice(...)", [sentence])

      expect(shown).to start_with("lain: done").and end_with("end").and include(" ... ")
      expect(inspector.exec_lua("return vim.fn.strdisplaywidth(...)", [shown]))
        .to be <= inspector.evaluate("v:echospace")
    end
  end
end
