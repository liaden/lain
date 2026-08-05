# frozen_string_literal: true

require "async"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ConversationScopeSpecSupport
  # A reply surface with the real one's SHAPE: it parks forever, exactly as
  # {Lain::CLI::HumanReplies#editor_reply_loop}'s consumer does, so an example
  # can tell "given a fiber and stopped" from "never given one at all" -- a
  # stand-in that fell off the end of its block would look identical either way,
  # and being stopped is the whole claim under test.
  class ParkingSurface
    POLL = 0.01

    def self.spawn(task) = task.async { loop { Async::Task.current.sleep(POLL) } }
  end
end

# T33's answer to "which object owns the editor consumer's lifetime". Both the
# fleet's reactor and the editor's gesture rail outlive any one ask, and both
# have to be stopped on EVERY exit from the conversation -- a parked fiber holds
# the repl's Sync open forever, which is why every `.stop` in {Repl#respond}'s
# ensure is deliberate and why this scope owes the same.
RSpec.describe Lain::CLI::Repl::ConversationScope do
  let(:supervisor) { instance_double(Lain::Supervisor, run: nil, stop: nil) }

  # The surfaces the scope is handed, kept so an example can ask each whether it
  # is still running after #close.
  def scope_over(surfaces:)
    replies = Class.new do
      def initialize(surfaces) = @surfaces = surfaces
      def session_surfaces(task) = @surfaces.call(task)
    end.new(surfaces)
    described_class.new(supervisor:, replies:)
  end

  it "runs the supervisor's reactor on the conversation's own task" do
    Sync do |task|
      scope_over(surfaces: ->(_task) { [] }).open(task).close

      expect(supervisor).to have_received(:run).with(task)
    end
  end

  it "stops every surface it opened, so the conversation's Sync can return" do
    parked = nil

    Sync do |task|
      scope = scope_over(surfaces: lambda { |inner|
        parked = ConversationScopeSpecSupport::ParkingSurface.spawn(inner)
        [parked]
      })
      scope.open(task)
      scope.close
    end

    expect(parked).not_to be_running
  end

  it "farewells the fleet after the surfaces, not before" do
    Sync do |task|
      scope_over(surfaces: ->(_task) { [] }).open(task).close

      expect(supervisor).to have_received(:stop).once
    end
  end

  # The path a bad reactor takes: nothing was opened, so there is nothing to
  # stop -- and the fleet's farewell is still owed.
  it "closes cleanly when it was never opened" do
    expect { scope_over(surfaces: ->(_task) { [] }).close }.not_to raise_error
    expect(supervisor).to have_received(:stop)
  end

  # A surface whose stop misbehaves must not cost the fleet its
  # drain-on-shutdown: the farewell is in an ensure for exactly this.
  it "farewells the fleet even when a surface's stop raises" do
    refusing = Class.new { def stop = raise("this surface will not stop") }.new

    Sync do |task|
      scope = scope_over(surfaces: ->(_inner) { [refusing] })
      scope.open(task)
      expect { scope.close }.to raise_error("this surface will not stop")
    end

    expect(supervisor).to have_received(:stop)
  end
end
