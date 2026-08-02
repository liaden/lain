# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/mode`: reads and writes the {Lain::Mode::Switch} slot every mode-aware
      # collaborator already holds, the same seam `/yolo` and `/model` write.
      # Bare `/mode` is Emacs' `C-h m` -- it reports and changes nothing.
      #
      # == One grammar, three token shapes, folded in order
      #
      #   /mode                 report the posture and its active layers
      #   /mode plan            move the exclusive slot, keeping the layers
      #   /mode +auto_approve   enable one layer, keeping the posture
      #   /mode -auto_approve   disable one layer, keeping the posture
      #   /mode !               reset: the most restrictive posture, no layers
      #
      # Tokens FOLD over one Mode and the result is switched ONCE, so
      # `/mode plan +notify -goal` journals a single flip naming where the
      # session started and where it ended. Applying each token as its own
      # switch would write intermediate postures the session was never really
      # in, and a journal reader cannot tell those from a human's own dithering.
      #
      # == The reset, and why it clears the layers too
      #
      # Vim's docs lead with the reset rather than the display: *"If for any
      # reason you do not know which mode you are in, you can always get back to
      # Normal mode by typing `<Esc>` twice."* Its promise is that afterwards
      # you know exactly where you are, which a surviving `+auto_approve` --
      # the one layer that can decide a tool call a human would have been asked
      # about -- would break. So the reset rebuilds a whole {Lain::Mode} rather
      # than moving the posture within the one in force.
      #
      # `!` arrives as an ARGUMENT (`/mode !`), not as part of the command word:
      # {Skill::Invocation}'s identifier is `[\w-]+`, so `/mode!` matches no
      # shape at all and falls through to the skill middleware as ordinary
      # prose. Widening that grammar is a deliberately deferred design decision
      # and is not this command's to make; a spec pins the boundary.
      class Mode
        # The same attribution `/yolo` and `/model` sign with: the flip came
        # from the human at the terminal.
        SURFACE = "tty"

        RESET = "!"

        # The rung the reset lands on. Named rather than derived from
        # {Lain::Mode::Posture::NAMES} so a reordering of the posture table
        # cannot silently retarget the reset -- a spec asserts the two agree,
        # which puts the drift in a failing example instead of in a session.
        FLOOR = :plan

        # A layer token's leading sigil, mapped to the {Lain::Mode::LayerSet}
        # message it means. Both messages answer a NEW set, so the fold stays a
        # sequence of values.
        SIGILS = { "+" => :enable, "-" => :disable }.freeze
        private_constant :SIGILS

        def initialize = freeze

        def name = "mode"

        def usage
          "/mode [posture] [+layer] [-layer] [!] -- show the mode, switch the posture, " \
            "toggle a layer, or reset to #{FLOOR}"
        end

        # Downcased, as `/yolo` downcases its own argument: the lighters a human
        # reads off chrome they cannot turn off are upper-case (`PLAN`, `AUTO`,
        # `MAN`, `AA`), so a HUD that displays `PLAN` beside a command that
        # refuses `/mode PLAN` is a trap of our own making. Every declared
        # posture and layer name is lower-case, and a spec holds that.
        def call(args, env)
          tokens = args.split.map(&:downcase)
          return env.mode_switch.describe if tokens.empty?

          before = env.mode_switch.current
          after = env.mode_switch.switch(fold(tokens, before), surface: SURFACE)
          # No `mode: ` prefix: {Lain::Mode#describe} already carries its own
          # colon, and the two together stutter.
          "#{before.describe} -> #{after.describe}"
        end

        private

        # The whole fold is guarded, not each token, so a typo in the third
        # token abandons the first two rather than half-applying them: the
        # switch is never written, and the mode in force is the one the human
        # can still see. The messages are {Lain::Mode::Posture.for}'s and
        # {Lain::Mode::Layer.for}'s own, each of which names its full roster --
        # re-raised as a {Lain::Error} because an unknown posture is a
        # recoverable typo the repl renders and loops past, not a bug.
        def fold(tokens, mode)
          tokens.inject(mode) { |current, token| apply(current, token) }
        rescue ArgumentError => e
          raise Error, e.message
        end

        # A bare token names a posture; `+`/`-` names a layer. The shapes cannot
        # collide only because no declared name opens with a sigil or with
        # {RESET} -- true of today's rosters and enforced NOWHERE ELSE, so a
        # spec asserts it: a layer declared `:"-x"` would be unreachable here
        # (the sigil branch strips the `-` and looks up `x`) and a posture named
        # `!` would be shadowed by the reset, which is tested first.
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
