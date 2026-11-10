# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "git"
require_relative "map"

module TestMap
  # Anchors count toward KEEP, so at most 8 maps are stored.
  class MapStore
    KEEP = 8
    ANCHOR_DEPTH = 200
    STALE_TEMP_SECONDS = 3600
    TREE_ID = /\A\h{40,64}\z/

    def initialize(repo:)
      @repo = repo
    end

    def save(map)
      FileUtils.mkdir_p(dir)
      temp = File.join(dir, ".#{map.tree}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      File.write(temp, JSON.generate(map.to_h))
      File.rename(temp, path_for(map.tree))
      prune
    end

    def for_tree(tree)
      parsed = JSON.parse(File.read(path_for(tree)))
      parsed.is_a?(Hash) ? Map.from_h(parsed) : nil
    rescue Errno::ENOENT, JSON::ParserError, KeyError
      nil
    end

    private

    def dir = @dir ||= File.join(common_dir, "lain", "test-map")

    def common_dir = Git.run("rev-parse", "--path-format=absolute", "--git-common-dir", repo: @repo).strip

    def path_for(tree)
      raise ArgumentError, "not a tree id: #{tree.inspect}" unless TREE_ID.match?(tree)

      File.join(dir, "#{tree}.json")
    end

    def prune
      protected_trees = anchors
      sweep_stale_temps
      return if protected_trees.nil?

      stored = stored_trees
      protected_trees &= stored
      newest = (stored - protected_trees).first([KEEP - protected_trees.size, 0].max)
      (stored - protected_trees - newest).each { |tree| remove(tree) }
    end

    def stored_trees
      Dir.glob(File.join(dir, "*.json"))
         .filter_map { |file| modified(file) }
         .sort_by { |mtime, tree| [mtime, tree] }.reverse.map(&:last)
    end

    def modified(file)
      [File.mtime(file), File.basename(file, ".json")]
    rescue Errno::ENOENT
      nil
    end

    def sweep_stale_temps
      cutoff = Time.now - STALE_TEMP_SECONDS
      Dir.glob(File.join(dir, ".*.tmp")).each do |file|
        File.delete(file) if File.mtime(file) < cutoff
      rescue Errno::ENOENT
        nil
      end
    end

    def remove(tree)
      File.delete(path_for(tree))
    rescue Errno::ENOENT
      nil
    end

    # nil when git fails: a kept extra map is cheap, a lost anchor is not.
    def anchors
      worktree_heads.filter_map { |head| anchor_tree(head) }.uniq
    rescue RuntimeError
      nil
    end

    def worktree_heads
      Git.run("worktree", "list", "--porcelain", repo: @repo).lines.filter_map do |l|
        l.split.last if l.start_with?("HEAD ")
      end
    end

    def anchor_tree(head)
      history = Git.run("log", "--first-parent", "--max-count=#{ANCHOR_DEPTH}", "--format=%T", head, repo: @repo)
      history.split.find { |tree| File.file?(path_for(tree)) }
    end
  end
end
