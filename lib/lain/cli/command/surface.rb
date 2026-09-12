# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # Assembles everything a typed `you>` line can hit before the model --
      # extracted from {Wiring} because "what a line dispatches through" is its
      # own responsibility (the Metrics trip said so: extract, do not loosen):
      #
      # * the frozen, nil-free {Env} every command reads, built ONCE from the
      #   collaborators Wiring wired -- a mis-wire is a loud ArgumentError here,
      #   never a fail-open Null, and the queue-shaped {Env::NoApprovals} keeps
      #   the one reader an unattended run leaves empty nil-free;
      # * the shipped command {Registry}, bound over that Env ({#commands});
      # * the skill middleware ({#middleware}) over the SAME catalog snapshot
      #   the registry's /help lists, so listing and dispatch cannot drift.
      #
      # `library:` is the run's ONE {Skill::Library}, so this surface,
      # {Tools::RunSkill} and {Backend#context}'s system prompt are readers of
      # one `.lain/` read rather than separate reads of the same tree.
      class Surface
        # `chronicle:`, `status_feed:`, `model_switch:`, `mode_switch:`, `role_spawn:`,
        # `library:`, `ledger:`, `sensitivity:` and `snapshots:` are required, not defaulted:
        # each is always wired in the live path, so a defaulted Null would only
        # mask a mis-wire. The mode switch is the sharpest case -- it is the slot
        # that reaches the gate, since {CLI::Switchboard#apply} DERIVES the gate
        # policy from the flip, so a defaulted one would fail OPEN and `/mode
        # plan` would report success against a slot no gate and no toolset ever
        # reads. A defaulted library would silently be a SECOND read of the same
        # tree, and a defaulted {Lain::Sensitivity::Ledger} lets a forgotten
        # injection become a SECOND ledger whose releases nobody ever sees, so
        # `/survey` would mask regions this run has already released -- and the
        # path boundary is that same argument one boundary over (ARCHITECTURE.md,
        # "The secret boundary"). A defaulted snapshot slot would answer
        # "nothing to undo" for a session that has changed files.
        #
        # `cwd:` is the OTHER half of {Lain::Project}: root is the authority
        # boundary, cwd is where a relative path resolves, and a monorepo chat
        # stands in a subtree while its root sits at the repository top.
        # {Survey} names every file of a survey from it, because the attached
        # editor resolves a row against the directory it was started in and
        # `lain up` gives both panes one `-c`. `root:` stays on its own
        # business: {Meta} reads the project's `.lain/` config from it.
        def initialize(agent:, replies:, supervisor:, role_spawn:, chronicle:, status_feed:,
                       model_switch:, mode_switch:, library:, ledger:, sensitivity:, snapshots:, approvals: nil,
                       root: Dir.pwd, cwd: Dir.pwd, approval_prompt: nil, goal_driver: GoalDriver::Null, epic: nil)
          @role_spawn = role_spawn
          @goal_driver = goal_driver
          @root = root
          @cwd = cwd
          @library = library
          @ledger = ledger
          @sensitivity = sensitivity
          # The inline drain shares Frontend::ApprovalPolicy's prompt loop;
          # Wiring hands in one whose reader routes through the conductor.
          @approval_prompt = approval_prompt || Frontend::ApprovalPolicy.new
          @env = assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:,
                              model_switch:, mode_switch:, snapshots:, epic_driver: epic_driver(epic, chronicle))
        end

        attr_reader :env, :goal_driver

        # The run's ONE open changeset review: `/review` puts the round it opened
        # in, `/review-submit` takes it out and posts it. Memoized because two
        # outboxes would mean a review open in one command and absent from the
        # other. Public so a wiring spec can assert that the registered
        # `/review-submit` reads THIS one rather than an outbox of its own.
        def outbox = @outbox ||= Lain::Review::Submit::Outbox.new

        # The command surface the Repl consults ahead of SkillDispatch
        # (precedence is command-first by design): the registry curried over the
        # one Env, so the Repl dispatches with text alone. Memoized because two
        # calls answering different registries would split /help's listing from
        # the dispatchable set.
        def commands = @commands ||= registry.bind(@env)

        # The repl phase for every line no command claims, over the SAME library
        # /help lists. No `root:`: the snapshot is handed over, so the builder
        # has nothing left to read from disk.
        def middleware = @middleware ||= ReplMiddleware.build(role_spawn: @role_spawn, library: @library)

        private

        # What `/implement-epic` drives, resolved HERE rather than in {Wiring}
        # for the reason {ForkPoint} and {TmuxSurface} are built here:
        # assembling the collaborators a typed line reaches is this object's
        # whole job, and Wiring has no room left to hold another one.
        #
        # The mount inside the seams is the SEAT's -- never a second
        # {EpicMount.for}, which would put a second {Epic::Review} over one
        # journal and leave the regeneration guard guarding nothing. A chat in
        # no epic, and every spec that lends no seams, gets the refusing Null,
        # so the command is registered and answers everywhere.
        def epic_driver(epic, chronicle)
          return EpicDriver::Factory::Unmounted if epic.nil?

          epic.driver(root: @root, library: @library, chronicle:)
        end

        # The one Env assembly -- extracted so initialize stays the plain seeding
        # it reads as (the Metrics trip said so: extract, do not loosen). Only
        # `approvals` falls back, to the genuine {Env::NoApprovals} Null when the
        # session wired no queue.
        def assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:,
                         model_switch:, mode_switch:, snapshots:, epic_driver:)
          Env.new(
            status: status_feed, sessions: Lain::CLI::Sessions.new,
            approvals: approvals || Env::NoApprovals, supervisor:,
            replies:, fork_point: ForkPoint.new(dir: Paths.new.sessions_dir),
            tmux_surface: TmuxSurface.new, agent:, chronicle:,
            model_switch:, mode_switch:, role_spawn: @role_spawn, snapshots:, epic_driver:
          )
        end

        # The shipped set, assembled once. /help holds the LIVE registry, so a
        # command a later card registers here appears in its listing with no
        # edit of its own.
        def registry
          @registry ||= Registry.new(builtins).tap do |registry|
            registry.register(Help.new(registry:, catalog: @library.catalog))
            registry.register(Approve.new(prompt: @approval_prompt))
            registry.register(Model.new)
          end
        end

        # The shipped commands #registry has nothing to build for. What separates
        # this list from #registry is that #registry builds arguments (a live
        # registry, a catalog, a prompt) and this does not; the split is what
        # keeps #registry's ABC honest as the set grows.
        #
        # This list sits near Metrics/AbcSize's limit of 17 on its own, so a new
        # command joins a NAMED group (#history_commands, #review_commands) or
        # founds one, one splat here, rather than growing this line.
        def builtins
          [Quit.new, *history_commands, Btw.new, Status.new, Sessions.new, Inbox.new, Ruby.new, Mode.new,
           Goal.new(driver: @goal_driver), Meta.new(root: @root), Introspect.new(outbox:), *review_commands,
           *epic_commands]
        end

        # The commands of the epic this chat is seated in. Its own group rather
        # than another entry above, for the reason #builtins gives: that list
        # sits at Metrics/AbcSize's limit, so a new command founds a group.
        def epic_commands = [ImplementEpic.new]

        # The commands that move this session through its own history: its
        # conversation (`/rewind`), the files its turns wrote (`/undo`), a
        # sibling opened at its head (`/fork`), and the turns compaction must
        # keep (`/pin`, `/unpin`, `/keep`).
        def history_commands = [Rewind.new, Undo.new, Fork.new, Pin.new, Unpin.new, Keep.new]

        # The commands of one review: `/review` and `/survey` each open a round
        # into {#outbox} -- the run's ONE, which is what lets each refuse over
        # the other's open surface -- and `/review-submit` takes it out and posts
        # it. Their own line because they share {#outbox} AS A ROUND, where
        # `/introspect` is only a READER and could never disagree with them.
        def review_commands
          [Review.new(root: @root, outbox:), ReviewSubmit.new(root: @root, outbox:),
           Survey.new(cwd: @cwd, outbox:, ledger: @ledger, sensitivity: @sensitivity)]
        end
      end
    end
  end
end
