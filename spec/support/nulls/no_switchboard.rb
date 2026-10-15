# frozen_string_literal: true

module SpecNulls
  # The board a directly-constructed {Lain::CLI::Wiring::ToolsetBuild} runs
  # under: children ungated, byte-for-byte what every spawn
  # did before children were first gated. For the direct-construction seams
  # the specs drive, and never a production state -- the exe always passes a
  # thunk over the run's real {Lain::CLI::Switchboard}.
  #
  # An INSTANCE, so a spec's `switchboard:` stays the `-> { NoSwitchboard }`
  # thunk the live wiring's shape demands.
  NoSwitchboard = Class.new do
    # The one value {Lain::CLI::ToolGuard} reads. One ledger, for
    # {Lain::CLI::Switchboard}'s reason; no queue, which the guard reads as a
    # run nobody attends -- every region is released, byte-for-byte what a
    # child read before children were guarded; no path policy and no test
    # layout, so nothing is refused; and a gate that approves every call,
    # reporting a refusal it never makes in the sentence {Lain::Middleware::Gate}
    # produces on its own.
    attr_reader :guard_inputs

    def initialize
      super
      @guard_inputs = Lain::CLI::ToolGuard::Inputs.new(
        ledger: Lain::Sensitivity::Ledger.new, approvals: nil,
        sensitivity: Lain::Sensitivity::Policy::Null.instance,
        test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
        policy: Lain::Middleware::Gate::ApproveAll.new, policy_for: ->(_worker_env) { guard_inputs.policy },
        denial: Lain::Middleware::Gate::DENIAL,
        bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new
      )
    end

    def approvals = nil
    def policy_switch = guard_inputs.policy
    def sensitivity = guard_inputs.sensitivity

    def inspect = "SpecNulls::NoSwitchboard"
    alias_method :to_s, :inspect
  end.new.freeze
end
