# frozen_string_literal: true

module Lain
  module Memory
    # Whether the files an item was written from still hold the bytes it
    # recorded. Answers marks for a Manifest line rather than hiding or
    # rewriting the item: a stale memory is still evidence, only dated.
    class Staleness
      # A source the project cannot vouch for: outside the root, or not a file.
      class Refused < StandardError; end

      # The answer when nothing is checked, so a Manifest never guards on nil.
      Never = Object.new.tap do |never|
        def never.of(_item) = [].freeze
      end.freeze

      # @param root [String] the project root sources are relative to and kept inside
      # @param resolver [#resolve] how a path as the model spelled it becomes absolute
      # @param stat [#stat] where size and mtime come from
      def initialize(root:, resolver: nil, stat: File)
        @root = File.join(root, "")
        @resolver = resolver
        @stat = stat
        @digests = {}
      end

      # @return [String] the project root, with a trailing separator
      attr_reader :root

      # @param item [Item]
      # @return [Array<String>] "lib/a.rb changed" or "lib/a.rb missing", sorted by path
      def of(item)
        item.sources.sort.filter_map do |path, recorded|
          change = change(path, recorded)
          "#{path} #{change}" if change
        end
      end

      # @param paths [Array<String>] as the model spelled them
      # @return [Hash{String=>String}] project-relative path => digest
      # @raise [Refused] when a path lands outside the root or is not a file
      def record(paths)
        paths.to_h do |path|
          absolute = resolve(path)
          raise Refused, "memory source #{path} is not a file" unless File.file?(absolute)
          raise Refused, "memory source #{path} is outside the project" unless inside?(absolute)

          [-File.realpath(absolute).delete_prefix(real_root), digest_of(File.realpath(absolute))]
        end
      end

      private

      def change(path, recorded)
        absolute = File.join(@root, path)
        return "missing" unless File.file?(absolute)

        "changed" unless digest_of(absolute) == recorded
      end

      def resolve(path) = @resolver ? @resolver.resolve(path) : File.expand_path(path, @root)

      def real_root = File.join(File.realpath(@root), "")

      def inside?(absolute) = File.realpath(absolute).start_with?(real_root)

      # Keyed by size and mtime so an untouched source costs a stat per render
      # rather than a read and a hash.
      def digest_of(absolute)
        info = @stat.stat(absolute)
        key = [info.size, info.mtime]
        held = @digests[absolute]
        return held.last if held && held.first == key

        fresh = Canonical.digest_bytes(File.binread(absolute))
        @digests[absolute] = [key, fresh]
        fresh
      end
    end
  end
end
