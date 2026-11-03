# frozen_string_literal: true

module Lain
  module Confine
    # The programs an agent may run, as a set of rules: a glob matched against
    # a path's spelling under the rule's root. The join is set union.
    #
    # The glob matches the way a sensitivity rule's does, so `*` crosses a `/`
    # and `target/**` holds everything beneath `target`. That keeps a rule no
    # wider than what it lowers to: in {#dirs} a wild rule lowers to the
    # directory above its first wild segment, a literal one to itself.
    # A matched path is cleaned first, so a `..` cannot climb out of a root
    # it was spelled under.
    class ExecRules
      Rule = Data.define(:glob, :root)

      # One glob under one root.
      class Rule
        GLOB = Sensitivity::Rule::GLOB
        WILD = Sensitivity::Rules::GLOB_METACHARACTERS
        UNCLEAN = Sensitivity::Rules::UNCLEAN_SEGMENTS

        # @param glob [String] relative to the root and clean: no empty, `.` or `..` segment
        # @param root [String] absolute
        # @raise [ArgumentError] on an absolute or unclean glob, or a relative root
        def initialize(glob:, root:)
          unclean = glob.empty? || glob.split(File::SEPARATOR, -1).intersect?(UNCLEAN)
          raise ArgumentError, "exec root #{root.inspect} is not absolute" unless root.start_with?(File::SEPARATOR)
          raise ArgumentError, "exec glob #{glob.inspect} is absolute" if glob.start_with?(File::SEPARATOR)
          raise ArgumentError, "exec glob #{glob.inspect} has an empty, `.` or `..` segment" if unclean

          super(glob: -glob, root: -root)
        end

        # @param path [String] an absolute landing, cleaned before it is matched
        # @return [Boolean]
        def exec?(path)
          clean = Landing.lexical(path)
          Landing.under?(clean, root) && File.fnmatch?(glob, relative(clean), GLOB)
        end

        # lain-fence's exec directories accept a file too, so a literal rule is granted no wider than itself.
        #
        # @return [String] a wild rule's directory above its first wild segment, a literal one's own path
        def dir
          segments = glob.split(File::SEPARATOR)
          wild = segments.index { WILD.match?(_1) }
          File.join(root, *(wild ? segments.take(wild) : segments))
        end

        # @return [Array<String>] the order the canonical form sorts by
        def key = [root, glob]

        private

        def relative(path) = path.delete_prefix(root).delete_prefix(File::SEPARATOR)
      end

      # @param pairs [Array<Array(String, String)>] each a glob and the absolute root it is matched under
      # @return [ExecRules]
      def self.of(*pairs) = new(pairs.map { |glob, root| Rule.new(glob:, root: File.expand_path(root)) })

      # @param rules [Array<Rule>]
      def initialize(rules)
        @rules = rules.uniq.sort_by(&:key).freeze
        freeze
      end

      NONE = new([])

      # @param other [ExecRules]
      # @return [ExecRules] running what either runs
      def |(other) = ExecRules.new(rules | other.rules)

      # @param other [ExecRules]
      # @return [Boolean] whether every rule here is one of `other`'s
      def <=(other) = (rules - other.rules).empty?

      # @param path [String] an absolute landing
      # @return [Boolean]
      def exec?(path) = rules.any? { _1.exec?(path) }

      # @return [Array<String>] lain-fence's exec directories: a wild rule lowers to the directory above its
      #   first wild segment, a literal one to itself
      def dirs = rules.map(&:dir).uniq

      # @return [Array<Array<String>>] each rule as its root and glob, sorted
      def to_canonical = rules.map(&:key)

      def ==(other) = other.is_a?(ExecRules) && rules == other.rules
      alias eql? ==

      def hash = rules.hash

      protected

      attr_reader :rules
    end
  end
end
