# frozen_string_literal: true

module Lain
  module QA
    # The revisions a QA pass is about: a base the work started from, the head
    # it reached, and the paths that differ between them. Read from git once,
    # then a value, so every rung and every finding quotes the same range.
    Changeset = Data.define(:base, :head, :changed) do
      # Two-dot, so `changed` is the difference between the two commits rather
      # than the work done since they parted. A base that has itself moved on
      # therefore attributes its own commits to this pass; hand a base the head
      # descends from.
      #
      # @param root [String] the checkout to read
      # @param base [String] any revision git resolves
      # @param git [#run, #operation_in_progress?] built over `root` unless lent
      # @return [Changeset]
      # @raise [Lain::Error] when git is half way through an operation, or
      #   cannot resolve either end or diff them
      def self.read(root:, base:, git: Isolation::Checkout.new(root))
        raise Error, refusal(root) if git.operation_in_progress?

        from = resolved(git, base)
        to = resolved(git, "HEAD")
        new(base: from, head: to, changed: paths(git!(git, "diff", "--name-only", "-z", "--no-renames", from, to)))
      end

      # Half way through a merge or a rebase, HEAD is behind the work, so the
      # diff is partial or empty and every card in the plan reads as a claim
      # nobody performed.
      def self.refusal(root)
        "QA will not read a changeset from a checkout with a git operation in progress: #{root}. " \
          "Finish or abort it, or point QA at a clean checkout of the head."
      end

      # `-z` for the reason {Isolation::Checkout#unmerged} gives. The tag is
      # UTF-8 rather than that method's FILESYSTEM because the comparand
      # decides it: these paths are compared against strings scanned out of a
      # markdown plan, which Ruby read as UTF-8, and not against the disk. A
      # locale-derived tag is US-ASCII under `LC_ALL=C`, where the same bytes
      # then compare unequal and every non-ASCII path becomes a false finding.
      # `--no-renames`, because a rename is two claims and one folded entry
      # would read as an unperformed claim on the path that went.
      def self.paths(stdout) = stdout.split("\0").map { |path| path.force_encoding(Encoding::UTF_8) }

      def self.resolved(git, revision) = git!(git, "rev-parse", "--verify", "--quiet", "#{revision}^{commit}").strip

      def self.git!(git, *args)
        shell = git.run(*args)
        return shell.stdout if shell.exitstatus.zero?

        raise Error, "QA could not read the changeset: `git #{args.join(" ")}` failed #{shell.stderr.to_s.strip}".strip
      end
      private_class_method :refusal, :resolved, :git!, :paths

      def initialize(base:, head:, changed:)
        super(base: -base.to_s, head: -head.to_s, changed: changed.map { |path| -path.to_s }.freeze)
      end

      # The range every finding's reproduction quotes, in short SHAs a human
      # can paste.
      def range = "#{base[0, 12]}..#{head[0, 12]}"
    end
  end
end
