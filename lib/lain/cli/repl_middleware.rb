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
    # rest of the CLI already keys off, so the exe's call stays a single argless
    # line.
    module ReplMiddleware
      def self.build(root: Dir.pwd)
        catalog = Skill::Catalog.load(root:)
        renderer = Skill::Renderer.new(catalog:, slots: Prompt::Slots.load(root:))
        Middleware::Stack.new([Middleware::SkillDispatch.new(catalog:, renderer:)])
      end
    end
  end
end
