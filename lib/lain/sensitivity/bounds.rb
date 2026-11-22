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

      # @param reads [Array<String>] files or directories, each expanded against the process directory
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

      # @return [Array<String>] every directory {#read?} holds, sorted, each as written and where it lands
      def readable = DIRS.flat_map { spellings.fetch(_1) }.uniq.sort

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

      # Which paths beyond the session's reads may be lent to one agent's bounds, judged where each lands. One
      # that would hand it the filesystem, home, the project or a secret wholesale is refused, and each refusal
      # is journaled once for the life of this object, however many calls and children are lent it.
      class Lending
        CAPABILITY = :lent_path
        FILESYSTEM_ROOT = "it is the filesystem root"
        ROOT = "it holds the project root"
        HOME = "it is the home directory or holds it"
        CLASSIFIED = "its path is classified %<level>s"

        # @param journal [#<<] receives a `Telemetry::CapabilityDegraded` for each path refused
        def initialize(journal: Channel::Null.instance)
          @journal = journal
          @journaled = Set.new
          @lock = Mutex.new
        end

        # @param paths [Array<String>] absolute
        # @param home [String, nil] absolute; a lend may not be it or hold it
        # @param roots [Array<String, nil>] the project roots a lend may not hold
        # @param classifier [#classify] the session's policy on a path
        # @return [Hash{String => String}] each path refused, with why
        def refused(paths, home:, roots:, classifier:)
          refusals = paths.filter_map { |path| refusal(path, home, roots.compact, classifier)&.then { [path, _1] } }
          journal(refusals.to_h)
        end

        private

        def refusal(path, home, roots, classifier)
          landing = landing(path)
          return FILESYSTEM_ROOT if landing == File::SEPARATOR
          return ROOT if roots.any? { Landing.under?(landing(_1), landing) }
          return HOME if home && Landing.under?(landing(home), landing)

          verdict = classifier.classify(landing)
          format(CLASSIFIED, level: verdict.level) unless verdict.ordinary?
        end

        def landing(path)
          File.realpath(path)
        rescue SystemCallError
          File.expand_path(path)
        end

        def journal(refusals)
          @lock.synchronize do
            refusals.except(*@journaled).each do |path, reason|
              @journaled << path
              @journal << Telemetry::CapabilityDegraded.new(capability: CAPABILITY, requirer: self.class.name,
                                                            provider: "#{path}: #{reason}")
            end
          end
          refusals
        end
      end
    end
  end
end
