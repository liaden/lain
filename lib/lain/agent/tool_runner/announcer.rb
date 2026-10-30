# frozen_string_literal: true

module Lain
  class Agent
    class ToolRunner
      # Draws the tool-call line a call's two edges show. It is display only: nothing
      # here is journalled, and nothing here may fail a tool run.
      class Announcer
        TARGET_KEYS = %w[path file_path command pattern query url].freeze

        # One call in flight; {#finish} or, failing that, {#abandon} closes it.
        class Call
          def initialize(announcer, tool_use, context)
            @announcer = announcer
            @tool_use = tool_use
            @context = context
            @started = announcer.clock.call
            @open = true
            announcer.emit(tool_use, context, "start")
          end

          def finish(block) = close { ended(@announcer.outcome(block, @context)) }

          def abandon = close { ended("interrupted") }

          private

          def ended(outcome)
            seconds = @announcer.clock.call - @started
            @announcer.emit(@tool_use, @context, "end", outcome:, seconds:)
          end

          def close
            return unless @open

            @open = false
            yield
          end
        end

        # Shows nothing and builds nothing: a Null display never pays for masking.
        class Silent
          def begin(*) = self
          def finish(_block) = nil
          def abandon = nil
        end

        def self.for(display:, secrets:, clock:)
          display.is_a?(Channel::Null) ? Silent.new : new(display:, secrets:, clock:)
        end

        # @return [#call] the monotonic clock a call's duration is read from
        attr_reader :clock

        def initialize(display:, secrets:, clock:)
          @clock = clock
          @display = display
          @secrets = secrets
        end

        def begin(tool_use, context) = Call.new(self, tool_use, context)

        # @api private
        def emit(tool_use, context, phase, outcome: nil, seconds: nil)
          @display << Telemetry::ToolCalled.new(tool_use_id: tool_use.id, tool: tool_use.name,
                                                summary: summary(tool_use, context), phase:, outcome:, seconds:)
        # A display line is best effort: losing one must never fail the tool it describes.
        rescue StandardError
          nil
        end

        # @api private
        def outcome(block, context)
          return "ok" unless block["is_error"]

          "failed #{masked(block["content"].to_s.lines.first.to_s.chomp, context)}".strip
        end

        private

        def summary(tool_use, context)
          input = tool_use.input
          text = input.is_a?(Hash) ? target(input).to_s.lines.first.to_s.chomp : ""
          clipped(masked(text, context))
        end

        def target(input)
          key = TARGET_KEYS.find { |name| input[name].is_a?(String) }
          key ? input[key] : input.values.find { |value| value.is_a?(String) }
        end

        def masked(text, context) = Sensitivity::TextMask.text(text, secrets: @secrets.for(context))

        # Cut after masking, so a secret is never left half-cut and unrecognisable, and
        # past the end of any placeholder the cut lands in.
        def clipped(text)
          cut = StatusFeed::Fleet::Row.clamped(text)
          return text if cut == text

          kept = cut.delete_suffix(StatusFeed::Fleet::Row::ELLIPSIS)
          "#{text[0, whole_placeholder_end(text, kept.size)]}#{StatusFeed::Fleet::Row::ELLIPSIS}"
        end

        def whole_placeholder_end(text, cut)
          inside = text.to_enum(:scan, Sensitivity::Regions::PLACEHOLDER_SHAPE).map { Regexp.last_match }
                       .find { |found| found.begin(0) < cut && cut < found.end(0) }
          inside ? inside.end(0) : cut
        end
      end
    end
  end
end
