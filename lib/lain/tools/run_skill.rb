# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): the in-agent composition primitive. Given a skill name
    # (and optional args), it RENDERS that skill's scaffold via {Skill::Renderer}
    # and returns the finished markdown AS ITS tool_result -- so the skill's
    # guidance becomes the next thing the SAME agent reads. It is a CONTINUATION,
    # not a spawn: no child Agent, no fresh Timeline, no `you>` prompt. (The
    # repl's `@role/skill` surface -- a real delegation -- is a different seam;
    # this one is what a mid-loop agent calls to pull a skill's scaffold into its
    # own context.)
    #
    # Rendering text has no egress and mutates nothing, so it is tier 1 and needs
    # no approval gate (the default). A skill that does not exist, or a static
    # include cycle, is reported as an error {Tool::Result} -- never a raise --
    # so the loop reads the problem and continues.
    #
    # == The dispatch-time backstop (a per-run invocation BUDGET, not a depth)
    #
    # A rendered scaffold can itself say "call run_skill ...", so the model can
    # read a scaffold, call run_skill, read another, call again -- unbounded
    # recursion the render-time {Prompt::CircularSlot} guard cannot see, because
    # each render finishes and returns before the next call is even made. This is
    # distinct from a static include cycle: it is a chain of SEPARATE dispatches,
    # not one render.
    #
    # The bound lives HERE, on the tool instance, set at construction and never
    # threaded through session state. It is deliberately NOT a nesting depth like
    # {Tools::Subagent}'s `max_depth`: that ceiling DECREMENTS into a per-child
    # copy of the tool, so N sibling spawns never exhaust it (true nesting).
    # run_skill has no child and no toolset copy -- its "recursion" is just
    # repeated calls to the ONE instance in the ONE agent's toolset, with no
    # return signal to count down on. So the honest bound is a cumulative,
    # cross-skill, never-reset per-run invocation COUNT against `max_invocations`:
    # every call is charged, whatever skill, and past the budget the next call
    # refuses (an is_error Result) doing no work. That still satisfies the AC --
    # a self-calling scaffold cannot recurse without bound -- but it is a session
    # QUOTA, so the refusal says "budget", not "depth".
    #
    # This is a belt-and-suspenders SAFETY NET, not the primary cap: {Agent::Budget}
    # (turns/tokens) is what actually stops a runaway self-calling loop. So the
    # default is set well above realistic legitimate composition and only trips on
    # a genuine runaway.
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

      # The per-run invocation budget, set well ABOVE realistic legitimate
      # composition -- this is the runaway backstop, not a working limit; a
      # legitimate multi-skill session never approaches it, and {Agent::Budget}
      # (turns/tokens) is the primary cap on a self-calling loop. Named so a
      # caller wiring the tool can raise or lower it in one readable line.
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
        # An unknown skill ({Skill::Catalog::Unknown}), a static include cycle
        # ({Prompt::CircularSlot}), or any other named composition failure: the
        # model asked a reasonable question and gets an answer it can act on, so
        # the loop continues. A genuine bug (a NoMethodError, say) is NOT a
        # Lain::Error and still propagates to the handler's gate-3 conversion.
        Tool::Result.error(e.message)
      end

      private

      # Mirrors {Middleware::SkillDispatch#expand}: the rendered scaffold, then
      # the caller's args verbatim after a blank line; an argless call is the
      # bare scaffold with no trailing blank.
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
