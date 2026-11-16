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
        # @param repo_root [String] any directory inside the checkout to list
        # @param notes [#puts] where a row a request refuses is named
        # @param since [String] how far back a commit still counts as recent
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, notes:, since: "1 day ago", shell_out_factory: Shell::Out.public_method(:new))
          @since = since
          @listing = Listing.new(notes:, shell_out_factory:)
          @root = @listing.top_of(repo_root)
          @git = Isolation::Checkout.of(@root, shell_out_factory:)
        end

        # @return [Array<Row>] branches, then the dirty tree, then recent commits
        def call
          tip = @git.target("HEAD")
          @trunk = live_trunk
          tip ? branches + dirty(tip) + commits : []
        end

        private

        # Git answers in bytes; the request's wire form is UTF-8.
        def utf8(text) = String.new(text).force_encoding(Encoding::UTF_8)

        # lstrip=2 rather than short, which says heads/v1 when a tag v1 exists.
        def branches
          @git.out("for-each-ref", *unmerged, "--format=%(refname:lstrip=2)%09%(objectname)", "refs/heads")
              .lines(chomp: true).filter_map { |line| branch_row(*utf8(line).split("\t")) }
        end

        def unmerged = @trunk ? ["--no-merged=#{@trunk}"] : []

        def live_trunk
          name = @git.trunk
          name unless @git.target("refs/heads/#{name}").nil?
        end

        def branch_row(name, sha)
          against = @trunk ? { "base" => @trunk } : {}
          @listing.row("branch:#{@root}:#{name}",
                       { "kind" => "branch", "branch" => name, "repo_root" => @root, **against },
                       rank: :branch, reason: "unmerged branch #{name}", head_sha: sha)
        end

        def dirty(tip)
          status = @git.out("status", "--porcelain=v1", "-z", "--untracked-files=all",
                            env: { "GIT_OPTIONAL_LOCKS" => "0" })
          return [] if status.empty?

          [@listing.row("dirty:#{@root}", { "kind" => "dirty", "repo_root" => @root },
                        rank: :dirty, reason: "uncommitted changes", head_sha: fingerprint(tip, status))].compact
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

        # Status paths are bytes, so the join is in bytes: a UTF-8 root and a
        # non-ASCII path would not concatenate.
        def stamp(path)
          stat = File.lstat(File.join(@root.b, path.b))
          [stat.mtime.to_i, stat.mtime.nsec, stat.size].join(":")
        rescue SystemCallError
          "gone"
        end

        # A root commit has no parent to range from, so it gets no row.
        def commits
          log = @git.out("log", "--no-merges", "--since=#{@since}", "--format=%H%x09%P%x09%s", trunk_or_head)
          log.lines(chomp: true).map { |line| utf8(line).split("\t", 3) }.reject { |_, parents| parents.empty? }
             .filter_map { |fields| commit_row(*fields) }
        end

        def trunk_or_head = @trunk || "HEAD"

        def commit_row(sha, parents, subject)
          @listing.row("commit:#{@root}:#{sha}",
                       { "kind" => "range", "base" => parents.split.first, "head" => sha, "repo_root" => @root },
                       rank: :commit, reason: "recent commit: #{subject}", head_sha: sha)
        end
      end
    end
  end
end
