# frozen_string_literal: true

module Lain
  module Telemetry
    Escalation = Data.define(:tool, :tool_use_id, :requester, :rule, :ruling)

    # The one `escalation` journal record, whichever rung or middleware ruled.
    # Beside {Approval::Escalation}, so call sites inside Approval root-qualify it.
    class Escalation
      include Journalable

      # Evidence about a call must never cost the call: some writers sit above
      # the interpreter, with nothing below to turn an exception into a result.
      #
      # @param journal [#<<] where the record goes
      # @param ruling [Approval::Escalation::Ruling]
      # @param effect [Effect::ToolCall]
      # @param context [Object, nil] names the requester unless one is given
      # @param requester [String, nil]
      # @param extra [Hash] further fields; nil values are left off
      # @return [void]
      def self.write(journal, ruling, effect, context, requester: nil, **extra)
        record = new(tool: effect.name, tool_use_id: effect.tool_use_id,
                     requester: requester_of(context, requester), rule: ruling.rule, ruling:)
        journal << record.to_journal.merge(extra.compact.transform_keys(&:to_s)).merge(ruling.record)
        nil
      rescue StandardError
        nil
      end

      # @param context [Object, nil]
      # @param given [Requester, String, nil] who the stack was built for
      # @return [String] the name, because a record keeps a String and not the value
      def self.requester_of(context, given = nil)
        (given ? Requester.of(given) : Approval::Queue.identity_for(context)).name
      end

      # `tool_use_id` rides beside the name because parallel calls of one tool are in flight together.
      def to_journal
        { "type" => journal_type, "tool" => tool, "tool_use_id" => tool_use_id,
          "requester" => requester, "rule" => rule }.compact
      end
    end
  end
end
