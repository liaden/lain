# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): the in-agent composition primitive. It RENDERS a
    # skill's scaffold and returns the markdown AS ITS tool_result, so the
    # guidance becomes the next thing the SAME agent reads. A CONTINUATION, not
    # a spawn: no child Agent, no fresh Timeline, no `you>` prompt.
    #
    # Rendering text has no egress and mutates nothing, so it is tier 1 and
    # needs no approval gate. An unknown skill or a static include cycle is
    # reported as an error {Tool::Result}, never a raise.
    #
    # == The dispatch-time backstop: a per-run invocation BUDGET, not a depth
    #
    # A rendered scaffold can itself say "call run_skill ...", so the model can
    # recurse without bound in a way the render-time {Prompt::CircularSlot}
    # guard cannot see -- each render finishes and returns before the next call
    # is made, so it is a chain of SEPARATE dispatches rather than one render.
    #
    # Deliberately NOT a nesting depth like {Tools::Subagent}'s `max_depth`:
    # that ceiling DECREMENTS into a per-child copy of the tool, so N sibling
    # spawns never exhaust it. run_skill has no child and no toolset copy, so
    # its "recursion" is repeated calls to the ONE instance with no return
    # signal to count down on. The honest bound is therefore a cumulative,
    # cross-skill, never-reset per-run COUNT -- a session QUOTA, which is why
    # the refusal says "budget" and not "depth".
    #
    # A belt-and-suspenders SAFETY NET, not the primary cap: {Agent::Budget} is
    # what actually stops a runaway self-calling loop, so the default sits well
    # above realistic composition and trips only on a genuine runaway.
    class RunSkill < Tool
      # The wire shape: the skill to render, and the concrete input it operates
      # on. `args` is optional -- an argless invocation is the bare scaffold.
      class Input < Tool::Input
        field :name, :string, description: "Name of the skill to render and run.", required: true
        field :args, :string,
              description: "Optional concrete input for the skill (e.g. a path or a question), " \
                           "appended to the rendered scaffold.",
              required: false
      end

      input_model Input

      # Well ABOVE realistic composition: the runaway backstop, not a working
      # limit. Named so a caller wiring the tool can move it in one line.
      MAX_INVOCATIONS = 64

      def initialize(renderer:, max_invocations: MAX_INVOCATIONS)
        super()
        @renderer = renderer
        @max_invocations = Integer(max_invocations)
        @invocations = 0
      end

      def name = "run_skill"

      def description
        "Renders a named skill's scaffold (with the optional args appended) and " \
          "returns it as this tool's result, so the skill's guidance becomes the " \
          "next thing you read. Use it to pull a skill's procedure into your own " \
          "work mid-task. An unknown skill or an include cycle is returned as an " \
          "error, and a per-run budget bounds how many skills one run may invoke."
      end

      protected

      def perform(input, _invocation)
        return budget_exhausted if @invocations >= @max_invocations

        @invocations += 1
        Tool::Result.ok(expand(input))
      rescue Lain::Error => e
        # A named composition failure gets an answer the model can act on, so
        # the loop continues. A genuine bug -- a NoMethodError, say -- is NOT a
        # Lain::Error and still propagates to the handler's gate-3 conversion.
        Tool::Result.error(e.message)
      end

      private

      # Mirrors {Middleware::SkillDispatch#expand}: an argless call is the bare
      # scaffold with no trailing blank.
      def expand(input)
        scaffold = @renderer.render(input.name)
        args = input.args.to_s
        args.empty? ? scaffold : "#{scaffold}\n\n#{args}"
      end

      def budget_exhausted
        Tool::Result.error("run_skill budget of #{@max_invocations} invocation(s) exhausted " \
                           "for this session")
      end
    end
  end
end
