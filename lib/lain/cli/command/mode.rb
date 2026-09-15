# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/mode`: reads and writes the {Lain::Mode::Switch} slot every mode-aware
      # collaborator already holds -- the same live-slot seam `/model` writes.
      # Bare `/mode` is Emacs' `C-h m`: it reports and changes nothing.
      #
      #   /mode                 report the scope, the approval level and the layers
      #   /mode auto            move one exclusive axis, keeping everything else
      #   /mode checkout ask    move both axes at once
      #   /mode +auto_approve   enable one layer
      #   /mode -auto_approve   disable one layer
      #   /mode !               reset: the starting scope and approval, no layers
      #
      # Tokens FOLD over one Mode and the result is switched ONCE, so
      # `/mode auto +notify -goal` journals a single flip naming where the
      # session started and where it ended. Applying each token as its own
      # switch would write intermediate modes the session was never really in.
      #
      # An axis holds one value, so two tokens naming the same axis are a
      # contradiction and refuse whole, naming both -- taking the last would
      # hand a typo the gate.
      #
      # The reset clears the layers too, because Vim's promise for `<Esc><Esc>`
      # is that afterwards you know exactly where you are -- which a surviving
      # `+auto_approve`, the one layer that can decide a tool call a human would
      # have been asked about, would break.
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

        # A layer token's leading sigil, mapped to the {Lain::Mode::LayerSet}
        # message it means. Both answer a NEW set, so the fold stays values.
        SIGILS = { "+" => :enable, "-" => :disable }.freeze
        private_constant :SIGILS

        # Each exclusive axis, keyed by the {Lain::Mode} member it sets. A bare
        # token names a value of exactly one of them.
        AXES = { scope: Lain::Mode::Scope, approval: Lain::Mode::Approval }.freeze
        private_constant :AXES

        # Names a human may still type from an older mode vocabulary, each
        # refused with where it went rather than as a typo.
        RETIRED = {
          "manual" => "manual is retired: approval is ask or auto, and ask gates everything manual gated",
          "accept_edits" => "accept_edits is retired: it is ask now",
          "plan" => "plan is not available yet: plan scope, which confines writes and commands to a spike " \
                    "worktree, is not built"
        }.freeze
        private_constant :RETIRED

        def initialize = freeze

        def name = "mode"

        def usage
          "/mode [scope] [approval] [+layer] [-layer] [!] -- show the mode, switch its scope or approval, " \
            "toggle a layer, or reset"
        end

        # Downcased, because the lighters a human reads off chrome they cannot
        # turn off are upper-case (`AUTO`, `AA`), so a HUD showing `AUTO` beside
        # a command that refuses `/mode AUTO` is a trap of our own making. Every
        # declared name is lower-case.
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
        # see. A declared family's own `ArgumentError` is re-raised as a
        # {Lain::Error} because a typo is something the repl renders and loops
        # past, not a bug.
        def fold(tokens, mode)
          refuse_retired(tokens)
          refuse_contradictions(tokens)
          tokens.inject(mode) { |current, token| apply(current, token) }
        rescue ArgumentError => e
          raise Error, e.message
        end

        def refuse_retired(tokens)
          retired = tokens.find { |token| RETIRED.key?(token) }
          raise Error, "#{RETIRED.fetch(retired)} -- #{takes}" if retired
        end

        def refuse_contradictions(tokens)
          named = tokens.group_by { |token| axis_of(token) }.except(nil)
          axis, both = named.find { |_axis, values| values.size > 1 }
          raise Error, "/mode #{both.join(" ")} names #{axis} twice, and a mode holds one #{axis}" if axis
        end

        # A bare token names an axis value; `+`/`-` names a layer. The shapes
        # cannot collide only because no declared name opens with a sigil or
        # with {RESET} -- true of today's rosters and enforced NOWHERE ELSE, so a
        # spec asserts it.
        def apply(mode, token)
          return Lain::Mode.new if token == RESET

          toggle = SIGILS[token[0]]
          return mode.with(layers: mode.layers.public_send(toggle, token[1..])) if toggle

          axis = axis_of(token)
          raise ArgumentError, "unknown /mode token #{token.inspect} -- #{takes}" unless axis

          mode.with(axis => token)
        end

        def axis_of(token) = AXES.find { |_axis, family| family::NAMES.include?(token.to_sym) }&.first

        def takes
          names = AXES.values.flat_map { |family| family::NAMES }.sort.join(", ")
          "/mode takes #{names}, #{RESET}, +layer and -layer (layers: #{Lain::Mode::Layer::NAMES.join(", ")})"
        end
      end
    end
  end
end
