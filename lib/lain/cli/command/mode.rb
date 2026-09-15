# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/mode`: reads and writes the {Lain::Mode::Switch} slot every mode-aware
      # collaborator already holds -- the same live-slot seam `/model` writes.
      # Bare `/mode` is Emacs' `C-h m`: it reports and changes nothing.
      #
      #   /mode                 report the posture and its active layers
      #   /mode plan            move the exclusive slot, keeping the layers
      #   /mode +auto_approve   enable one layer, keeping the posture
      #   /mode -auto_approve   disable one layer, keeping the posture
      #   /mode !               reset: the most restrictive posture, no layers
      #
      # Tokens FOLD over one Mode and the result is switched ONCE, so
      # `/mode plan +notify -goal` journals a single flip naming where the
      # session started and where it ended. Applying each token as its own switch
      # would write intermediate postures the session was never really in, and a
      # journal reader cannot tell those from a human's own dithering.
      #
      # The reset clears the layers too, because Vim's promise for `<Esc><Esc>`
      # is that afterwards you know exactly where you are -- which a surviving
      # `+auto_approve`, the one layer that can decide a tool call a human would
      # have been asked about, would break. So it rebuilds a whole {Lain::Mode}
      # rather than moving the posture within the one in force.
      #
      # The `goal` layer is the standing-goal driver's: the switch a chat hands
      # this command is {GoalDriver::Guard}, which refuses `+goal` with no goal
      # standing and stops the goal when a flip lowers it.
      #
      # `!` arrives as an ARGUMENT (`/mode !`), not as part of the command word:
      # {Skill::Invocation}'s identifier is `[\w-]+`, so `/mode!` matches no shape
      # at all and falls through to the skill middleware as ordinary prose.
      # Widening that grammar is a deferred design decision; a spec pins it.
      class Mode
        # The same attribution `/model` signs with: the human at the terminal.
        SURFACE = "tty"

        RESET = "!"

        # The rung the reset lands on. Named rather than derived from
        # {Lain::Mode::Posture::NAMES} so a reordering of the posture table
        # cannot silently retarget the reset; a spec asserts the two agree.
        FLOOR = :plan

        # A layer token's leading sigil, mapped to the {Lain::Mode::LayerSet}
        # message it means. Both answer a NEW set, so the fold stays values.
        SIGILS = { "+" => :enable, "-" => :disable }.freeze
        private_constant :SIGILS

        def initialize = freeze

        def name = "mode"

        def usage
          "/mode [posture] [+layer] [-layer] [!] -- show the mode, switch the posture, " \
            "toggle a layer, or reset to #{FLOOR}"
        end

        # Downcased, because the lighters a human reads off chrome they cannot
        # turn off are upper-case (`PLAN`, `AUTO`, `MAN`, `AA`), so a HUD showing
        # `PLAN` beside a command that refuses `/mode PLAN` is a trap of our own
        # making. Every declared posture and layer name is lower-case.
        def call(args, env)
          tokens = args.split.map(&:downcase)
          return env.mode_switch.describe if tokens.empty?

          before = env.mode_switch.current
          after = env.mode_switch.switch(fold(tokens, before), surface: SURFACE)
          # No `mode: ` prefix: {Lain::Mode#describe} carries its own colon.
          "#{before.describe} -> #{after.describe}"
        end

        private

        # The whole fold is guarded, not each token, so a typo in the third token
        # abandons the first two rather than half-applying them: the switch is
        # never written, and the mode in force is the one the human can still
        # see. The messages are {Lain::Mode::Posture.for}'s and
        # {Lain::Mode::Layer.for}'s own, re-raised as a {Lain::Error} because an
        # unknown posture is a typo the repl renders and loops past, not a bug.
        def fold(tokens, mode)
          tokens.inject(mode) { |current, token| apply(current, token) }
        rescue ArgumentError => e
          raise Error, e.message
        end

        # A bare token names a posture; `+`/`-` names a layer. The shapes cannot
        # collide only because no declared name opens with a sigil or with
        # {RESET} -- true of today's rosters and enforced NOWHERE ELSE, so a spec
        # asserts it: a layer declared `:"-x"` would be unreachable here, and a
        # posture named `!` would be shadowed by the reset, which is tested
        # first.
        def apply(mode, token)
          return Lain::Mode.new(posture: FLOOR) if token == RESET

          toggle = SIGILS[token[0]]
          return mode.with(posture: token) unless toggle

          mode.with(layers: mode.layers.public_send(toggle, token[1..]))
        end
      end
    end
  end
end
