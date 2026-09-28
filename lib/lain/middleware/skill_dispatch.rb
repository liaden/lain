# frozen_string_literal: true

module Lain
  module Middleware
    # The repl-phase middleware that turns a `you>` line into either an expanded
    # turn or a short-circuited answer, before the model is ever asked. It parses
    # `env[:text]` via {Skill::Invocation.parse} and branches on the five outcomes
    # the grammar admits:
    #
    #   not an invocation  (parse -> nil)  -> pass through unchanged
    #   in-line  (`/skill args`)           -> render the scaffold, append args,
    #                                         REWRITE env[:text], run the turn --
    #                                         unless the skill declares a model,
    #                                         which an in-line turn cannot honor
    #                                         ({ModelWithoutSpawn})
    #   unknown  (`/nope`)                 -> short-circuit: a loud env[:response]
    #                                         naming the known set, NO model turn
    #   role-bound (`@role/skill`)         -> fold a persona'd one-shot subagent's
    #                                         final answer into env[:response] via
    #                                         the {Skill::RoleSpawn} seam
    #   malformed (parse raises Malformed) -> propagate; the dispatch boundary
    #                                         rescues Lain::Error and renders it
    #
    # A short-circuit answers by setting env[:response] and NEVER calling
    # downstream. The response is a real {Response} whose text is the loud
    # message, so the one boundary renderer handles it exactly as it handles a
    # model turn; this middleware never touches the terminal.
    #
    # Malformed is deliberately NOT rescued here: rescuing it into a silent
    # pass-through would send the broken line to the model verbatim.
    #
    # One in-line skill has a second meaning. With a changeset review held,
    # `/critique` is {Review::Critique} over the held round -- one child per
    # chunk, reading git objects -- and not a turn over the working tree the
    # human is still editing. With nothing held it is the skill like any other.
    class SkillDispatch < Base
      # An in-line invocation of a skill whose front-matter declares a model.
      # There is no child to give it to -- an in-line skill expands into the
      # parent's own turn -- so honouring the declaration is impossible and
      # running the line on the parent's model would be the declaration ignored
      # in silence. Refused where the skill is READ, ahead of the turn it would
      # have expanded into, so nothing is spent answering on a model nobody
      # chose. A {Lain::Error}, so the dispatch boundary renders it.
      class ModelWithoutSpawn < Error; end

      # The skill a held review round answers itself.
      CRITIQUE = :critique

      # `outbox:` is the chat's ONE held review, `window:` the run's window book
      # a critique sizes its chunks against; `checkouts:`, `journal:` and
      # `slots:` are what {Review::Critique} reads through, records to and
      # renders its role's prelude from. All required, for the reason every
      # keyword here is: a defaulted book would size chunks to a guess.
      def initialize(catalog:, renderer:, role_spawn:, outbox:, window:, checkouts:, journal:, slots:)
        @catalog = catalog
        @renderer = renderer
        @role_spawn = role_spawn
        @outbox = outbox
        @critique = { spawn: role_spawn, window:, checkouts:, journal:, slots: }.freeze
        super()
        freeze
      end

      def call(env, &app)
        invocation = Skill::Invocation.parse(env.fetch(:text))
        return downstream(env, &app) if invocation.nil?
        return report_role_bound(env, invocation) unless invocation.inline?
        return report_unknown(env, invocation) unless known?(invocation)

        refuse_unspawned_model!(invocation)
        return report_critique(env, invocation) if held_critique?(invocation)

        downstream(env.merge(text: expand(invocation)), &app)
      end

      private

      def known?(invocation) = @catalog.names.include?(invocation.skill.to_sym)

      def held_critique?(invocation) = invocation.skill.to_sym == CRITIQUE && @outbox.open?

      # Ahead of the held-review branch as well as the expansion: a critique
      # round spawns its own children on the run's model, so letting a declared
      # one through there would be the same silence by a longer road.
      def refuse_unspawned_model!(invocation)
        skill = @catalog.fetch(invocation.skill)
        return if Blankness.blank?(skill.model)

        raise ModelWithoutSpawn,
              "skill #{skill.name.inspect} declares model #{skill.model.inspect}, and an in-line " \
              "/#{skill.name} has no child to run it on: invoke it role-bound (@role/#{skill.name} or " \
              "@role[/#{skill.name}]) so the declared model reaches a spawn, or drop `model:` from its " \
              "front-matter"
      end

      # A refusal raises {Review::Critique::Refused}, a {Lain::Error}, so it
      # reaches the dispatch boundary exactly as an unknown role does.
      def report_critique(env, invocation)
        critique = Review::Critique.new(changeset: @outbox.held_changeset, instructions: expand(invocation),
                                        **@critique)
        short_circuit(env, critique.call)
      end

      # The rendered scaffold, then the caller's args verbatim after a blank
      # line. An argless invocation is the bare scaffold -- no trailing blank.
      def expand(invocation)
        scaffold = @renderer.render(invocation.skill)
        invocation.args.empty? ? scaffold : "#{scaffold}\n\n#{invocation.args}"
      end

      def report_unknown(env, invocation)
        short_circuit(env,
                      "unknown skill #{invocation.skill.inspect}, expected one of #{@catalog.names.inspect}")
      end

      # The {Skill::RoleSpawn} seam fetches the role, spawns it under its
      # policy/persona in the parsed context mode (`:inherit` for `@role/skill`,
      # `:fresh` for `@role[/skill]`), and runs the scaffold to a single result.
      # Setting env[:response] short-circuits, so the boundary renders the child's
      # answer with ZERO parent turn -- the subagent's turns live attributed in
      # the shared Store, never in the parent's rendered conversation. An unknown
      # role raises {Role::Catalog::Unknown} BEFORE any spawn, so no tokens are
      # spent; being a {Lain::Error} it propagates to the dispatch boundary like
      # {Malformed} does.
      def report_role_bound(env, invocation)
        result = @role_spawn.call(invocation.role, invocation.context, expand(invocation),
                                  model: declared_model(invocation))
        short_circuit(env, result.content)
      end

      # The skill's front-matter model, carrying the skill's OWN name so a
      # refusal at the spawn cites the declaration a reader has to go and edit
      # rather than the role that happened to be asked for.
      def declared_model(invocation)
        skill = @catalog.fetch(invocation.skill)
        Tools::Subagent::ModelChoice.of(skill.model, declared_by: "skill #{skill.name.inspect}")
      end

      def short_circuit(env, message)
        env.merge(response: Response.new(content: [{ "type" => "text", "text" => message }],
                                         stop_reason: :end_turn))
      end
    end
  end
end
