# frozen_string_literal: true

require "pathname"
require "mixlib/shellout"

module Lain
  module CLI
    # Turns `--isolation <name>` into the {Isolation} backend a run leases
    # workers from: which concrete backend, which decorators layer over it, and
    # where a worktree's checkouts live. The same seam {Backend} is for
    # `--provider` -- a validated name resolved in ONE place -- so chat, the
    # bench arm driver, and anything else that grows an `--isolation` flag agree
    # on what a backend name means, and {BACKENDS} is the single authority both
    # the resolution and their help text read.
    #
    # DECORATION IS BY NEED. A decorator that would provision nothing is not
    # added at all: no declared services means no service decorator, and a
    # journal that goes nowhere ({Channel::Null}) means no {Isolation::Journal}.
    # Both would be harmless no-ops if applied unconditionally -- this is a
    # legibility policy, not a correctness one. What it buys is that the
    # UNDECORATED cases stay identifiable: `resolve(nil)` is an
    # {Isolation::Null} and not a stack of pass-throughs around one, which is
    # what lets a spec (and a reader) see at a glance that a run got no
    # isolation. A caller that always passes a real journal -- which every
    # production wiring does -- never sees a bare backend, and does not need to:
    # the by-need rule costs it nothing.
    #
    # THE JOURNAL WRAPS NEAREST THE CONCRETE BACKEND, exactly once (see
    # {Isolation::Journal}'s own doc). Nearest, so the emitted record names the
    # backend that actually isolated the worker ({Isolation::Worktree}) rather
    # than a decorator over it; once, because a second wrap double-journals
    # every transition and corrupts lease accounting.
    #
    # A BAD FLAG IS REFUSED HERE, NOT AT THE FIRST ACQUIRE. `worktree` outside a
    # repository ({NotARepository}) and a compose declaration with no compose
    # file ({NoComposeFile}) are both operator mistakes about the environment
    # the run was started in, and both are cheap to detect now. Deferring them
    # to acquire surfaces them mid-run, after workers are dispatched, as a git
    # or docker error that buries what the operator actually got wrong.
    #
    # ONE PROJECT, ONE CONCURRENT ISOLATED RUN. The worktree root is keyed on
    # the REPOSITORY (see {#worktree_root}), and worker ids restart from 1 per
    # process, so two concurrent `--isolation worktree` runs of one project
    # target identical checkout paths -- and {Isolation::Worktree}'s
    # already-leased guard is a per-instance Set, so the second run's `#reap`
    # would force-remove the first's LIVE checkout. The repo-keyed root is a
    # deliberate trade, not an oversight: it is exactly what lets that reap
    # clear a CRASHED run's leftovers before the next add, which a per-run root
    # would leak forever. Until that trade is revisited, treat one concurrent
    # isolated run per project as a precondition of this backend.
    class IsolationBackend
      # An unrecognized `--isolation` name. Loud and naming the valid set, the
      # voice {Backend#provider_name} and {Role::Catalog.fetch} use; per the
      # error-taxonomy convention it subclasses {Lain::Error} next to the object
      # that raises it, so the exe layer maps it to a clean Thor::Error.
      class Unknown < Error; end

      # `--isolation worktree` outside a git repository. Refused HERE, at
      # resolution, rather than handed back as a backend that raises
      # {Isolation::Worktree::Refused} at the first acquire -- by then a run has
      # started, workers are dispatched, and the operator's actual mistake (a
      # flag that does not apply where they ran it) is buried under a git error.
      class NotARepository < Error; end

      # A `.lain/services.rb` declaring compose services in a project with no
      # compose file. {NotARepository}'s sibling, and refused for the same
      # reason at the same moment -- see the class doc.
      class NoComposeFile < Error; end

      # The backends `--isolation` selects between, in the order help text lists
      # them: the shared-process baseline first, since it is the default.
      BACKENDS = %w[none worktree].freeze

      # An unset flag arrives as nil, and this constant -- not a Thor default --
      # is what it falls through to, so one authority answers "what does no
      # `--isolation` mean?"
      DEFAULT = "none"

      # @return [#acquire] the resolved, decorated backend
      def self.resolve(...) = new(...).backend

      # @param name [String, nil] the `--isolation` value; nil means {DEFAULT}
      # @param root [String] the project the backend is resolved FOR: where
      #   `.lain/services.rb` is read from, and where the repository search
      #   starts
      # @param journal [#<<] where {Telemetry::IsolationLease} records land;
      #   the Null channel (the default) earns no journal decorator
      # @param paths [Paths] supplies the worktree root and the per-worker keys
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as a factory exactly as {Isolation::Worktree} and {Tools::Bash} do, so
      #   a spec substitutes it
      def initialize(name = nil, root: Dir.pwd, journal: Channel::Null.instance, paths: Paths.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @name = name || DEFAULT
        @root = File.expand_path(root)
        @journal = journal
        @paths = paths
        @shell_out_factory = shell_out_factory
      end

      # @return [#acquire] the concrete backend, journalled, then decorated by
      #   whatever the project declares
      # @raise [Unknown] on a name outside {BACKENDS}
      # @raise [NotARepository] for `worktree` outside a git repository
      def backend = with_compose(with_databases(journalled(concrete)))

      private

      def concrete
        case backend_name
        when "worktree" then worktree
        else Isolation::Null.new
        end
      end

      # Validated once, so the mapping above only ever sees a name already known
      # to be in {BACKENDS} -- {Backend#provider_name}'s shape.
      def backend_name
        return @name if BACKENDS.include?(@name)

        raise Unknown, "unknown isolation backend #{@name.inspect}, expected one of #{BACKENDS.inspect}"
      end

      def worktree
        repo = repo_root
        Isolation::Worktree.new(root: worktree_root(repo), repo_root: repo, paths: @paths,
                                shell_out_factory: @shell_out_factory)
      end

      # Keyed on the REPOSITORY, never on the cwd: two runs started in different
      # subdirectories of one project lease out of one root (so the reap of a
      # leftover checkout finds it), while two projects can never collide there.
      # Under {Paths#runtime_dir} rather than a state dir because a leased
      # checkout is ephemeral scratch that release always reclaims -- see
      # {Isolation::Worktree}'s "uncommitted work is scratch".
      def worktree_root(repo) = File.join(@paths.runtime_dir, "worktrees", @paths.project_hash(repo))

      # The repository `git worktree add` branches from, found by ascending from
      # the project -- so `lain --isolation worktree` works from a subdirectory
      # the way every other git-aware tool does. `.git` is a FILE inside a linked
      # worktree and a directory in a primary one, and `exist?` covers both.
      def repo_root
        found = Pathname.new(@root).ascend.find { |dir| dir.join(".git").exist? }
        return found.to_s if found

        raise NotARepository, "--isolation worktree needs a git repository to branch checkouts from, and " \
                              "#{@root} is not inside one; run it from a repository or use " \
                              "--isolation #{DEFAULT}"
      end

      # Read ONCE: both decorators partition the same declarations, and a second
      # read would let a `.lain/services.rb` edited mid-resolution give the two
      # of them different answers.
      def services = @services ||= Isolation::Services.load(root: @root)

      # {Isolation::DbIndex} provisions EVERY service it is handed -- unlike
      # {Isolation::Compose}, which selects its own declarations -- so it gets
      # only those that answer `#provision`. A compose declaration provisions
      # nothing itself; its stack does, one decorator out.
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

      # CHECKED, not injected. {Isolation::Compose} stays the authority on which
      # file it uses -- it re-resolves at acquire, off the same constant -- and
      # this only refuses early when there is none to find. Injecting the
      # resolved path instead would silently paper over a file DELETED between
      # resolve and acquire, which is a real failure the backend must still
      # reclaim its inner lease from.
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
