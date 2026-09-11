# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      Handback = Data.define(:handoff, :sync)

      # How a worker's work comes home on the chat path: the
      # {Isolation::WorkerHandoff} a one-shot child's lease ends in -- the same
      # one the {Supervisor} surrenders a crashed actor through, so the two
      # lanes cannot hand work back to different places -- and the
      # {Isolation::SelfSync} that rebases a child onto the working branch
      # before that handback runs.
      #
      # Built from the fleet's isolation, which names the working branch, and
      # from the project's `[isolation]` table, which names the merge strategy
      # and the rebase retries. With no branch named no checkout was cut, so
      # nothing is synced and the handoff only releases: a handback run over
      # the chat's own tree would read the human's work as a worker's.
      #
      # Reopened rather than declared in a `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing class.
      class Handback
        # The resolver a conflict spawns is the run's ONE {Skill::RoleSpawn},
        # which {ToolsetBuild} builds after the {Supervisor} holding this
        # handoff. So it is read at call time, never captured, and never built
        # twice: a second RoleSpawn would be a second answer to which seam a
        # child spawns over.
        LateResolver = Data.define(:role_spawn) do
          def call(role_name, context_mode, prompt) = role_spawn.call.call(role_name, context_mode, prompt)
        end

        # A file the whole chat reads cannot take the chat down with it, and a
        # worker handed back with lain's defaults is still handed back.
        UNREAD = "the [isolation] settings in .lain/config.toml were not read, so workers hand back " \
                 "with lain's defaults: %<reason>s"

        # The sync defaults to nothing, which is what a handoff with no
        # working branch needs. Resolved in the signature, at call time,
        # because `lain/cli` loads before `lain/isolation`.
        def initialize(handoff:, sync: Isolation::SelfSync::Null) = super

        def self.none = new(handoff: Isolation::WorkerHandoff::Null)

        # @param isolation [#base] the fleet's backend; its working branch is
        #   the only branch a handback lands on and the one a worker syncs onto
        # @param root [String] the project root `.lain/config.toml` is read under
        # @param journal [#<<] where the handback and sync records land
        # @param role_spawn [#call] a thunk reading the run's {Skill::RoleSpawn}
        # @param notice [#call, nil] told when the settings could not be read
        # @return [Handback]
        def self.for(isolation:, root:, journal:, role_spawn:, notice: nil)
          base = isolation.base
          return none if base.name.empty?

          settings = settings(root, notice)
          strategy = Isolation::MergeStrategy.from(settings)
          new(handoff: Isolation::WorkerHandoff.over(repo_root: toplevel(root), base:, journal:, strategy:,
                                                     resolver: LateResolver.new(role_spawn:)),
              sync: Isolation::SelfSync.new(base:, strategy:, retries: settings.rebase_retries))
        end

        def self.settings(root, notice)
          Config.load(root:).isolation
        rescue Lain::Error, SystemCallError => e
          notice&.call(format(UNREAD, reason: e.message))
          Config::Isolation.empty
        end

        # The checkout the human is standing in, which is the one the fleet's
        # worktrees were cut from: conflicted paths come back relative to it,
        # and a project root below it would name files that are not there.
        def self.toplevel(root)
          shell = Isolation::Checkout.new(File.expand_path(root)).run("rev-parse", "--show-toplevel")
          return shell.stdout.strip if shell.exitstatus.zero?

          raise Error, "#{root} is in no git checkout to hand workers back to: #{shell.stderr.strip}"
        end

        private_class_method :settings, :toplevel
      end
    end
  end
end
