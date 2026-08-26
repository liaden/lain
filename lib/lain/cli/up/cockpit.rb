# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Lain
  module CLI
    class Up
      # The planning half of `lain up --nvim`: the shared socket and the nvim
      # pane's command. The socket is computed ONCE here and handed to both
      # panes explicitly, so agreement is by construction rather than two sides
      # re-deriving the convention. `option` is the resolved answer to two
      # flags, not the spelling of either: nil is `--no-nvim`, "" derives the
      # plugin's deterministic socket, a non-empty String is used verbatim.
      class Cockpit
        # A relative socket resolves against each pane's own directory, so
        # requiring an absolute path is the rule rather than a formatting
        # preference -- the socket is the ONE name the editor and the chat must
        # agree on.
        #
        # It also refuses a Thor quirk exactly, without knowing about Thor: a
        # BARE `--nvim-socket` makes Thor supply the flag's own name, so the
        # cockpit would listen on a relative file called `nvim_socket`.
        # Comparing against the flag's name would be a heuristic; "not an
        # absolute path" is the rule the socket needs anyway.
        class UnusableSocket < Error
          def initialize(option)
            super("--nvim-socket #{option.inspect} is not an absolute path -- the nvim socket is the one " \
                  "name the editor pane and the chat pane must agree on, and a relative one resolves " \
                  "against whichever pane reads it. Write `--nvim-socket=/path/to.sock`, or leave the " \
                  "flag off to use the per-project socket lain derives.")
          end
        end

        def initialize(option:, cwd:, paths:)
          @option = option
          @cwd = cwd
          @paths = paths
        end

        # {Up} pins BOTH panes here with tmux's own -c: the cockpit's one silent
        # failure mode is the panes disagreeing about the project directory, so
        # the socket hash and the panes' cwd come from this one captured value
        # rather than from default-path inheritance.
        attr_reader :cwd

        def requested? = !@option.nil?

        # The whole of the layout wiring: `:LainStart` lays out now if lain has
        # attached, else arms a one-shot so the views open when the sibling
        # pane's `chat --nvim` lands. The rtp injection through `--cmd` is
        # evaluated before nvim sources rtp `plugin/` files, which is what makes
        # `:LainStart` exist with zero user config.
        #
        # THE SHAPE IS FORCED twice over, both halves measured on 2026-08-05
        # against nvim 0.12.4:
        #
        # 1. NOT `if exists(':LainStart') | LainStart | endif`, the idiom this
        #    wants: `-c` takes ONE Ex command, so every bar-chained form dies on
        #    `E488: Trailing characters` at the first bar -- `if|endif`,
        #    `try|endtry`, even `execute`. The cost was total: nvim came up on
        #    the "Press ENTER" prompt, never served its socket, and
        #    `chat --nvim` waited in ep_poll forever.
        # 2. NOT `silent! LainStart`, which fixes that and hides the next fault:
        #    it swallows any error `:LainStart` ITSELF raises, and shipped just
        #    long enough to find a layout that never opened, in silence. The
        #    ternary guards existence instead, so a bare `nvim --listen` is
        #    unharmed and a real failure reaches the screen.
        LAIN_START = "execute exists(':LainStart') ? 'LainStart' : ''"

        # Suppresses the user's start screen, which would otherwise cover the
        # cockpit until the first view arrives: a dashboard plugin draws over
        # exactly the empty unnamed buffer nvim boots into, and the cockpit's
        # nvim boots into nothing by design.
        #
        # NAMING the buffer is what trips snacks' own guard, measured against
        # nvim 0.12.4: it bails with reason "buffer has a name". The
        # neighbouring `argc(-1) > 0` guard looks more portable and is wrong
        # here -- the only argument worth passing is the project directory, and
        # snacks RE-enables the dashboard for a lone directory argument when its
        # explorer is on.
        #
        # Scheme-shaped so `:file` leaves it alone: a bare word is taken as a
        # relative filename and expanded against the cwd, which showed up as a
        # buffer named for a path in the project that nobody could open.
        #
        # `lain-cockpit://`, NOT `lain://`: init.lua's fallback scan treats
        # every `lain://` buffer as layout-eligible, and this is a placeholder
        # the runtime never created.
        SCRATCH_BUFFER = "file lain-cockpit://start"

        def nvim_pane_command
          Shellwords.join(["nvim", *rtp_flag, "--listen", socket, "-c", SCRATCH_BUFFER, "-c", LAIN_START])
        end

        def chat_flags = ["--nvim", socket]

        # EMPTY IS THE DERIVE SENTINEL, deliberately: `--nvim-socket ""` is an
        # empty shell variable, and "an empty flag means no flag" is the reading
        # `--root` already takes. Anything else must be ABSOLUTE -- see
        # {UnusableSocket}.
        def socket
          @socket ||= begin
            raise UnusableSocket, @option unless @option.empty? || @option.start_with?(File::SEPARATOR)

            @option.empty? ? derived_socket : @option
          end
        end

        # The degrade case: the shipped plugin cannot be located. The cockpit
        # still opens either way -- see {#rtp_flag}.
        def plugin_missing? = !Dir.exist?(@paths.nvim_plugin_root)

        def nvim_plugin_root = @paths.nvim_plugin_root

        private

        def rtp_flag
          return [] if plugin_missing?

          ["--cmd", "set rtp+=#{nvim_plugin_root}"]
        end

        # The plugin's own convention byte-for-byte, with `Paths#project_hash`
        # as the Ruby twin of its sha256(getcwd). The 0700 directory is ensured
        # only on THIS derived path: runtime_dir is ours to create, where an
        # explicit --nvim-socket's parent is the caller's.
        def derived_socket
          File.join(@paths.runtime_dir, "nvim-#{@paths.project_hash(@cwd)}.sock").tap do |sock|
            FileUtils.mkdir_p(File.dirname(sock), mode: 0o700)
          end
        end
      end
    end
  end
end
