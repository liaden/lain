# frozen_string_literal: true

module SpecNulls
  # A frozen {Lain::Mode} answers `#posture` exactly as {Lain::Mode::Switch}
  # does, which is the whole of what `PosturePermits` asks -- so the board
  # below stands in with a real value rather than a fake duck. `accept_edits`
  # because its {Lain::Mode::Posture::Permits} is `All`: a build with no live
  # board attenuates nothing, which is what "no posture was ever bound here"
  # has to mean.
  UNSWITCHED = Lain::Mode.new(posture: :accept_edits)

  # The board a directly-constructed {Lain::CLI::Wiring::ToolsetBuild} runs
  # under: children ungated and unattenuated, byte-for-byte what every spawn
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
    # child read before children were guarded; and no test layout, so nothing
    # is refused.
    attr_reader :guard_inputs

    def initialize
      super
      @guard_inputs = Lain::CLI::ToolGuard::Inputs.new(
        ledger: Lain::Sensitivity::Ledger.new, approvals: nil,
        sensitivity: Lain::Sensitivity::Policy::Null.instance,
        test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared
      )
    end

    def approvals = nil
    def policy_switch = Lain::Tools::Subagent::UNGATED
    def mode_switch = UNSWITCHED
    def sensitivity = Lain::Sensitivity::Policy::Null.instance
    # A board that was never wired knows nothing about who is attached, so a
    # child gated by UNGATED reads the sentence {Lain::Effect::Handler::Gate}
    # produces on its own.
    def denial = Lain::Effect::Handler::Gate::DENIAL

    def inspect = "SpecNulls::NoSwitchboard"
    alias_method :to_s, :inspect
  end.new.freeze
end
