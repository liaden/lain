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
      # The largest scaffold that ships, `plan-epic`, composes to 8,759 bytes:
      # under this, though by less than two to one, while a runaway include
      # chain or a pasted corpus is over it.
      #
      # A class constant like every other bounded tool's ({Tools::Bash}'s
      # `OUTPUT_BOUND`, {Tools::ReadFile}'s `BOUND`), so the ceiling is
      # discoverable by reading the class rather than by constructing one, and
      # so a sweep over the toolset can see that this tool declares a bound.
      EXPANSION_BOUND = Tool::Bounds::Handback.new(limit: Tool::Bounds::CEILINGS.fetch("run_skill"))

      # The moves that are available whatever overran. Audience-bound, and the
      # audience is a MODEL being refused rather than a human being offered a
      # choice: each one is a call it can make on its next turn. "Send it
      # anyway" is not among them, because nothing here will send it.
      NARROWER = ["run a narrower skill", "carry on without the skill's scaffold"].freeze

      # Offered only when the scaffold would have fitted, which is the only case
      # where the args are what put the expansion over. A scaffold that overruns
      # on its own is re-rendered byte for byte however short the args get, so
      # offering this there names the call that was just refused -- the identical
      # re-issue {Tool::Bounds.offer} exists to prevent. It leads when it IS
      # offered, because then it is the move that works with nothing else
      # changed.
      SHORTER_ARGS = "call run_skill again with shorter args (or with none at all)"

      # What one call may hand back, and what to say when it may not.
      #
      # A rendered scaffold is guidance somebody else authored, so
      # {Tool::Bounds::Handback} is the shape that fits: it measures without
      # taking a view, and leaves the choice to whoever has one. This tool has
      # no human channel -- no confirm, no second turn to offer -- so its choice
      # is made once, here, and the answer is {Tool::Bounds::Overrun#refusal}.
      # The oversized bytes are dropped rather than handed on, because a scaffold
      # that fills the context defeats the thing it was fetched to help with, and
      # a compactor cannot drop a result it has just been given.
      #
      # Its own object rather than a fourth branch in {RunSkill#perform}, which
      # already carries the budget guard, the happy path and the rescue: the
      # thing missing was a name for "what this tool may hand back", not another
      # conditional. It is a value object so that two tools may share one and
      # neither can reach into it.
      Ceiling = Data.define(:bound) do
        def initialize(bound: EXPANSION_BOUND) = super

        # @param skill [String] the skill that was rendered, so the sentence
        #   names what overran in the model's own terms
        # @param scaffold [String] the rendered skill on its own, measured FIRST
        #   because whether IT fits is what decides which moves are real
        # @param expansion [String] the finished bytes, scaffold and args both --
        #   what would land in the context is what gets measured
        # @return [Tool::Result] the expansion, or a refusal carrying none of it
        def answer(skill:, scaffold:, expansion:)
          overrun = measure(skill, scaffold, expansion)
          return Tool::Result.ok(expansion) if overrun.nil?

          overrun.refusal
        end

        private

        # "The args are the excess" is true only when the scaffold would have
        # fitted, so the scaffold is asked first and on its own. A one-byte arg
        # on a scaffold that overruns is still a scaffold that overruns, and a
        # model told to shorten its args there shortens them all the way to none
        # -- burning a turn and an invocation apiece -- before hearing the one
        # sentence that was true from the start.
        def measure(skill, scaffold, expansion)
          return scaffold_overrun(skill, scaffold) unless bound.admits?(scaffold.bytesize)

          bound.measure(subject: "the #{skill} skill's expansion", content: expansion,
                        actions: [SHORTER_ARGS, *NARROWER])
        end

        # Measured against the SCAFFOLD, so the size the model is told is the one
        # it cannot get below: a total that included the args would read as a
        # target it could shave and still be refused.
        #
        # The subject says the rendering is deterministic because that is what
        # makes this refusal PERMANENT for this skill -- a fact, and so belonging
        # here rather than in the actions, which {Tool::Bounds.offer} promises
        # are places to go. Its trailing comma closes an appositive that
        # {Tool::Bounds::Overrun#message} continues with " is N bytes"; the
        # clause reads as one sentence only because of that, so the two move
        # together.
        def scaffold_overrun(skill, scaffold)
          bound.overrun(subject: "the #{skill} skill's scaffold, which renders the same bytes every time,",
                        content: scaffold, actions: NARROWER)
        end
      end

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

      def initialize(renderer:, max_invocations: MAX_INVOCATIONS, ceiling: Ceiling.new)
        super()
        @renderer = renderer
        @max_invocations = Integer(max_invocations)
        @invocations = 0
        @ceiling = ceiling
      end

      def name = "run_skill"

      def description
        "Renders a named skill's scaffold (with the optional args appended) and " \
          "returns it as this tool's result, so the skill's guidance becomes the " \
          "next thing you read. Use it to pull a skill's procedure into your own " \
          "work mid-task. An unknown skill or an include cycle is returned as an " \
          "error, an expansion over #{EXPANSION_BOUND.limit} bytes is refused with " \
          "something narrower to do, and a per-run budget bounds how many skills " \
          "one run may invoke."
      end

      protected

      def perform(input, _invocation)
        return budget_exhausted if @invocations >= @max_invocations

        @invocations += 1
        scaffold = @renderer.render(input.name)
        @ceiling.answer(skill: input.name, scaffold:, expansion: expand(scaffold, input.args.to_s))
      rescue Lain::Error => e
        # A named composition failure gets an answer the model can act on, so
        # the loop continues. A genuine bug -- a NoMethodError, say -- is NOT a
        # Lain::Error and still propagates to the handler's gate-3 conversion.
        Tool::Result.error(e.message)
      end

      private

      # Mirrors {Middleware::SkillDispatch#expand}: an argless call is the bare
      # scaffold with no trailing blank.
      def expand(scaffold, args) = args.empty? ? scaffold : "#{scaffold}\n\n#{args}"

      def budget_exhausted
        Tool::Result.error("run_skill budget of #{@max_invocations} invocation(s) exhausted " \
                           "for this session")
      end
    end
  end
end
