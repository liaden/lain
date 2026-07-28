# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Lain
  module CLI
    class Up
      # T19's planning half of `lain up --nvim`: the shared socket and the
      # nvim pane's command. The socket is computed ONCE, here, and handed to
      # both panes explicitly ({Up#create_cockpit_session} threads
      # {#chat_flags} into the chat pane) -- agreement is by construction,
      # never two sides re-deriving the convention. `option` is the exe's
      # --resume shape: nil is off, "" (a bare --nvim) derives the plugin's
      # deterministic socket, a non-empty String is used verbatim.
      class Cockpit
        def initialize(option:, cwd:, paths:)
          @option = option
          @cwd = cwd
          @paths = paths
        end

        # {Up} pins BOTH panes to this directory with tmux's own -c: the
        # cockpit's one silent failure mode is the panes disagreeing about the
        # project directory, so the socket hash and the panes' cwd come from
        # the same captured value, never default-path inheritance.
        attr_reader :cwd

        def requested? = !@option.nil?

        # The layout is armed via -c, tmux-keystroke-free: :LainStart (guarded
        # -- the plugin is sugar, a bare nvim must not error) lays out now if
        # attached, else one-shots on LainAttach, so the standard view layout
        # opens the moment the sibling pane's `chat --nvim` lands. T2's rtp
        # injection (`--cmd`, evaluated before nvim sources rtp `plugin/`
        # files -- the same seam `spec/plugin/nvim_plugin_spec.rb`'s
        # `boot_nvim` uses to load the plugin headless) is what makes
        # :LainStart exist with zero user config; the exists() guard is what
        # keeps a bare `nvim --listen` unharmed either way, plugin present or
        # not.
        def nvim_pane_command
          Shellwords.join(["nvim", *rtp_flag, "--listen", socket,
                           "-c", "if exists(':LainStart') | LainStart | endif"])
        end

        def chat_flags = ["--nvim", socket]

        def socket
          @socket ||= @option.empty? ? derived_socket : @option
        end

        # T2 degrade AC: the shipped plugin cannot be located. {Up} probes
        # this once, on the create path only, to report the named warning --
        # the cockpit still opens either way (see {#rtp_flag}).
        def plugin_missing? = !Dir.exist?(@paths.nvim_plugin_root)

        def nvim_plugin_root = @paths.nvim_plugin_root

        private

        def rtp_flag
          return [] if plugin_missing?

          ["--cmd", "set rtp+=#{nvim_plugin_root}"]
        end

        # The plugin's own convention, byte-for-byte ($XDG_RUNTIME_DIR/lain/
        # nvim-<sha256(cwd)[:12]>.sock -- Paths#project_hash is the Ruby twin
        # of its sha256(getcwd)). The directory is ensured (0700, matching the
        # plugin's own mkdir) only on THIS derived path: runtime_dir is ours
        # to create, an explicit --nvim SOCKET's parent is the caller's.
        def derived_socket
          File.join(@paths.runtime_dir, "nvim-#{@paths.project_hash(@cwd)}.sock").tap do |sock|
            FileUtils.mkdir_p(File.dirname(sock), mode: 0o700)
          end
        end
      end
    end
  end
end
