# frozen_string_literal: true

module SpecNulls
  # A frozen {Lain::Mode} answers `#layers` exactly as {Lain::Mode::Switch}
  # does, which is the whole of what the auto_approve layer check asks -- so
  # the board below stands in with a real value rather than a fake duck, in the
  # mode every session starts in.
  UNSWITCHED = Lain::Mode.new

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
        policy: Lain::Middleware::Gate::ApproveAll.new, denial: Lain::Middleware::Gate::DENIAL
      )
    end

    def approvals = nil
    def policy_switch = guard_inputs.policy
    def mode_switch = UNSWITCHED
    def sensitivity = guard_inputs.sensitivity

    def inspect = "SpecNulls::NoSwitchboard"
    alias_method :to_s, :inspect
  end.new.freeze
end
