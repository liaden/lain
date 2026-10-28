# frozen_string_literal: true

# Reads which policy a stack's gate asks by driving a call through it, not by opening the gate.
module GateAsked
  # @param policy [#rule] the policy expected to rule; stubbed to allow, so a real ladder never parks the call
  # @param layers [#to_a] the stack under test
  # @param toolset [Lain::Toolset] resolves the call's tool
  # @return [Array] the context of each call the gate asked that policy about
  def gate_contexts(policy, layers, toolset:)
    asked = []
    allow(policy).to receive(:rule) do |_effect, context|
      asked << context
      Lain::Approval::Escalation::Ruling.allow(rung: "spec", because: "stubbed to see who is asked")
    end
    Sync { dispatch_call("bash", { "command" => "true" }, toolset:, layers: layers.to_a, context: Lain::Session.new) }
    asked
  end

  def gate_asks?(policy, layers, toolset:) = gate_contexts(policy, layers, toolset:).any?
end

RSpec.configure { |config| config.include GateAsked }
