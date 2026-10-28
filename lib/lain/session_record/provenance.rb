# frozen_string_literal: true

require "concurrent/map"
require "digest"

module Lain
  module SessionRecord
    Provenance = Data.define(:harness, :tool_surface, :effort, :policy, :cwd, :root, :home, :weights)

    # What produced a run, as one header block: the lain that ran it, the tools
    # it offered, the effort it asked for, the project policy it ran under, where
    # it ran and, for a local model, which weights it ran. Two runs that differ in
    # any of these are not comparable, and a reader can only tell that if the
    # header says so.
    #
    # Every field but the weights is a String, and a value nobody could read is
    # {UNRECORDED} rather than nil, so a reader compares two headers without a
    # nil case. The weights are a {Provider::ModelIdentity} or nil, and nil means
    # the provider has no weights to name, so the header gains no key.
    #
    # The harness covers source, not builds: gitignored artifacts such as
    # `lib/lain/lain.so` and `target/release/lain-fence` are outside it, so a
    # rebuild from unchanged source records the same harness.
    class Provenance
      include Declarative

      UNRECORDED = "unrecorded"

      # @return [Array<Symbol>] the members recorded as strings
      STRINGS = (members - %i[weights]).freeze

      declare { STRINGS.each { |name| attribute name, :lain_interned } }

      # The trees whose uncommitted edits change what lain does when it runs.
      HARNESS_TREES = %w[lib ext crates exe].freeze

      # Seconds a launch waits on one git call before recording no harness.
      GIT_TIMEOUT = 5

      # Plumbing with every output knob pinned, so a user's diff, color or
      # abbrev settings cannot change the bytes digested.
      DIFF = %w[diff-index -p --binary --full-index --no-color --no-textconv --no-ext-diff HEAD --].freeze

      # The repo's own .gitignore files only, never the user's core.excludesFile.
      UNTRACKED = %w[ls-files -z --others --exclude-per-directory=.gitignore --].freeze

      # A session started with nothing measured writes no block at all.
      module Absent
        # @return [Hash] empty, so the header gains no key
        def self.to_header = {}
      end

      # The harness of THIS process, read at its first launch and kept: eager
      # loading put its code in memory at boot, so a later edit on disk is not
      # what it runs.
      RUNNING = Concurrent::Map.new

      class << self
        # @param toolset [Toolset] the tools the run offers
        # @param root [String, nil] the project root
        # @param cwd [String, nil] where relative paths resolve
        # @param home [String, nil] whose dotfiles the run could read
        # @param effort [String, nil] what the context asks the model for
        # @param policy [String] {.policy}'s digest of the config the run is under
        # @param weights [Provider::ModelIdentity, nil] what the provider states it ran
        # @param harness [String] which lain ran; this process's own by default
        # @return [Provenance]
        def current(toolset:, root:, cwd:, home:, effort:, policy:, weights: nil, harness: running_harness)
          new(harness:, tool_surface: toolset.digest, effort:, policy:, cwd:, root:, home:, weights:)
        end

        # @return [String] {.harness} of the installed lain, computed on the first call only
        def running_harness = RUNNING.compute_if_absent(:harness) { harness }

        # Diffing against HEAD reads only what changed, so the cost follows the
        # size of the edit rather than the size of the tree.
        #
        # @param git [Class] builds a command the way {Shell::Out} does
        # @param gem_root [String] the lain checkout whose HEAD is recorded
        # @return [String] `<HEAD sha>+<digest of the uncommitted changes>`, or {UNRECORDED}
        def harness(git: Shell::Out, gem_root: Paths::Shipped::GEM_ROOT)
          head = run(git, gem_root, "rev-parse", "--show-toplevel", "HEAD")
          toplevel, sha = head&.stdout&.lines(chomp: true)
          return UNRECORDED unless sha && toplevel == File.realpath(gem_root)

          changes = uncommitted(git, gem_root)
          changes ? "#{sha}+#{Canonical.digest(changes)}" : UNRECORDED
        rescue SystemCallError, Shell::Out::Timeout
          UNRECORDED
        end

        # A launch in `project`: the policy is the Ruby it runs, its
        # `.lain/*.rb` and the user's config.rb.
        #
        # @param project [Project] where the run belongs and where it runs from
        # @param toolset [Toolset] the tools the run offers
        # @param effort [String, nil] what the context asks the model for
        # @param paths [Paths] the user's home and config.rb
        # @param weights [Provider::ModelIdentity, nil] what the provider states it ran
        # @return [Provenance]
        def launched(project:, toolset:, effort:, paths: Paths.new, weights: nil)
          current(toolset:, root: project.root, cwd: project.cwd, home: paths.home_or_nil, effort:, weights:,
                  policy: policy(project_dir: ProjectDir.new(root: project.root, paths:), paths:))
        end

        # The project's content digest, which names files by basename and ignores
        # the root, so a clone holding the same bytes elsewhere is the same policy.
        #
        # @param project_dir [ProjectDir] whose `.lain/*.rb` the run evaluates
        # @param paths [Paths] where the user's config.rb lives
        # @return [String]
        def policy(project_dir:, paths: Paths.new)
          policy_of(Project::Trust.for(project_dir:, paths:), Project::Trust.for_user(paths:))
        end

        # The policy digest over two trusts already read, and the one formula for it.
        #
        # @param project [Project::Trust] the project's `.lain/*.rb`
        # @param user [Project::Trust] the user's config
        # @return [String]
        def policy_of(project, user) = Canonical.digest([project.content_digest, user.digest])

        private

        # An untracked file is an uncommitted change too, and `git diff` never shows one.
        def uncommitted(git, gem_root)
          diff = run(git, gem_root, *DIFF, *HARNESS_TREES)
          untracked = run(git, gem_root, *UNTRACKED, *HARNESS_TREES)
          return nil unless diff && untracked

          { "diff" => Digest::SHA256.hexdigest(diff.stdout),
            "untracked" => untracked.stdout.split("\0").sort.to_h { |path| [path, entry_digest(gem_root, path)] } }
        end

        # Only a regular file is opened: a FIFO would block the launch, and a
        # link, a nested repo or a locked file says what it is instead.
        def entry_digest(gem_root, path)
          full = File.join(gem_root, path)
          case (type = File.lstat(full).ftype)
          when "link" then "link:#{File.readlink(full)}"
          when "file" then readable_digest(full)
          else type
          end
        end

        def readable_digest(full) = File.readable?(full) ? Digest::SHA256.file(full).hexdigest : "unreadable"

        def run(git, gem_root, *)
          out = git.new("git", "-C", gem_root, *, environment: Isolation::Worktree::GIT_CONTEXT_SCRUB,
                                                  timeout: GIT_TIMEOUT).run_command
          Shell::Out.ok?(out) ? out : nil
        end
      end

      def initialize(weights: nil, **strings)
        unknown = strings.keys - STRINGS
        raise ArgumentError, "unknown keyword: #{unknown.map(&:inspect).join(", ")}" if unknown.any?

        super(**self.class.settle!(**STRINGS.to_h { [_1, strings[_1] || UNRECORDED] }), weights:)
      end

      # @return [Hash{String=>Hash{String=>String}}] every field, nested under one key
      def to_header
        fields = to_h.except(:weights).transform_keys(&:to_s)
        fields["weights"] = weights.to_h.transform_keys(&:to_s) if weights
        { "provenance" => fields }
      end
    end
  end
end
