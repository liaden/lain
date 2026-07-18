# frozen_string_literal: true

module Lain
  module Middleware
    # The repl-phase middleware that turns a `you>` line into either an expanded
    # turn or a short-circuited answer, before the model is ever asked.
    #
    # Subclass-Base/override-#call/freeze, the {RefuseSecretWrites} template, and
    # it routes every path through {Base#downstream} rather than a bare `yield`.
    # It parses `env[:text]` via {Skill::Invocation.parse} and branches on the
    # five outcomes the grammar admits:
    #
    #   not an invocation  (parse -> nil)  -> pass through unchanged
    #   in-line  (`/skill args`)           -> render the scaffold, append args,
    #                                         REWRITE env[:text], run the turn
    #   unknown  (`/nope`)                  -> short-circuit: a loud env[:response]
    #                                         naming the known set, NO model turn
    #   role-bound (`@role/skill`)          -> fold a persona'd one-shot subagent's
    #                                         final answer into env[:response] via
    #                                         the {Skill::RoleSpawn} seam (T-B3)
    #   malformed (parse raises Malformed)  -> propagate; the dispatch boundary
    #                                         rescues Lain::Error and renders it
    #
    # A short-circuit answers by setting env[:response] and NEVER calling
    # downstream -- the B0 dispatch-boundary seam renders env[:response] with
    # zero model turn. The response is a real {Response} whose text is the loud
    # message, so the one boundary renderer (`render_response`) handles it exactly
    # as it handles a model turn; this middleware never touches the terminal.
    #
    # Malformed is deliberately NOT rescued here: a `@word/` that attempts the
    # grammar and breaks it is a {Skill::Invocation::Malformed} (a {Lain::Error}),
    # and letting it propagate is what lets the REPL's dispatch boundary render it
    # and loop to the next prompt -- rescuing it into a silent pass-through would
    # send the broken line to the model verbatim.
    class SkillDispatch < Base
      def initialize(catalog:, renderer:, role_spawn:)
        @catalog = catalog
        @renderer = renderer
        @role_spawn = role_spawn
        super()
        freeze
      end

      def call(env, &app)
        invocation = Skill::Invocation.parse(env.fetch(:text))
        return downstream(env, &app) if invocation.nil?
        return report_role_bound(env, invocation) unless invocation.inline?
        return report_unknown(env, invocation) unless known?(invocation)

        downstream(env.merge(text: expand(invocation)), &app)
      end

      private

      def known?(invocation) = @catalog.names.include?(invocation.skill.to_sym)

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

      # T-B3. A role-bound line folds a persona'd one-shot subagent's final
      # answer into env[:response]: the {Skill::RoleSpawn} seam fetches the role,
      # spawns it under its policy/persona in the parsed context mode
      # (`:inherit` for `@role/skill`, `:fresh` for `@role[/skill]`), and runs
      # the rendered scaffold + args to a single result. Setting env[:response]
      # short-circuits, so the B0 boundary renders the child's answer with ZERO
      # parent turn -- the subagent's turns live attributed in the shared Store,
      # never in the parent's rendered conversation (OM-2 out-of-band). An
      # unknown role raises {Role::Catalog::Unknown} BEFORE any spawn (no
      # tokens); it is a {Lain::Error}, so -- exactly like {Malformed} -- it
      # propagates to the dispatch boundary, which renders it and loops.
      def report_role_bound(env, invocation)
        result = @role_spawn.call(invocation.role, invocation.context, expand(invocation))
        short_circuit(env, result.content)
      end

      def short_circuit(env, message)
        env.merge(response: Response.new(content: [{ "type" => "text", "text" => message }],
                                         stop_reason: :end_turn))
      end
    end
  end
end
