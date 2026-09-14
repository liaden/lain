# frozen_string_literal: true

module Lain
  class Toolset
    # What a name resolves to when this set does not hold it: a Null Object
    # standing where the tool would, so the tool phase needs no branch for the
    # model asking for a capability it was never given.
    #
    # {Agent::ToolRunner} resolves each call to one of these or to the real
    # tool, once, and every reader takes it from there: it is never
    # parallel-safe, it does not ask for approval, and when interpreted it
    # refuses by name. A missing name is a failed call, not a crash -- and not
    # a question for a human, since approving it would run nothing.
    Unheld = Data.define(:name) do
      def initialize(name:)
        super(name: -name.to_s)
      end

      def parallel_safe? = false
      def requires_approval? = false
      def held? = false

      def call(_input, _invocation = nil) = Tool::Result.error("no tool named #{name.inspect} is available")
    end
  end
end
