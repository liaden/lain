# frozen_string_literal: true

module Lain
  class Config
    # The tables of one `.lain/config.rb`, each already through its own `.from`.
    #
    # `tests` is nil when the file declares no such table, and {#test_layout}
    # is the reader: absence must stay distinguishable from a declared table so
    # the detected-framework fallback survives, without every caller comparing
    # against {TestLayout::None}.
    Built = Data.define(:epics, :approval, :isolation, :sensitivity, :shell, :tests) do
      # @param framework [String, nil] a detected test framework
      # @return [TestLayout] the declared layout, else what the framework implies
      def test_layout(framework: nil) = tests || TestLayout.from(nil, path: nil, framework:)
    end

    # The evaluation context for `.lain/config.rb`: one verb per table, each
    # handing the same `.from` the TOML reader used a string-keyed hash, so
    # every semantic refusal survives the change of syntax. instance_eval'd
    # with no sandbox, like `.lain/services.rb`.
    #
    # A refusal names the line of the verb that caused it, because the user
    # wrote Ruby and a backtrace into this file points nowhere they can edit.
    class Builder
      VERBS = %i[epics approval isolation sensitivity shell tests].freeze

      # Records the calls a block makes, so the verb that owns the block can
      # validate them at the line each was written on.
      class Collector
        Call = Data.define(:verb, :args, :kwargs, :line)

        attr_reader :calls

        def initialize(path, verbs)
          @path = path
          @verbs = verbs
          @calls = []
        end

        # @param name [Symbol] the verb
        # @param args [Array] its positional arguments
        # @param kwargs [Hash{Symbol => Object}] its keyword arguments, kept as written
        # @option kwargs [Object] :field one field of an entry, as written
        def method_missing(name, *args, **kwargs)
          line = Builder.line_in(@path)
          raise Builder.unknown_verb(name, @verbs, path: @path, line:) unless @verbs.include?(name)

          @calls << Call.new(verb: name, args:, kwargs:, line:)
        end

        def respond_to_missing?(name, include_private = false) = @verbs.include?(name) || super
      end
      private_constant :Collector

      # @param source [String] the text of a `.lain/config.rb`
      # @param path [String] what backtraces and refusals name
      # @return [Built]
      # @raise [Refusal] naming the path and line of what the file got wrong,
      #   whether that is a refused value or Ruby itself failing
      def self.evaluate(source, path:)
        builder = new(path)
        # A String read under LC_ALL=C is US-ASCII, and `load` would assume UTF-8 here.
        builder.instance_eval(source.dup.force_encoding(Encoding::UTF_8), path, 1)
        builder.built
      rescue Refusal
        raise
      rescue ScriptError, StandardError => e
        raise translated(DslCatalog.refusal_message(e, path), path)
      end

      def self.translated(message, path)
        location = message[/\A#{Regexp.escape(path)}(:\d+)?/]
        Refusal.new(message.delete_prefix("#{location}: "), path: location)
      end
      private_class_method :translated

      # @return [Integer, nil] the line in `path` the current call came from
      def self.line_in(path) = caller_locations.find { |frame| frame.path == path }&.lineno

      def self.located(path, line) = line ? "#{path}:#{line}" : path

      def self.unknown_verb(name, known, path:, line:)
        Refusal.new("has no verb #{name.inspect}; known verbs: #{known.join(", ")}",
                    path: located(path, line), key: name.to_s)
      end

      def initialize(path)
        @path = path
        @tables = {}
      end

      # @return [Built] every table not declared at its default
      def built
        Built.new(epics: @tables.fetch(:epics) { Epics.from(nil, path: @path) },
                  approval: @tables.fetch(:approval, Answers.empty),
                  isolation: @tables.fetch(:isolation, Isolation.empty),
                  sensitivity: @tables.fetch(:sensitivity, Sensitivity::Rules.empty),
                  shell: @tables.fetch(:shell, Shell::Exclusions.empty),
                  tests: @tables[:tests])
      end

      def epics(**table, &block)
        declare(:epics, Epics::TABLE, table) do |at|
          gates = gates_from(collect(block, %i[gate]), table, at)
          Epics.from(shaped(table, "gates" => gates), path: at)
        end
      end

      def approval(&block)
        declare(:approval, Answers::TABLE) do |at|
          calls = collect(block, %i[allow deny deny_tool])
          calls.each { |call| Answers.from({ call.verb.to_s => [entry(call)] }, path: located_at(call.line)) }
          Answers.from(calls.group_by(&:verb).to_h { |verb, group| [verb.to_s, group.map { |call| entry(call) }] },
                       path: at)
        end
      end

      def isolation(**table)
        declare(:isolation, Isolation::TABLE, table) { |at| Isolation.from(shaped(table), path: at) }
      end

      def sensitivity(**table)
        declare(:sensitivity, Sensitivity::Rules::TABLE, table) { |at| Sensitivity::Rules.from(shaped(table), path: at) }
      end

      def shell(**table)
        declare(:shell, Shell::Exclusions::TABLE, table) { |at| Shell::Exclusions.from(shaped(table), path: at) }
      end

      def tests(**table) = declare(:tests, TestLayout::TABLE, table) { |at| TestLayout.from(shaped(table), path: at) }

      # Kernel#test answers the likeliest typo of `tests` with an unrelated TypeError.
      def test(*, **)
        raise self.class.unknown_verb(:test, VERBS, path: @path, line: self.class.line_in(@path))
      end

      def method_missing(name, *, **)
        raise self.class.unknown_verb(name, VERBS, path: @path, line: self.class.line_in(@path))
      end

      def respond_to_missing?(*) = super

      private

      def declare(table, label, keywords = {})
        at = located_at(self.class.line_in(@path))
        raise Refusal.new("declares #{table} twice", path: at, table: label, key: table.to_s) if @tables.key?(table)

        refuse_repeated_keys(keywords, at, label)
        @tables[table] = yield(at)
      end

      def refuse_repeated_keys(keywords, at, label)
        twice = keywords.keys.map(&:to_s).tally.select { |_, count| count > 1 }.keys
        raise Refusal.new("gives #{twice.join(", ")} twice", path: at, table: label, key: twice) if twice.any?
      end

      def located_at(line) = self.class.located(@path, line)

      def refuse(detail, line:, table:, key:) = raise(Refusal.new(detail, path: located_at(line), table:, key:))

      def collect(block, verbs)
        collector = Collector.new(@path, verbs)
        collector.instance_eval(&block) if block
        collector.calls
      end

      def gates_from(calls, table, at)
        both = calls.any? && table.key?(:gates)
        if both
          raise Refusal.new("gives gates both as a keyword and as a block", path: at, table: Epics::TABLE,
                                                                            key: "gates")
        end

        gates = calls.each_with_object({}) do |call, seen|
          stage, policy = gate_pair(call)
          if seen.key?(stage)
            refuse("declares gate #{stage.inspect} twice", line: call.line, table: Epics::Gates::TABLE,
                                                           key: stage.to_s)
          end

          seen[stage] = policy
        end
        gates.empty? ? nil : gates
      end

      def gate_pair(call)
        return call.args if call.args.size == 2 && call.kwargs.empty?

        refuse("gate takes a stage and a policy, got #{call.args.size} arguments",
               line: call.line, table: Epics::Gates::TABLE, key: "gate")
      end

      def entry(call)
        unless call.args.size == 1
          refuse("#{call.verb} takes one tool name, got #{call.args.size} arguments",
                 line: call.line, table: Answers::TABLE, key: call.verb.to_s)
        end

        { "tool" => call.args.first }.merge(input_of(call))
      end

      # `allow "x"` with no fields is `input = {}`; `deny_tool` has no input, so
      # a field beside it is left for {Answers} to refuse.
      def input_of(call)
        return {} if call.verb == :deny_tool && call.kwargs.empty?

        { "input" => shaped(call.kwargs) }
      end

      # TOML's own shape: string keys, and a symbol is a string.
      def shaped(value, extra = {})
        case value
        when Hash then value.merge(extra.compact).to_h { |key, member| [key.to_s, shaped(member)] }
        when Array then value.map { |member| shaped(member) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
