# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    # Turns `--isolation <name>` into the {Isolation} backend a run leases
    # workers from. The same seam {Backend} is for `--provider` -- a validated
    # name resolved in ONE place -- so every caller that grows an `--isolation`
    # flag agrees on what a backend name means, and {BACKENDS} is the single
    # authority both the resolution and the help text read.
    #
    # DECORATION IS BY NEED, a legibility policy rather than a correctness one:
    # applying every decorator unconditionally would be harmless, but then the
    # UNDECORATED cases stop being identifiable, and `resolve(nil)` reading as
    # an {Isolation::Null} rather than a stack of pass-throughs is what lets a
    # spec (and a reader) see at a glance that a run got no isolation.
    #
    # THE JOURNAL WRAPS NEAREST THE CONCRETE BACKEND, exactly once (see
    # {Isolation::Journal}'s own doc). Nearest, so the emitted record names the
    # backend that actually isolated the worker rather than a decorator over
    # it; once, because a second wrap double-journals every transition and
    # corrupts lease accounting.
    #
    # A BAD FLAG IS REFUSED HERE, NOT AT THE FIRST ACQUIRE. `worktree` outside a
    # repository ({NotARepository}) and a compose declaration with no compose
    # file ({NoComposeFile}) are both operator mistakes about the environment
    # the run was started in, and both are cheap to detect now. Deferring them
    # to acquire surfaces them mid-run, after workers are dispatched, as a git
    # or docker error that buries what the operator actually got wrong.
    #
    # ONE PROJECT, ONE CONCURRENT ISOLATED RUN -- a precondition of this
    # backend, and a deliberate trade. The worktree root is keyed on the
    # REPOSITORY (see {.worktree_root}) and worker ids restart from 1 per
    # process, so two concurrent `--isolation worktree` runs of one project
    # target identical checkout paths. The second run's acquire finds the
    # first's checkout locked by a live process and REFUSES, naming it, rather
    # than touching it ({Isolation::Worktree::Leftover}). The repo-keyed root
    # is what lets a later run clear a CRASHED run's leftovers -- moved aside,
    # never destroyed -- which a per-run root would leak forever.
    class IsolationBackend
      # An unrecognized `--isolation` name. Subclasses {Lain::Error} next to
      # the object that raises it, so the exe layer maps it to a clean
      # Thor::Error.
      class Unknown < Error; end

      # `--isolation worktree` outside a git repository. Refused HERE rather
      # than as an {Isolation::Worktree::Refused} at the first acquire -- by
      # then a run has started, workers are dispatched, and the operator's
      # actual mistake is buried under a git error.
      class NotARepository < Error; end

      # A `.lain/services.rb` declaring compose services in a project with no
      # compose file. {NotARepository}'s sibling, and refused for the same
      # reason at the same moment -- see the class doc.
      class NoComposeFile < Error; end

      # `--isolation worktree` where the repository search cannot be BOUNDED:
      # its walk stops at the refusal set, and the refusal set needs a usable
      # `$HOME`. Its own class rather than {NotARepository} because the cause
      # differs in kind -- there may well be a repository; nothing could go
      # looking for it -- and its own message because
      # {Project::Resolver::UnusableHome}'s names neither the flag the operator
      # passed nor the variable they have to set. A container run with a uid
      # that has no `/etc/passwd` entry is the realistic way to reach it.
      class UnboundedSearch < Error
        def initialize(cause)
          super("--isolation worktree bounds its repository search at $HOME, and #{cause.message}; " \
                "set HOME to the user's home directory, or use --isolation #{DEFAULT}")
        end
      end

      # In the order help text lists them: the shared-process baseline first,
      # since it is the default.
      BACKENDS = %w[none worktree].freeze

      # An unset flag arrives as nil and falls through to this constant, not a
      # Thor default, so one authority answers "what does no `--isolation`
      # mean?"
      DEFAULT = "none"

      # @return [#acquire] the resolved, decorated backend
      def self.resolve(...) = new(...).backend

      # Keyed on the REPOSITORY, never on the cwd: two runs started in
      # different subdirectories of one project lease out of one root (so the
      # clearing of a leftover checkout finds it), while two projects never
      # collide. Under {Paths#state_home}, not the tmpfs runtime dir, because a
      # checkout is retained for `[isolation] retain_days` and a reboot must not
      # cut that short.
      #
      # @param repo [String] the repository, as {Project::Repository.nearest} found it
      # @param paths [Paths]
      # @return [String]
      def self.worktree_root(repo, paths:) = File.join(paths.state_home, "worktrees", paths.project_hash(repo))

      # `realpath`, not `expand_path`. This object and {Project::Resolver} both
      # ascend for `.git`, and they once ascended DIFFERENT ancestries: a
      # symlink whose lexical parent holds a repository its real parent does
      # not made the resolver answer the plain leaf and this walk answer the
      # trap. {Project::Resolver.resolved} is the resolver's own spelling of
      # it, and keeps the tolerance a lexical expansion had for a root naming
      # nothing on disk.
      #
      # @param name [String, nil] the `--isolation` value; nil means {DEFAULT}
      # @param root [String] the project the backend is resolved FOR: where
      #   `.lain/services.rb` is read from, and where the repository search
      #   starts
      # @param journal [#<<] where {Telemetry::IsolationLease} records land;
      #   the Null channel (the default) earns no journal decorator
      # @param paths [Paths] supplies the worktree root, the per-worker keys,
      #   and the three XDG bases {#repo_root}'s stop rule names
      # @param home [String, nil] the user's home directory, read from `ENV` by
      #   the CALLER and injected here; consulted only by {#repo_root}, so
      #   `--isolation none` neither needs it nor refuses a run that has none.
      #   NOT `Dir.home`, which the cop disabled below asks for: with `HOME`
      #   unset it falls through to getpwuid and raises a bare ArgumentError,
      #   where `nil` reaches {Project::Resolver::Home} and is refused there by
      #   name -- renamed once more, to {UnboundedSearch}, so the message says
      #   which flag to drop.
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as a factory so a spec substitutes it
      def initialize(name = nil, root: Dir.pwd, journal: Channel::Null.instance, paths: Paths.new,
                     home: ENV.fetch("HOME", nil), # rubocop:disable Style/EnvHome -- see the `home:` tag
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @name = name || DEFAULT
        @root = Project::Resolver.resolved(File.expand_path(root), File)
        @journal = journal
        @paths = paths
        @home = home
        @shell_out_factory = shell_out_factory
      end

      # @return [#acquire] the concrete backend, journalled, then decorated by
      #   whatever the project declares
      # @raise [Unknown] on a name outside {BACKENDS}
      # @raise [NotARepository] for `worktree` outside a git repository
      # @raise [Isolation::WorkingBranch::Refused] for `worktree` on a detached HEAD
      def backend = with_compose(with_databases(journalled(concrete)))

      private

      # The `none` branch is built with the same root/paths/home this object
      # resolves `worktree` from, so its `#repo_root` answers the repository
      # THIS run would cut from, not an unrelated one found from the process cwd.
      def concrete
        case backend_name
        when "worktree" then worktree
        else Isolation::Null.new(root: @root, paths: @paths, home: @home)
        end
      end

      # Validated once, so the mapping above only ever sees a name already
      # known to be in {BACKENDS}.
      def backend_name
        return @name if BACKENDS.include?(@name)

        raise Unknown, "unknown isolation backend #{@name.inspect}, expected one of #{BACKENDS.inspect}"
      end

      def worktree
        repo = repo_root
        Isolation::Worktree.new(root: self.class.worktree_root(repo, paths: @paths), repo_root: repo,
                                base: working_branch(repo), paths: @paths, shell_out_factory: @shell_out_factory)
      end

      # Named HERE, which for chat is launch: the branch the parent stands on
      # now is the one every child is cut from and handed back to, whatever
      # the checkout is switched to later. A detached HEAD is refused at this
      # moment for the reason {NotARepository} is.
      def working_branch(repo)
        Isolation::WorkingBranch.checked_out(repo_root: repo, shell_out_factory: @shell_out_factory)
      end

      # The repository `git worktree add` branches from, found by ascending
      # from the project through {Project::Repository}.
      def repo_root
        nearest = nearest_repository
        return nearest.path if nearest.found?

        raise NotARepository, "--isolation worktree needs a git repository to branch checkouts from, and " \
                              "#{nearest.searched(@root)}; run it from a repository or use " \
                              "--isolation #{DEFAULT}"
      end

      # Searched HERE and not in #initialize, so `--isolation none` pays neither
      # the `stat` per ancestor nor the {Project::Resolver::UnusableHome}
      # refusal an absent `$HOME` earns: only the worktree branch walks.
      def nearest_repository
        Project::Repository.nearest(@root, paths: @paths, home: @home)
      rescue Project::Resolver::UnusableHome => e
        raise UnboundedSearch, e
      end

      # Read ONCE: both decorators partition the same declarations, and a
      # second read would let a `.lain/services.rb` edited mid-resolution give
      # them different answers.
      def services = @services ||= Isolation::Services.load(root: @root)

      # {Isolation::DbIndex} provisions EVERY service it is handed -- unlike
      # {Isolation::Compose}, which selects its own declarations -- so it gets
      # only those that answer `#provision`.
      def with_databases(inner)
        declared = services.select { |service| service.respond_to?(:provision) }
        return inner if declared.empty?

        Isolation::DbIndex.new(services: declared, inner:, paths: @paths,
                               shell_out_factory: @shell_out_factory)
      end

      def with_compose(inner)
        declared = services.grep(Isolation::Services::Compose)
        return inner if declared.empty?

        refuse_without_compose_file
        Isolation::Compose.new(services: declared, inner:, paths: @paths, project_root: @root,
                               shell_out_factory: @shell_out_factory)
      end

      # CHECKED, not injected. {Isolation::Compose} stays the authority on
      # which file it uses; this only refuses early when there is none to find.
      # Injecting the resolved path would silently paper over a file DELETED
      # between resolve and acquire, which is a real failure the backend must
      # still reclaim its inner lease from.
      def refuse_without_compose_file
        names = Isolation::Compose::COMPOSE_FILE_NAMES
        return if names.any? { |name| File.exist?(File.join(@root, name)) }

        raise NoComposeFile, "#{Isolation::Services::DSL_PATH} declares compose services but there is no " \
                             "compose file in #{@root} (looked for #{names.join(", ")}); add one, or drop " \
                             "the compose declaration"
      end

      def journalled(inner)
        return inner if @journal.is_a?(Channel::Null)

        Isolation::Journal.new(backend: inner, journal: @journal)
      end
    end
  end
end
