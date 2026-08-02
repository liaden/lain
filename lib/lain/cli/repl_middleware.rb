# frozen_string_literal: true

module Lain
  module CLI
    # Assembles the repl-phase {Middleware::Stack} the Repl wraps each `you>`
    # line in. Lib-side and unit-testable, the {Backend} precedent: the exe stays
    # thin wiring and calls one builder; the construction -- which middlewares,
    # in what order, over what collaborators -- lives here where it can be tested
    # without a Thor instance.
    #
    # The repl phase composes over the run's ONE {Skill::Library} -- the
    # project's skills and the prompt slots they render through, read once at
    # {Backend#library}. T15 threaded the two halves separately and T40 named
    # the pair, which is what took `root:` off this module: it was here only to
    # feed the from-disk defaults, and a from-disk default is exactly the second
    # read of one tree the threading exists to remove.
    #
    # BOTH keywords are REQUIRED, for one reason. `library` is the run's
    # snapshot: defaulting it would let /help's listing, this stack's dispatch,
    # {Tools::RunSkill}'s render and {Backend#context}'s system prompt look at
    # different reads of one tree -- silently, since the tree rarely changes
    # mid-session. `role_spawn` is the {Skill::RoleSpawn} seam a `@role/skill`
    # line folds through: a defaulted Null would let a role-bound line degrade
    # to a "not wired" message with no error at the wiring site. Either way a
    # forgotten keyword must be a loud ArgumentError here, not a quiet degrade
    # far from the bug.
    #
    # `extras`, unlike the two keywords above, defaults to none: T23 opens the
    # door {Middleware::Stack} already has -- `#use`/`#insert_before`/
    # `#insert_after` -- to this phase, it does not invent a new one. Extras
    # are placed AHEAD of the one fixed member, so they run outermost, in the
    # order given, wrapping skill dispatch rather than being wrapped by it; it
    # is what a future symmetric `Principal` hangs off. A caller whose extra
    # short-circuits without setting `env[:response]` gets no help from this
    # module -- `repl.rb`'s dispatch boundary already renders that fault
    # loudly (`render_missing_response`), for every phase alike.
    module ReplMiddleware
      def self.build(role_spawn:, library:, extras: [])
        skill_dispatch = Middleware::SkillDispatch.new(catalog: library.catalog, renderer: library.renderer,
                                                       role_spawn:)
        Middleware::Stack.new([*extras, skill_dispatch])
      end
    end
  end
end
