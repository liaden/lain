# frozen_string_literal: true

require "digest"

module Lain
  module Review
    class Queue
      # What is unfinished in one checkout: its unmerged branches, its dirty
      # tree and its recent commits. Listing is read-only; a dirty tree is
      # named by a digest of its status and is turned into a commit only when
      # a review of it opens.
      class LocalChanges
        # What a row asks a review to open. `head` is nil for a dirty tree,
        # which has no commit until it is snapshotted.
        Request = Data.define(:kind, :repo_root, :base, :head)

        # @param repo_root [String] the checkout to list
        # @param since [String] how far back a commit still counts as recent
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, since: "1 day ago", shell_out_factory: Shell::Out.public_method(:new))
          @root = File.expand_path(repo_root)
          @since = since
          @git = Isolation::Checkout.of(@root, shell_out_factory:)
        end

        # @return [Array<Row>] branches, then the dirty tree, then recent commits
        def call
          tip = @git.target("HEAD")
          @trunk = live_trunk
          tip ? branches + dirty(tip) + commits : []
        end

        private

        def branches
          @git.out("for-each-ref", *unmerged, "--format=%(refname:short)%09%(objectname)", "refs/heads")
              .lines(chomp: true).map { |line| branch_row(*line.split("\t")) }
        end

        def unmerged = @trunk ? ["--no-merged=#{@trunk}"] : []

        def live_trunk
          name = @git.trunk
          name unless @git.target("refs/heads/#{name}").nil?
        end

        def branch_row(name, sha)
          Row.new(id: "branch:#{@root}:#{name}", rank: :branch, reason: "unmerged branch #{name}",
                  request: Request.new(kind: :branch, repo_root: @root, base: @trunk, head: name), head_sha: sha)
        end

        def dirty(tip)
          status = @git.out("status", "--porcelain=v1", "-z", "--untracked-files=all",
                            env: { "GIT_OPTIONAL_LOCKS" => "0" })
          return [] if status.empty?

          [Row.new(id: "dirty:#{@root}", rank: :dirty, reason: "uncommitted changes",
                   request: Request.new(kind: :dirty, repo_root: @root, base: tip, head: nil),
                   head_sha: fingerprint(tip, status))]
        end

        # Status alone cannot tell 2 edits of 1 file apart, and hashing every
        # changed file's bytes would make listing cost its size.
        def fingerprint(tip, status)
          Digest::SHA1.hexdigest([tip, status, *changed_paths(status).map { |path| stamp(path) }].join("\n"))
        end

        # A rename or copy entry is followed by its source path, which names a
        # file that is no longer there.
        def changed_paths(status)
          entries = status.split("\0").each
          paths = []
          loop do
            entry = entries.next
            paths << entry[3..]
            entries.next if entry[0, 2].match?(/[RC]/)
          end
          paths
        end

        def stamp(path)
          stat = File.lstat(File.join(@root, path))
          [stat.mtime.to_i, stat.mtime.nsec, stat.size].join(":")
        rescue SystemCallError
          "gone"
        end

        def commits
          log = @git.out("log", "--no-merges", "--since=#{@since}", "--format=%H%x09%P%x09%s", trunk_or_head)
          log.lines(chomp: true).map { |line| commit_row(*line.split("\t", 3)) }
        end

        def trunk_or_head = @trunk || "HEAD"

        def commit_row(sha, parents, subject)
          Row.new(id: "commit:#{@root}:#{sha}", rank: :commit, reason: "recent commit: #{subject}",
                  request: Request.new(kind: :commit, repo_root: @root, base: parents.split.first, head: sha),
                  head_sha: sha)
        end
      end
    end
  end
end
