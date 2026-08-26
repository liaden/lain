# frozen_string_literal: true

module Lain
  module CLI
    # Assembles the repl-phase {Middleware::Stack} the Repl wraps each `you>`
    # line in. Lib-side and unit-testable, the {Backend} precedent: the exe
    # stays thin wiring, and which middlewares in what order over what
    # collaborators lives here, where it can be tested without a Thor instance.
    #
    # BOTH keywords are REQUIRED, for one reason. The library is the run's ONE
    # snapshot of the project's skills, read once at {Backend#library};
    # defaulting it would let /help's listing, this stack's dispatch,
    # {Tools::RunSkill}'s render and {Backend#context}'s system prompt look at
    # different reads of one tree -- silently, since the tree rarely changes
    # mid-session. The role_spawn keyword is the {Skill::RoleSpawn} seam a
    # `@role/skill` line folds through, and a defaulted Null would let a
    # role-bound line degrade to a "not wired" message with no error at the
    # wiring site. Either way a forgotten keyword must be a loud ArgumentError.
    #
    # Extras default to none, and are placed AHEAD of the one fixed member so
    # they run outermost, in the order given, wrapping skill dispatch rather
    # than being wrapped by it. An extra that short-circuits without setting
    # `env[:response]` gets no help here: `repl.rb`'s dispatch boundary already
    # renders that fault loudly, for every phase alike.
    module ReplMiddleware
      def self.build(role_spawn:, library:, extras: [])
        skill_dispatch = Middleware::SkillDispatch.new(catalog: library.catalog, renderer: library.renderer,
                                                       role_spawn:)
        Middleware::Stack.new([*extras, skill_dispatch])
      end
    end
  end
end
