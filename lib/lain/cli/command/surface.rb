# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # Assembles everything a typed `you>` line can hit before the model --
      # extracted from {Wiring} because "what a line dispatches through" is its
      # own responsibility (the Metrics trip said so: extract, do not loosen):
      #
      # * the frozen, nil-free {Env} every command reads, built ONCE from the
      #   collaborators Wiring wired -- every reader but one is a required
      #   collaborator (a mis-wire is a loud ArgumentError here, never a
      #   fail-open Null), and an unattended run wires no approval queue, so
      #   the queue-shaped {Env::NoApprovals} keeps that ONE reader nil-free;
      # * the shipped command {Registry}, bound over that Env ({#commands});
      # * the skill middleware ({#middleware}) over the SAME catalog snapshot
      #   the registry's /help lists, so listing and dispatch can never drift.
      #
      # `library:` is the run's ONE {Skill::Library}, loaded at
      # {Backend#library} and injected by Wiring, so this surface,
      # {Tools::RunSkill} and {Backend#context}'s system prompt are readers of
      # one `.lain/` read rather than separate reads of the same tree. It
      # arrived as a `(catalog:, slots:)` pair before the Library named it.
      #
      # A later command card lands as one require in cli/command.rb, one
      # register line in {#registry}, and -- when it needs a new Env reader --
      # one line in the {Env} assembly here.
      class Surface
        # `chronicle:`, `status_feed:`, `model_switch:`, `mode_switch:`,
        # `role_spawn:` and `library:` are all required, not defaulted -- each is
        # always wired in the live path, so a defaulted Null here would only mask
        # a mis-wire. The mode switch is the sharpest case of that rule: it is the
        # slot that actually reaches the gate, since {CLI::Switchboard#apply}
        # DERIVES the gate policy from the flip, so a defaulted one would fail
        # OPEN -- `/mode plan` would report success against a slot no gate and no
        # toolset ever reads. A forgotten keyword must be a loud
        # ArgumentError at construction, not a quiet degrade far from the bug.
        # That applies to the library exactly as it does to the rest: a from-disk
        # default here would silently be a SECOND read of the same tree, which is
        # exactly the bug that injection removed.
        #
        # `root:` survives the library, on its own business: {Meta} reads the
        # project's `.lain/` config from it. It no longer feeds a snapshot load.
        #
        # `cwd:` is the OTHER half of {Lain::Project} and a different question --
        # root is the authority boundary, cwd is where a relative path resolves,
        # and a monorepo chat stands in a subtree while its root sits at the
        # repository top. {Survey} names every file of a survey from it, because
        # the attached editor resolves a row against the directory it was started
        # in and `lain up` gives both panes one `-c`. Threaded rather than left
        # to each command's own default so the run answers ONE directory.
        #
        # `ledger:` is required on exactly the same terms and for the sharpest
        # version of the reason: {Lain::Sensitivity::Ledger} states no-default as
        # a rule of its own, because a defaulted one lets a forgotten injection
        # become a SECOND ledger whose releases nobody ever sees -- `/survey`
        # would mask regions this run has already released, with every object
        # present and nothing about the wiring looking wrong.
        def initialize(agent:, replies:, supervisor:, role_spawn:, chronicle:, status_feed:,
                       model_switch:, mode_switch:, library:, ledger:, approvals: nil, root: Dir.pwd,
                       cwd: Dir.pwd, approval_prompt: nil, goal_driver: GoalDriver::Null)
          @role_spawn = role_spawn
          @goal_driver = goal_driver
          @root = root
          @cwd = cwd
          @library = library
          @ledger = ledger
          # The inline drain shares Frontend::ApprovalPolicy's prompt loop;
          # Wiring hands in one whose reader routes through the conductor.
          @approval_prompt = approval_prompt || Frontend::ApprovalPolicy.new
          @env = assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:,
                              model_switch:, mode_switch:)
        end

        attr_reader :env, :goal_driver

        # The run's ONE open changeset review: `/review` puts the round it
        # opened in, `/review-submit` takes it out and posts it. Memoized for
        # {#commands}' reason and sharper -- two outboxes would mean a review
        # that is open in one command and absent from the other, with every
        # object present and nothing to see.
        #
        # Public because it is a run-scoped collaborator this class assembles,
        # like {#env}: it is what lets a wiring spec assert that the registered
        # `/review-submit` reads THIS one rather than an outbox of its own.
        def outbox = @outbox ||= Lain::Review::Submit::Outbox.new

        # The command surface the Repl consults ahead of SkillDispatch
        # (precedence is command-first by design): the registry curried over
        # the one Env, so the Repl dispatches with text alone. Memoized, like
        # every reader here: two calls MUST answer the same bound registry, or
        # /help's listing and the dispatchable set could silently be two
        # disjoint registries (panel fix 1).
        def commands = @commands ||= registry.bind(@env)

        # The repl phase for every line no command claims, over the SAME library
        # /help lists and the run's other renderers hold. No `root:`: the
        # snapshot is handed over, so the builder has nothing left to read from
        # disk. Memoized for the one-assembly reason {#commands} gives.
        def middleware = @middleware ||= ReplMiddleware.build(role_spawn: @role_spawn, library: @library)

        private

        # The one Env assembly -- extracted so initialize stays the plain
        # seeding it reads as (the Metrics trip said so: extract, do not
        # loosen). Every reader is a required live collaborator; only
        # `approvals` falls back, to the genuine {Env::NoApprovals} Null when
        # the session wired no queue.
        def assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:,
                         model_switch:, mode_switch:)
          Env.new(
            status: status_feed, sessions: Lain::CLI::Sessions.new,
            approvals: approvals || Env::NoApprovals, supervisor:,
            replies:, fork_point: ForkPoint.new(dir: Paths.new.sessions_dir),
            tmux_surface: TmuxSurface.new, agent:, chronicle:,
            model_switch:, mode_switch:, role_spawn: @role_spawn
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

        # The shipped commands that need nothing #registry has to build for them
        # -- most take no argument at all, and the four that do (`/goal`,
        # `/meta`, `/introspect`, and the review trio one line down) take a
        # collaborator this class already holds. "Parameterless" was the
        # criterion when the list was one, and it stopped being true: what
        # actually separates this from #registry is that #registry builds
        # arguments (a live registry, a catalog, a prompt) and this does not.
        #
        # Split out so #registry's ABC stays honest as the set grows (/btw and
        # /keep were later additions): each `.new` is an ABC method call, and
        # this list is data, not the registration behavior #registry owns.
        #
        # ⚠️ THAT SPLIT HAS NOW RUN OUT ITSELF: with `/introspect` this method
        # measures 17.0 against Metrics/AbcSize's limit of 17, so the NEXT
        # command added here trips the cop. The answer is another extraction (a
        # named group, as #review_commands already is), never a loosened limit.
        def builtins
          [Quit.new, Rewind.new, Pin.new, Unpin.new, Fork.new, Btw.new, Keep.new, Status.new, Sessions.new,
           Inbox.new, Ruby.new, Mode.new, Goal.new(driver: @goal_driver), Meta.new(root: @root),
           Introspect.new(outbox:), *review_commands]
        end

        # The commands of one review: `/review` and `/survey` each open a round
        # into {#outbox} -- the run's ONE, which is what lets each refuse over
        # the other's open surface -- and `/review-submit` takes it out and posts
        # it. Their own line because they are the group that shares {#outbox}
        # AS A ROUND -- each holds one in or takes one out, so a second outbox
        # would be a review open in one command and absent from another. That is
        # a different relationship from `/introspect`'s, which is a READER: it
        # reports the round these three own and could never disagree with them
        # about one, because it never writes. And because #builtins reached its
        # ABC budget, which is the same pressure saying the same thing.
        def review_commands
          [Review.new(root: @root, outbox:), ReviewSubmit.new(root: @root, outbox:),
           Survey.new(root: @root, cwd: @cwd, outbox:, ledger: @ledger)]
        end
      end
    end
  end
end
