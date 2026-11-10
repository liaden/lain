# frozen_string_literal: true

require "prism"
require_relative "git"

module TestMap
  # Reads a tree-to-tree diff in the old tree's line numbers, so a stored map's line sets apply to it unshifted.
  module Change
    Hunk = Data.define(:kind, :lines)
    ChangedFile = Data.define(:path, :status, :hunks)

    STATUSES = { "A" => :added, "D" => :deleted }.freeze
    HUNK_HEADER = /\A@@ -(?<start>\d+)(?:,(?<count>\d+))? /

    # Unscrubbed: under `commit -a` and `commit <path>` the index git commits is only in GIT_INDEX_FILE.
    def self.staged_tree(repo:) = Git.run("write-tree", repo:, scrub: false).strip

    # NUL-separated names, because git C-quotes a path holding a quote, tab or backslash in any other form.
    def self.between(old_tree, new_tree, repo:)
      listing = Git.run("diff", "--name-status", "-z", "--no-renames", old_tree, new_tree, repo:)
      listing.split("\0").each_slice(2).map do |letter, path|
        status = STATUSES.fetch(letter, :modified)
        ruby = path.end_with?(".rb") && status == :modified
        ChangedFile.new(path:, status:, hunks: ruby ? hunks_of(old_tree, new_tree, path, repo) : [])
      end
    end

    def self.spans_in(tree, path, repo)
      source = Git.run("show", "#{tree}:#{path}", repo:)
      defs = []
      collect_defs(Prism.parse(source).value, defs)
      defs.sort_by(&:size)
    end

    def self.collect_defs(node, defs)
      defs << (node.location.start_line..node.location.end_line) if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |child| collect_defs(child, defs) }
    end

    def self.hunks_of(old_tree, new_tree, path, repo)
      spans = spans_in(old_tree, path, repo)
      diff = Git.run("diff", "-U0", "--no-renames", old_tree, new_tree, "--", ":(literal)#{path}", repo:)
      diff.lines.filter_map do |line|
        match = HUNK_HEADER.match(line)
        match && hunk(match[:start].to_i, (match[:count] || "1").to_i, spans)
      end
    end

    # A pure addition has count 0 and sits between line `start` and the next.
    def self.hunk(start, count, spans)
      if count.zero?
        span = spans.find { |candidate| candidate.cover?(start) && start < candidate.end }
        return span ? Hunk.new(:method, span) : Hunk.new(:file, start..start)
      end

      lines = start..(start + count - 1)
      span = spans.find { |candidate| candidate.cover?(lines) }
      span ? Hunk.new(:method, span) : Hunk.new(:file, lines)
    end

    private_class_method :spans_in, :collect_defs, :hunks_of, :hunk
  end
end
