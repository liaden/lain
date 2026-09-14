# frozen_string_literal: true

module Lain
  module CLI
    # Turns `--context-pipeline <name>` into the render strategy a {Context} is
    # built with, and the name that Context carries into the session record.
    #
    # Resolved at construction, never at render: {Context#render} is pure, and
    # purity is the constraint prompt caching imposes.
    #
    # A WORD REPLACES THE DEFAULT, it does not add to it. `--context-pipeline
    # prune` sends no workspace reminders -- in a chat, the todo list and the
    # memory manifest -- and marks no cache breakpoints, and nothing degrades
    # loudly, because nothing it requires is missing. `prune+default` is the
    # arm that keeps both.
    #
    # Parts join with `+` and fold with {Context::Combinator#>>} left to right,
    # so unlike `--compact-strategy`'s `+` the order is a semantic. The name is
    # recorded as typed.
    #
    # A combinator that needs a collaborator only a run can supply (Recall,
    # Compact, Mailbox, PinnedMessages) is not a word, and neither is
    # TailInjection (a mixin) or MessageEnvelope (one message's wrapper): none
    # composes under `>>` from a flag alone.
    class ContextPipeline
      # Worded as {CompactionStrategy::Unknown} is: one kind of mistake on two
      # knobs.
      class Unknown < Error; end

      # A literal, not {Backend::DEFAULT_KEEP_LAST}, though the reason matches:
      # a header records a WORD and the loader re-resolves it, so a word's
      # meaning must not move with a compaction knob.
      RECENT_MESSAGES = 20

      # The stages, as `->(workspace)` providers so {Context::Reminder} reads the
      # live Workspace. Built in the class body so each lambda's `self` is this
      # class, which keeps a Context holding one `Ractor.shareable?`.
      STAGES = Ractor.make_shareable(
        {
          "reminder" => ->(workspace) { Context::Reminder.new(workspace:) },
          "cache-breakpoints" => ->(_workspace) { Context::CacheBreakpoints.new },
          "prune" => ->(_workspace) { Context::Prune.new(keep_last: RECENT_MESSAGES) },
          "dedupe-tool-calls" => ->(_workspace) { Context::DedupeToolCalls.new },
          "purge-failed-inputs" => ->(_workspace) { Context::PurgeFailedInputs.new(turns: RECENT_MESSAGES) }
        }
      )

      # Every word and the stages it stands for, in help-text order. A word is
      # its stages so a repeat is judged on what renders: `default+reminder`
      # would send the workspace twice.
      PIPELINES = Ractor.make_shareable(
        { "default" => %w[reminder cache-breakpoints] }.merge(STAGES.keys.to_h { |stage| [stage, [stage]] })
      )

      SEPARATOR = "+"

      # The flag a refusal names unless the caller says where the name came from.
      FLAG = "--context-pipeline"

      COMPOSE = Ractor.make_shareable(
        lambda do |parts|
          Ractor.make_shareable(->(workspace) { parts.map { |part| part.call(workspace) }.inject(:>>) })
        end
      )
      private_constant :COMPOSE

      # An unset flag: the Context it always built, and no name, so the header
      # stays byte-identical to every one already on disk.
      class Unnamed
        def context(**attributes) = Context.new(**attributes)

        def stages = PIPELINES.fetch("default")
      end

      UNNAMED = Unnamed.new.freeze

      # @param name [String, nil]
      # @param origin [String] what a refusal says the name came from
      # @return [ContextPipeline, Unnamed]
      # @raise [Unknown] on an unknown, empty or repeated part, or a non-String
      def self.named(name, origin: FLAG) = name.nil? ? UNNAMED : new(name, origin:)

      def initialize(name, origin: FLAG)
        @origin = origin
        @name = -string_name(name)
        @stages = unrepeated(split_name.map { |part| validated(part) }).freeze
        @pipeline = composed(@stages.map { |stage| STAGES.fetch(stage) })
        freeze
      end

      # What renders, in order, whatever words named it: `default` and
      # `reminder+cache-breakpoints` answer alike, and so does an unset flag.
      #
      # @return [Array<String>]
      attr_reader :stages

      # @return [Context] rendering through this pipeline, and named for it
      def context(**attributes) = Context.new(**attributes, pipeline: @pipeline, pipeline_name: @name)

      private

      def composed(parts) = parts.one? ? parts.first : COMPOSE.call(parts.freeze)

      # {CompactionStrategy#string_name}'s door: `String()` would bless a
      # Symbol in silence.
      def string_name(name)
        return name if name.is_a?(String)

        raise Unknown, "#{@origin} takes a String, got #{name.class}: #{name.inspect}; #{expected}"
      end

      # A negative limit keeps empty parts, and `"".split` answers `[]`, so
      # both are named as the empty part they are.
      def split_name = @name.empty? ? [@name] : @name.split(SEPARATOR, -1)

      def validated(part)
        return part if PIPELINES.key?(part)

        raise Unknown, "unknown part #{part.inspect} in #{@origin} #{@name.inspect}, #{expected}"
      end

      # A repeated word is named as typed; a word repeating a stage inside
      # `default` is named by that stage.
      #
      # @return [Array<String>] the stages the words stand for, in order
      def unrepeated(words)
        stages = words.flat_map { |word| PIPELINES.fetch(word) }
        repeat = repeated(words) || repeated(stages)
        if repeat
          raise Unknown, "repeated part #{repeat.inspect} in #{@origin} #{@name.inspect}, #{expected}; " \
                         "each stage renders once, and \"default\" is reminder+cache-breakpoints"
        end

        stages
      end

      def repeated(parts) = parts.detect { |part| parts.count(part) > 1 }

      def expected = "expected one of #{PIPELINES.keys.inspect}, or several joined by #{SEPARATOR.inspect}"
    end
  end
end
