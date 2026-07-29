# frozen_string_literal: true

module Lain
  module CLI
    # Assembles the repl-phase {Middleware::Stack} the Repl wraps each `you>`
    # line in. Lib-side and unit-testable, the {Backend} precedent: the exe stays
    # thin wiring and calls one builder; the construction -- which middlewares,
    # in what order, over what collaborators -- lives here where it can be tested
    # without a Thor instance.
    #
    # The repl phase composes over a {Skill::Catalog} and a {Prompt::Slots} --
    # both session-fixed snapshots of the project's `.lain/` tree. BOTH are
    # injectable, and a live session injects both: the catalog is loaded once
    # by {Wiring}, the slots once by {Backend#slots}, and each instance is
    # threaded to every reader (T15), so /help's listing, this stack's
    # dispatch, {Tools::RunSkill}'s render and {Backend#context}'s system
    # prompt cannot be looking at four different reads of one tree. (Two owners
    # for one pair is the seam Chunk B is expected to name.)
    # `root` is where the defaults read their overrides; it defaults to
    # `Dir.pwd`, the project root the rest of the CLI already keys off, so a
    # caller holding neither snapshot still gets one in a single line.
    #
    # `role_spawn` is the {Skill::RoleSpawn} seam a `@role/skill` line folds
    # through -- the exe's Wiring constructs it from the session's
    # provider/toolset/parent/journal/supervisor and hands it in. It is REQUIRED,
    # not defaulted: a defaulted Null would let a role-bound line silently degrade
    # to a "not wired" message with no error at the wiring site, and the whole
    # point of injecting it is that a real session always has one.
    module ReplMiddleware
      def self.build(role_spawn:, root: Dir.pwd, catalog: Skill::Catalog.load(root:),
                     slots: Prompt::Slots.load(root:))
        Middleware::Stack.new([Middleware::SkillDispatch.new(catalog:, renderer: renderer(catalog:, slots:),
                                                             role_spawn:)])
      end

      # The catalog-and-slots composition seam, shared: this stack's
      # SkillDispatch and Wiring's run_skill tool render through the SAME
      # construction, so the two scaffold paths cannot drift.
      def self.renderer(root: Dir.pwd, catalog: Skill::Catalog.load(root:), slots: Prompt::Slots.load(root:))
        Skill::Renderer.new(catalog:, slots:)
      end
    end
  end
end
