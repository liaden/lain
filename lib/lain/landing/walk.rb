# frozen_string_literal: true

module Lain
  module Landing
    Walk = Data.define(:path, :tail, :hops)

    # A path resolved one component at a time, as the kernel resolves it: a
    # link's target is read from the link's own directory, and a `..` after a
    # link climbs from where the link lands.
    #
    # The tail is left uncleaned because its `..` means different things to
    # different callers: the seal stops at the missing component, a resolve
    # folds it lexically.
    class Walk
      # A loop ends the walk at the link the kernel would refuse with ELOOP: that link is the last of
      # {HOPS} + 1 hops, `path` is its directory and `tail` starts at its name.
      #
      # @param path [String] the landing of the longest prefix that resolves
      # @param tail [Array<String>] the components after it, `..` kept; empty when the whole path resolves
      # @param hops [Array<String>] every link met, at its real place, in order
      def initialize(path:, tail:, hops:)
        super(path: -path, tail: tail.map(&:-@).freeze, hops: hops.map(&:-@).freeze)
      end

      # @param path [String] absolute
      # @param facts [#symlink?, #exist?, #readlink] asked only of paths already resolved
      # @return [Walk]
      def self.of(path, facts) = step(File::SEPARATOR, parts(path), [], facts)

      # @return [Boolean] some of the path is not on disk, or a link loop stopped it
      def absent? = tail.any?

      # @return [Boolean] the kernel would answer ELOOP: the last hop is the link it refused to follow
      def looped? = hops.size > HOPS

      def self.step(dir, rest, hops, facts)
        return new(path: dir, tail: [], hops:) if rest.empty?

        name, *after = rest
        return step(File.dirname(dir), after, hops, facts) if name == ".."

        place = File.join(dir, name)
        return follow(dir, place, rest, hops, facts) if facts.symlink?(place)
        return new(path: dir, tail: rest, hops:) unless facts.exist?(place)

        step(place, after, hops, facts)
      end

      def self.follow(dir, link, rest, hops, facts)
        return new(path: dir, tail: rest, hops: [*hops, link]) if hops.size >= HOPS

        target = facts.readlink(link)
        step(target.start_with?(File::SEPARATOR) ? File::SEPARATOR : dir, [*parts(target), *rest.drop(1)],
             [*hops, link], facts)
      end

      # @param path [String]
      # @return [Array<String>] its components, with the empty and `.` ones the kernel skips left out
      def self.parts(path) = path.split(File::SEPARATOR).reject { _1.empty? || _1 == "." }

      private_class_method :step, :follow
    end
  end
end
