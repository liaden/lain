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
        # A `--nvim` that ate the first chat flag. Its own class because the
        # answer is a sentence about argv, not about tmux -- see {#socket}.
        class SwallowedFlag < Error; end

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

        # The one Ex command the cockpit's nvim runs at startup, and the whole
        # of the layout wiring: `:LainStart` lays out now if lain has attached,
        # else arms a one-shot so the views open when the sibling pane's
        # `chat --nvim` lands. T2's rtp injection (`--cmd`, evaluated before
        # nvim sources rtp `plugin/` files -- the same seam
        # `spec/plugin/nvim_plugin_spec.rb`'s `boot_nvim` uses) is what makes
        # `:LainStart` exist with zero user config.
        #
        # THE SHAPE IS FORCED, twice over, and both halves were measured on
        # 2026-08-05 against nvim 0.12.4:
        #
        # 1. NOT `if exists(':LainStart') | LainStart | endif`, the idiom this
        #    wants: `-c` takes ONE Ex command, so every bar-chained form dies on
        #    `E488: Trailing characters` at the first `|` -- `if|endif`,
        #    `try|endtry`, even `execute "...|..."`. The cost was total, not
        #    cosmetic: nvim came up on the "Press ENTER" prompt, never served
        #    its socket, and `chat --nvim` waited in ep_poll forever.
        # 2. NOT `silent! LainStart`, which fixes that and then hides the next
        #    fault: `silent!` swallows any error `:LainStart` ITSELF raises. It
        #    shipped for exactly as long as it took to find a layout that never
        #    opened, in silence. The ternary guards existence -- a bare
        #    `nvim --listen` is unharmed, plugin present or not -- and lets a
        #    real failure reach the screen.
        LAIN_START = "execute exists(':LainStart') ? 'LainStart' : ''"

        def nvim_pane_command
          Shellwords.join(["nvim", *rtp_flag, "--listen", socket, "-c", LAIN_START])
        end

        def chat_flags = ["--nvim", socket]

        # REFUSES a socket that is really a flag, because `--nvim` takes an
        # OPTIONAL value: written last before `--`, Thor hands it the first
        # chat flag as its socket, so `lain up --nvim -- --provider ollama` --
        # the form the usage line teaches -- listened on a path called
        # `--provider` and the shared socket the cockpit exists to establish
        # silently was not there. Any flag between `--nvim` and `--` hides it,
        # which is why `up_spec` never saw it: it passes an explicit socket.
        def socket
          @socket ||= begin
            raise SwallowedFlag, swallowed_flag_message if @option.start_with?("-")

            @option.empty? ? derived_socket : @option
          end
        end

        # Names the remedy rather than the parser: a human who typed the
        # documented form does not care that Thor treats an optional value
        # greedily, they care which of the two spellings to use instead.
        def swallowed_flag_message
          "--nvim took #{@option.inspect} as its socket, which is a flag, not a path -- an optional-value " \
            "flag swallows the next argument. Write `--nvim=SOCKET` with an explicit path, or move " \
            "`--nvim` before another `up` flag so it is not the last one before `--`."
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
