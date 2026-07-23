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
      #   fail-open Null), and --yolo wires no approval queue, so the
      #   queue-shaped {Env::YoloApprovals} keeps that ONE reader nil-free;
      # * the shipped command {Registry}, bound over that Env ({#commands});
      # * the skill middleware ({#middleware}) over the SAME catalog snapshot
      #   the registry's /help lists, so listing and dispatch can never drift.
      #
      # A later command card lands as one require in cli/command.rb, one
      # register line in {#registry}, and -- when it needs a new Env reader --
      # one line in the {Env} assembly here.
      class Surface
        # `chronicle:`, `status_feed:`, `policy_switch:`, `model_switch:`, and
        # `role_spawn:` are all required, not defaulted -- each is always wired
        # in the live path, so a defaulted Null here would only mask a mis-wire
        # (a permissive policy_switch/model_switch would even fail OPEN: a
        # silently disconnected gate). A forgotten keyword must be a loud
        # ArgumentError at construction, not a quiet degrade far from the bug.
        def initialize(agent:, replies:, supervisor:, role_spawn:, chronicle:, status_feed:, policy_switch:,
                       model_switch:, approvals: nil, root: Dir.pwd, approval_prompt: nil,
                       goal_driver: GoalDriver::Null)
          @role_spawn = role_spawn
          @goal_driver = goal_driver
          @root = root
          @catalog = Skill::Catalog.load(root:)
          # T14's inline drain shares Frontend::ApprovalPolicy's prompt loop;
          # Wiring hands in one whose reader routes through the conductor.
          @approval_prompt = approval_prompt || Frontend::ApprovalPolicy.new
          @env = assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:,
                              policy_switch:, model_switch:)
        end

        attr_reader :env, :goal_driver

        # The T9 command surface the Repl consults ahead of SkillDispatch
        # (precedence is command-first by design): the registry curried over
        # the one Env, so the Repl dispatches with text alone. Memoized, like
        # every reader here: two calls MUST answer the same bound registry, or
        # /help's listing and the dispatchable set could silently be two
        # disjoint registries (panel fix 1).
        def commands = @commands ||= registry.bind(@env)

        # The repl phase for every line no command claims, over this surface's
        # own catalog snapshot. Memoized for the same one-assembly reason.
        def middleware = @middleware ||= ReplMiddleware.build(role_spawn: @role_spawn, root: @root, catalog: @catalog)

        private

        # The one Env assembly -- extracted so initialize stays the plain
        # seeding it reads as (the Metrics trip said so: extract, do not
        # loosen). Every reader is a required live collaborator; only
        # `approvals` falls back, to the genuine {Env::YoloApprovals} Null when
        # --yolo wired no queue.
        def assemble_env(agent:, replies:, supervisor:, approvals:, chronicle:, status_feed:, policy_switch:,
                         model_switch:)
          Env.new(
            status: status_feed, sessions: Lain::CLI::Sessions.new,
            approvals: approvals || Env::YoloApprovals, supervisor:,
            replies:, fork_point: ForkPoint.new(dir: Paths.new.sessions_dir),
            tmux_surface: TmuxSurface.new, agent:, chronicle:,
            policy_switch:, model_switch:, role_spawn: @role_spawn
          )
        end

        # The shipped set, assembled once. /help holds the LIVE registry, so a
        # command a later card registers here appears in its listing with no
        # edit of its own.
        def registry
          @registry ||= Registry.new(builtins).tap do |registry|
            registry.register(Help.new(registry:, catalog: @catalog))
            registry.register(Approve.new(prompt: @approval_prompt))
            registry.register(Yolo.new)
            registry.register(Model.new)
          end
        end

        # The parameterless commands, split out so #registry's ABC stays honest
        # as the set grows (T17 added /btw and /keep): each `.new` is an ABC
        # method call, and this list is data, not the registration behavior
        # #registry owns.
        def builtins
          [Quit.new, Rewind.new, Fork.new, Btw.new, Keep.new, Status.new, Sessions.new, Inbox.new,
           Ruby.new, Goal.new(driver: @goal_driver), Meta.new(root: @root)]
        end
      end
    end
  end
end
