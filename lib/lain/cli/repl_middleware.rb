# frozen_string_literal: true

module Lain
  module CLI
    # Assembles the repl-phase {Middleware::Stack} the Repl wraps each `you>`
    # line in. Lib-side and unit-testable, the {Backend} precedent: the exe stays
    # thin wiring and calls one builder; the construction -- which middlewares,
    # in what order, over what collaborators -- lives here where it can be tested
    # without a Thor instance.
    #
    # {.build} OWNS the one disk read the repl phase needs: the {Skill::Catalog}
    # and the {Prompt::Slots} the {Skill::Renderer} composes through, loaded once
    # at session start (like {Backend#slots}) into frozen, session-fixed
    # instances, exactly as {Prompt::Slots.load} is. `root` is where both read
    # their `.lain/` overrides; it defaults to `Dir.pwd`, the project root the
    # rest of the CLI already keys off, so the exe's call stays a single line.
    #
    # `role_spawn` is the {Skill::RoleSpawn} seam a `@role/skill` line folds
    # through -- the exe's Wiring constructs it from the session's
    # provider/toolset/parent/journal/supervisor and hands it in. It is REQUIRED,
    # not defaulted: a defaulted Null would let a role-bound line silently degrade
    # to a "not wired" message with no error at the wiring site, and the whole
    # point of injecting it is that a real session always has one.
    module ReplMiddleware
      def self.build(role_spawn:, root: Dir.pwd)
        catalog = Skill::Catalog.load(root:)
        renderer = Skill::Renderer.new(catalog:, slots: Prompt::Slots.load(root:))
        Middleware::Stack.new([Middleware::SkillDispatch.new(catalog:, renderer:, role_spawn:)])
      end
    end
  end
end
