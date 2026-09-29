# frozen_string_literal: true

module Lain
  module Approval
    # Tells a parked call that stopped at the path gate from any other parked
    # call, so a surface can judge the path before a byte is read.
    #
    # A gated path parks with {Queue::Outstanding::NONE}: no region exists until
    # the file is opened. Asking the same {Sensitivity::Policy} the gate asked
    # keeps the two from disagreeing about what is gated.
    class PathGate
      # The gate of a session with no path boundary wired: nothing is one. A
      # class rather than a lambda so a caller asks `path_for` and never guards.
      class Absent
        def path_for(_pending) = nil
      end

      NONE = Absent.new.freeze

      # Only calls that merely READ the path. The oracle is shown a path and a
      # tool, never a command or content, so a write, an edit or a bash whose
      # cwd is gated must stay with the surfaces that see the whole call.
      READ_TOOLS = %w[read_file glob grep list_files ast_search file_symbols].freeze

      # @param policy [Sensitivity::Policy]
      def initialize(policy)
        @policy = policy
        freeze
      end

      # A denied path answers nil: it is refused before anything parks, and no
      # model is ever shown one to weigh.
      #
      # @param pending [Approval::Queue::Pending]
      # Coupled to {Middleware::Gate}: this re-derives, from the same policy,
      # why the gate parked the call rather than reading a reason the gate
      # recorded. A gate that parks on some other ground must be mirrored here,
      # or {AutoSurface} judges what this surface no longer claims.
      #
      # @return [String, nil] the path the call names, when the gate parked it
      def path_for(pending)
        return nil unless READ_TOOLS.include?(pending.tool.to_s)

        effect = Effect::ToolCall.new(tool_use_id: pending.tool_use_id, name: pending.tool.to_s, input: pending.input)
        path = named_by(effect)
        path if path && @policy.gates?(effect) && @policy.denial(effect).nil?
      end

      private

      # Read from the table {Sensitivity::Policy} classifies by, and only a
      # String: a value it would coerce is one this declines to show a judge.
      def named_by(effect)
        field = Sensitivity::Policy::PATH_FIELDS[effect.name]
        input = effect.input
        value = field && input.is_a?(Hash) && (input[field] || input[field.to_sym])
        value if value.is_a?(String)
      end
    end
  end
end
