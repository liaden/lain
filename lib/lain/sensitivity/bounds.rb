# frozen_string_literal: true

module Lain
  class Sensitivity
    # What one agent may read, write and run, and the leases it holds for its
    # children. The join is componentwise; {#lend} cuts a child's bounds from
    # the parent's base and one lease, so a child never reaches a sibling.
    #
    # {Roots} alone is a preorder, since a root beside its own child holds
    # what the root alone does. Each component is kept canonical here instead
    # -- spellings sorted, any nested under another dropped -- so two bounds
    # that hold the same landings are `==`, and `<=` is a partial order.
    class Bounds
      DIRS = %i[reads writes children].freeze

      # @param reads [Array<String>] directories, each expanded against the process directory
      # @param writes [Array<String>]
      # @param execs [Confine::ExecRules]
      # @param facts [FileFacts::Live, FileFacts::Recorded] where a directory really lands
      # @return [Bounds]
      def self.of(reads: [], writes: [], execs: Confine::ExecRules::NONE, facts: FileFacts::LIVE)
        new(reads: spell(reads, facts), writes: spell(writes, facts), children: [], execs:)
      end

      # @param dirs [Array<String>] each expanded against the process directory
      # @param facts [FileFacts::Live, FileFacts::Recorded]
      # @return [Array<String>] each directory as written and where it really lands
      def self.spell(dirs, facts) = dirs.flat_map { Roots.spellings(_1, facts) }

      # @param reads [Array<String>] absolute, already spelled; see {of}
      # @param writes [Array<String>]
      # @param children [Array<String>]
      # @param execs [Confine::ExecRules]
      def initialize(reads:, writes:, children:, execs:)
        @spellings = { reads:, writes:, children: }.transform_values { canonical(_1) }.freeze
        @reads, @writes, @children = DIRS.map { Roots.new(@spellings.fetch(_1)) }
        @execs = execs
        freeze
      end

      # @return [Roots]
      attr_reader :reads, :writes, :children
      # @return [Confine::ExecRules]
      attr_reader :execs

      # @param other [Bounds]
      # @return [Bounds] holding what either holds, component by component
      def |(other)
        Bounds.new(**DIRS.to_h { [_1, spellings.fetch(_1) + other.spellings.fetch(_1)] }, execs: execs | other.execs)
      end

      # @param other [Bounds]
      # @return [Boolean] whether every component here lies within `other`'s
      def <=(other) = DIRS.all? { public_send(_1) <= other.public_send(_1) } && execs <= other.execs

      # @param dir [String] a directory leased to a child
      # @param facts [FileFacts::Live, FileFacts::Recorded] where it really lands
      # @return [Bounds] these bounds holding that lease too
      def with_child(dir, facts: FileFacts::LIVE)
        self | Bounds.new(reads: [], writes: [], children: Bounds.spell([dir], facts), execs:)
      end

      # @param dir [String] the child's leased directory, one these bounds hold
      # @param facts [FileFacts::Live, FileFacts::Recorded] where it really lands
      # @return [Bounds] the base reads and execs, the lease to read and write, and no children
      # @raise [ArgumentError] when no lease here holds the directory
      def lend(dir, facts: FileFacts::LIVE)
        lease = Bounds.spell([dir], facts)
        raise ArgumentError, "no child lease holds #{dir}" unless lease.all? { children.held?(_1) }

        Bounds.new(reads: [*spellings.fetch(:reads), *lease], writes: lease, children: [], execs:)
      end

      # A write root is readable too, as the sandbox grants it.
      #
      # @param path [String] an absolute landing
      # @return [Boolean] whether the path lies under a read or write root or a child's lease
      def read?(path) = [reads, writes, children].any? { _1.held?(path) }

      # @param path [String] an absolute landing
      # @return [Boolean]
      def write?(path) = writes.held?(path)

      # @param path [String] an absolute landing
      # @return [Boolean]
      def exec?(path) = execs.exec?(path)

      # @return [String] the content address of the canonical form
      def digest = Canonical.digest(spellings.merge(execs: execs.to_canonical))

      def ==(other) = other.is_a?(Bounds) && spellings == other.spellings && execs == other.execs
      alias eql? ==

      def hash = [spellings, execs].hash

      protected attr_reader :spellings

      def canonical(spellings)
        unique = spellings.map(&:-@).uniq
        unique.reject { |dir| unique.any? { _1 != dir && Landing.under?(dir, _1) } }.sort.freeze
      end
      private :canonical

      NONE = new(reads: [], writes: [], children: [], execs: Confine::ExecRules::NONE)
    end
  end
end
