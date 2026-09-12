# frozen_string_literal: true

require "prism"

module Lain
  class TestLayout
    # Holds a test file to the layout. For a test file under a mirrored level
    # root:
    #
    # 1. its top-level describe names a constant;
    # 2. that constant is defined in the source file the test mirrors;
    # 3. that source file exists;
    # 4. any level tag in it agrees with the root it sits in.
    #
    # A test file in the test tree but under no level root is refused as a
    # stray, because the runner collects it all the same. A refusal names the
    # path the file should occupy, found by looking up where the constant IS
    # defined and mirroring that file, at the level its tag asks for. Presets
    # that describe no constant hold only the path: the mirrored source exists.
    #
    # A file's level is the root it sits in, so a file whose examples are
    # tagged for more than one level has no right place and must be split.
    #
    # One rule and not a lint: the cheap way to make a slow test file look
    # faster is to split it into siblings, and a sibling with no source of its
    # own is exactly what rule 2 refuses.
    class Guard
      # `outcome` is what a caller acts on. `rule` says which rule decided it,
      # so a caller can set its own policy per rule without reading the prose
      # -- a write-time caller may let `:no_source` through, since a test is
      # legitimately written before its class, where a land-time caller
      # refuses it.
      #
      #   passed     :mirrors
      #   exempt     :exempt
      #   unguarded  :no_layout, :not_a_test, :unmirrored, :outside
      #   refused    :stray, :no_describe, :not_a_constant, :unparseable,
      #              :source_unparseable, :no_source, :elsewhere, :level,
      #              :ambiguous, :missing
      #
      # `expected` is named only when the same content would pass there, so
      # following it ends the refusals; otherwise it is nil.
      Verdict = Data.define(:path, :outcome, :rule, :expected, :reason) do
        def self.of(path, outcome, rule, reason, expected: nil) = new(path:, outcome:, rule:, expected:, reason:)

        def initialize(path:, outcome:, rule:, expected:, reason:)
          super(path: path.dup.freeze, outcome:, rule:, expected: expected&.dup&.freeze, reason: reason.dup.freeze)
        end

        def refused? = outcome == :refused
        def to_s = reason
      end

      # Every rule a verdict can be refused under, published so a caller
      # setting policy per rule, and a record naming the rule it refused
      # under, read the one list rather than each keeping a copy.
      REFUSING = %i[stray no_describe not_a_constant unparseable source_unparseable no_source elsewhere level
                    ambiguous missing].freeze

      # What a test file says about itself: the constants its top-level
      # describes name, what any other describe names instead, and every
      # level its groups and examples are tagged with.
      Described = Data.define(:error, :subjects, :unnamed, :tags) do
        def parsed? = error.nil?
        def described? = !subjects.empty? && unnamed.empty?
      end

      # Where a described constant's test belongs. When the file the test
      # mirrors does define the constant, only the level can be wrong, and the
      # reason says so rather than blaming the constant.
      Placement = Data.define(:path, :constant, :level, :home, :expected, :readings) do
        def placed? = expected == path
        def rule = at_home? ? :level : :elsewhere

        def to_s
          return "#{path} is tagged :#{level}, so it belongs under the #{level} root, at #{expected}" if at_home?

          "#{path} describes #{constant}, which is defined in #{home}, not where it mirrors#{absent}; " \
            "its test belongs at #{expected}"
        end

        def at_home? = readings.any? { |reading| reading.path == home }

        def absent
          missing = readings.reject(&:exists?).map(&:path)
          missing.empty? ? "" : " (#{missing.join(" and ")} does not exist)"
        end
      end

      # Reads a test file by parsing it, never by loading it: the file may be
      # content a write has not put on disk yet, and it is somebody else's code.
      class Reader
        # rspec's group and example methods: a level tag on any of them is a
        # claim about the file's level.
        TAGGED = %i[describe context feature example_group it specify example scenario its
                    fdescribe fcontext fit xdescribe xcontext xit].freeze

        # @param levels [Array<String>] the level names a tag can carry
        def initialize(levels)
          @levels = levels
          freeze
        end

        # @param content [String] a test file's whole content
        # @return [Described]
        def read(content)
          result = Prism.parse(content)
          result.failure? ? unreadable(result.errors.first.message) : described_by(result.value)
        end

        private

        def unreadable(error) = Described.new(error:, subjects: [], unnamed: [], tags: [])

        def described_by(program)
          named, unnamed = describes(program).partition { |subject| constant_name(subject) }
          Described.new(error: nil, subjects: named.map { |subject| constant_name(subject) },
                        unnamed: unnamed.map { |subject| subject ? subject.slice : "nothing" }, tags: tags(program))
        end

        def describes(program)
          program.statements.body.select { |node| describe?(node) }.map { |call| call.arguments&.arguments&.first }
        end

        def describe?(node) = node.is_a?(Prism::CallNode) && node.name == :describe && rspec?(node.receiver)

        def rspec?(receiver)
          case receiver
          when nil then true
          when Prism::ConstantReadNode then receiver.name == :RSpec
          when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == :RSpec
          else false
          end
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then node.full_name.delete_prefix("::")
          end
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end

        def tags(program)
          calls(program).flat_map { |call| flags(call) }.select { |tag| @levels.include?(tag) }.uniq
        end

        def calls(node)
          own = node.is_a?(Prism::CallNode) && TAGGED.include?(node.name) ? [node] : []
          own + node.compact_child_nodes.flat_map { |child| calls(child) }
        end

        def flags(call)
          arguments = call.arguments ? call.arguments.arguments : []
          arguments.flat_map { |argument| flag_names(argument) }
        end

        def flag_names(argument)
          case argument
          when Prism::SymbolNode then [argument.unescaped]
          when Prism::KeywordHashNode, Prism::HashNode then true_keys(argument)
          else []
          end
        end

        def true_keys(hash)
          hash.elements.grep(Prism::AssocNode)
              .select { |pair| pair.key.is_a?(Prism::SymbolNode) && pair.value.is_a?(Prism::TrueNode) }
              .map { |pair| pair.key.unescaped }
        end
      end

      # Where the constants a test file describes are defined, and so where the
      # file belongs. One test file mirrors one source, so subjects defined in
      # different files have no single right place.
      class Placer
        # @param mapping [Mapping]
        # @param index [ConstantIndex]
        # @param source_roots [Array<String>] named when a constant is found nowhere
        def initialize(mapping:, index:, source_roots:)
          @mapping = mapping
          @index = index
          @source_roots = source_roots
          freeze
        end

        # @param path [String] the test file, relative to the root
        # @param constants [Array<String>] what its top-level describes name
        # @param level [String] the level it claims
        # @return [Verdict]
        def call(path, constants, level)
          readings = @mapping.sources_for(path).map { |source| @index.constants_in(source) }
          broken = readings.find(&:unparseable?)
          return unparsed(path, broken) if broken

          homes = constants.to_h { |constant| [constant, home_of(constant, readings)] }
          unresolved(path, homes, readings) || settle(placement(path, homes, level, readings))
        end

        private

        # A constant defined nowhere, or subjects defined in different files:
        # either way there is no one file this test could mirror.
        def unresolved(path, homes, readings)
          return undefined(path, homes.key(nil), readings) if homes.value?(nil)

          split(path, homes) if homes.values.uniq.size > 1
        end

        def placement(path, homes, level, readings)
          home = homes.values.first
          Placement.new(path:, constant: homes.keys.first, level:, home:, readings:,
                        expected: @mapping.test_path(home, level:))
        end

        # The mirror first, so a passing check parses one file; the source
        # tree is searched only to name where a misplaced test belongs.
        def home_of(constant, readings)
          mirror = readings.find { |reading| reading.defines?(constant) }
          mirror ? mirror.path : @index.definitions_of(constant).first
        end

        def settle(placement)
          path = placement.path
          return Verdict.of(path, :passed, :mirrors, "#{path} mirrors #{placement.home}") if placement.placed?

          Verdict.of(path, :refused, placement.rule, placement.to_s, expected: placement.expected)
        end

        def unparsed(path, broken)
          Verdict.of(path, :refused, :source_unparseable,
                     "#{broken.path} could not be parsed, so #{path} cannot be checked against it: #{broken.error}")
        end

        def undefined(path, constant, readings)
          mirrors = readings.map do |reading|
            "#{reading.path}, the source it mirrors, #{reading.exists? ? "does not define it" : "does not exist"}"
          end
          Verdict.of(path, :refused, :no_source,
                     "#{path} describes #{constant}, and no Ruby file under #{@source_roots.join(", ")} defines " \
                     "#{constant}#{mirrors.map { |mirror| "; #{mirror}" }.join}")
        end

        def split(path, homes)
          Verdict.of(path, :refused, :ambiguous,
                     "#{path} describes #{homes.keys.join(" and ")}, defined in #{homes.values.uniq.join(" and ")}; " \
                     "one test file mirrors one source, so split it by subject")
        end
      end

      attr_reader :layout, :root

      # The root is resolved through any symlink, and both spellings are
      # accepted, because a tool may hand over the path it was given or the
      # one the filesystem resolved.
      #
      # @param layout [TestLayout]
      # @param root [String] the project root test and source paths are relative to
      # @param index [ConstantIndex] injected so one index serves a whole session
      def initialize(layout:, root:, index: ConstantIndex.new(root: File.realpath(root),
                                                              source_roots: layout.source_roots,
                                                              extension: layout.preset.extension))
        @layout = layout
        @mapping = layout.mapping
        @root = File.realpath(root)
        @roots = [@root, File.expand_path(root)].uniq.freeze
        @reader = Reader.new(@mapping.levels.map(&:name))
        @placer = Placer.new(mapping: @mapping, index:, source_roots: layout.source_roots)
        freeze
      end

      # @param path [String] relative to the root, or absolute inside it
      # @param content [String] the test file's whole content
      # @return [Verdict]
      def check(path, content)
        relative = relative(path)
        screen(relative) { |level| content_verdict(relative, level, content) }
      end

      # The path rules alone, for a write whose resulting content is not in
      # hand: the file is a test under a mirrored root and its source exists.
      # @return [Verdict]
      def check_path(path)
        relative = relative(path)
        screen(relative) { |level| path_verdict(relative, level) }
      end

      # {#check} over the file as it is on disk, refused `:missing` when it is
      # not there.
      # @return [Verdict]
      def check_file(path)
        relative = relative(path)
        full = File.expand_path(relative, @root)
        return Verdict.of(relative, :refused, :missing, "#{relative} does not exist") unless File.file?(full)

        check(relative, File.read(full))
      end

      private

      def relative(path)
        full = File.expand_path(path, @root)
        base = @roots.find { |root| full.start_with?("#{root}/") }
        base ? full.delete_prefix("#{base}/") : path
      end

      def screen(path, &block)
        return unguarded(path, :no_layout, "no test layout is in force") unless @layout.in_force?
        return Verdict.of(path, :exempt, :exempt, "#{path} is exempt from the test layout") if @mapping.exempt?(path)
        return unguarded(path, :not_a_test, "#{path} is not a test file") unless @mapping.test_file?(path)

        located(path, &block)
      end

      # Yields the mirrored level holding the path, or nil for a stray.
      def located(path)
        level = @mapping.level_of(path)
        return yield level if level&.mirrored?
        return yield nil if @mapping.stray?(path)
        return unguarded(path, :outside, "#{path} is outside the test tree") unless level

        unguarded(path, :unmirrored, "#{path} is under the #{level.name} level, which mirrors no source")
      end

      # A stray in a layout with no default level has nothing to be judged
      # AGAINST, so it is reported as the stray it is rather than reaching for
      # a name that is not there. A loaded table cannot get here -- it is
      # refused while ambiguous -- but {TestLayout::None} and a hand-built
      # layout can, and this read used to be an unguarded `.name`.
      def content_verdict(path, level, content)
        against = level || @mapping.default_level
        return path_verdict(path, level) unless @layout.preset.describes && against

        verdict = described(path, against.name, @reader.read(content))
        level ? verdict : strayed(path, verdict)
      end

      def path_verdict(path, level) = level ? mirrored(path) : strayed(path)

      def strayed(path, advice = nil)
        reason = "#{path} is in the test tree under no level root, where the runner still collects it"
        Verdict.of(path, :refused, :stray, advice ? "#{reason}: #{advice.reason}" : reason, expected: advice&.expected)
      end

      def mirrored(path)
        sources = @mapping.sources_for(path)
        present = sources.find { |source| File.file?(File.join(@root, source)) }
        return Verdict.of(path, :passed, :mirrors, "#{path} mirrors #{present}") if present

        Verdict.of(path, :refused, :no_source, "#{path} mirrors #{sources.join(" or ")}, which does not exist")
      end

      def described(path, level, spec)
        unless spec.parsed?
          return Verdict.of(path, :refused, :unparseable, "#{path} could not be parsed: #{spec.error}")
        end
        return undescribed(path, spec) unless spec.described?
        return mixed(path, spec.tags) if spec.tags.size > 1

        @placer.call(path, spec.subjects, spec.tags.first || level)
      end

      def undescribed(path, spec)
        if spec.unnamed.empty?
          return Verdict.of(path, :refused, :no_describe,
                            "#{path} has no top-level describe naming the constant it tests")
        end

        Verdict.of(path, :refused, :not_a_constant,
                   "#{path}'s top-level describe names #{spec.unnamed.first}, not the constant it tests")
      end

      def mixed(path, tags)
        Verdict.of(path, :refused, :ambiguous,
                   "#{path} is tagged for the #{tags.join(" and ")} levels; a file's level is the root it sits in, " \
                   "so split its examples by level")
      end

      def unguarded(path, rule, reason) = Verdict.of(path, :unguarded, rule, reason)
    end
  end
end
