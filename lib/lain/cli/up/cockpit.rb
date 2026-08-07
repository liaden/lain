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
      # never two sides re-deriving the convention. `option` is the resolved
      # answer to two flags rather than the spelling of either: nil is
      # `--no-nvim`, "" is the cockpit with no `--nvim-socket` (derive the
      # plugin's deterministic socket), a non-empty String is that flag's
      # value, used verbatim.
      class Cockpit
        # A socket that is not a path two panes can both reach. The socket is
        # the ONE name the editor and the chat must agree on, and a relative one
        # is resolved against each pane's own directory -- so requiring it
        # absolute is the rule, not a formatting preference.
        #
        # It also refuses a Thor quirk exactly, without knowing about Thor: a
        # BARE `--nvim-socket` makes Thor supply the flag's own name, so the
        # cockpit would listen on a relative file literally called
        # `nvim_socket`. Recognising that by comparing against the flag's name
        # would be a heuristic; recognising it as "not an absolute path" is the
        # rule the socket needs anyway.
        #
        # The ancestor of this guard was `SwallowedFlag`, which refused a socket
        # beginning with `-` back when `--nvim` took an optional value and ate
        # the next argv token. That spelling is gone; {LainCLI::Argv} now holds
        # the argv half, and this holds the shape half.
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

        # Suppresses the user's start screen, which would otherwise cover the
        # cockpit from launch until the first view arrives -- a dashboard
        # plugin (snacks.nvim, alpha, dashboard-nvim, mini.starter) draws over
        # exactly the empty unnamed buffer nvim boots into, and the cockpit's
        # nvim boots into nothing by design.
        #
        # Naming the buffer is what trips snacks' OWN guard, measured against
        # nvim 0.12.4 + snacks: it bails with reason "buffer has a name". The
        # neighbouring `argc(-1) > 0` guard is the more portable-looking
        # answer and is the wrong one here -- the only argument worth passing
        # is the project directory, and snacks RE-enables the dashboard for a
        # lone directory argument when its explorer is on.
        #
        # Scheme-shaped so `:file` leaves it alone -- a bare word is taken as a
        # relative filename and expanded against the cwd, which showed up as a
        # buffer called `/home/joel/dev/lain/[lain]`, reading like a real file
        # in the project that nobody could open.
        #
        # `lain-cockpit://`, NOT `lain://`: init.lua's fallback scan treats
        # every `^lain://` buffer as layout-eligible, and this is a placeholder
        # the runtime never created. It survives on tab 1; `:LainStart` lays
        # the views out in a new tab.
        SCRATCH_BUFFER = "file lain-cockpit://start"

        def nvim_pane_command
          Shellwords.join(["nvim", *rtp_flag, "--listen", socket, "-c", SCRATCH_BUFFER, "-c", LAIN_START])
        end

        def chat_flags = ["--nvim", socket]

        # Indifferent to HOW the socket was spelled on the command line: `up`
        # resolves `--nvim-socket` (or its absence) into this one `option`
        # before the cockpit is built, so moving the flag never reshapes this.
        #
        # EMPTY IS THE DERIVE SENTINEL, and it is deliberate rather than
        # incidental: `--nvim-socket ""` is an empty shell variable, and "an
        # empty flag means no flag" is the reading `--root` already takes.
        # Anything else must be ABSOLUTE -- see {UnusableSocket}.
        def socket
          @socket ||= begin
            raise UnusableSocket, @option unless @option.empty? || @option.start_with?(File::SEPARATOR)

            @option.empty? ? derived_socket : @option
          end
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
        # to create, an explicit --nvim-socket's parent is the caller's.
        def derived_socket
          File.join(@paths.runtime_dir, "nvim-#{@paths.project_hash(@cwd)}.sock").tap do |sock|
            FileUtils.mkdir_p(File.dirname(sock), mode: 0o700)
          end
        end
      end
    end
  end
end
