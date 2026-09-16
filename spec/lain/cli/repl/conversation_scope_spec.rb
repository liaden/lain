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

# The answer to "which object owns a human surface's lifetime": the whole
# CONVERSATION. The fleet's reactor, the editor's gesture rail, the reply
# surfaces and every watcher over the parked-approval queue outlive any one
# line -- a docent child parks a call while the chat sits at rest -- and all of
# them have to be stopped on EVERY exit, because a parked fiber holds the
# repl's Sync open forever. Two prompts cannot race for the terminal any more:
# the input rail publishes them one at a time.
RSpec.describe Lain::CLI::Repl::ConversationScope do
  let(:supervisor) { instance_double(Lain::Supervisor, run: nil, stop: nil) }

  # The seams the scope asks, recording the task and attention each was handed.
  let(:replies) do
    Class.new do
      attr_reader :task, :attention

      def initialize(surfaces) = @surfaces = surfaces

      def session_surfaces(_task) = []

      def chat_surfaces(task, attention:)
        @task = task
        @attention = attention
        @surfaces.call(task)
      end
    end
  end

  let(:approvals) do
    Class.new do
      attr_reader :task, :attention

      def initialize(surfaces) = @surfaces = surfaces

      def watch(task, attention:)
        @task = task
        @attention = attention
        @surfaces.call(task)
      end
    end
  end

  def nothing = ->(_task) { [] }

  def scope_over(surfaces: nothing, watchers: nothing)
    @replies = replies.new(surfaces)
    @approvals = approvals.new(watchers)
    described_class.new(supervisor:, replies: @replies, surfaces: @approvals)
  end

  def parking(into) = ->(task) { [ConversationScopeSpecSupport::ParkingSurface.spawn(task).tap { |t| into << t }] }

  it "runs the supervisor's reactor on the conversation's own task" do
    Sync do |task|
      scope_over.open(task).close

      expect(supervisor).to have_received(:run).with(task)
    end
  end

  it "opens the reply surfaces and the approval watchers on that task, sharing one attention" do
    Sync do |task|
      scope_over.open(task).close

      expect([@replies.task, @approvals.task]).to all(be(task))
      expect(@replies.attention).to be_a(described_class::Attention).and be(@approvals.attention)
    end
  end

  it "stops every surface it opened, so the conversation's Sync can return" do
    parked = []

    Sync do |task|
      scope_over(surfaces: parking(parked), watchers: parking(parked)).open(task).close
    end

    expect(parked.size).to eq(2)
    expect(parked.none?(&:running?)).to be(true)
  end

  # The unattended shape: no queue was wired, so the approval seam answers nil
  # rather than an empty set, and there is nothing of it to stop.
  it "survives an approval seam that answers nil" do
    Sync { |task| expect { scope_over(watchers: ->(_task) {}).open(task).close }.not_to raise_error }
  end

  it "stops the reply surfaces when opening the approval watchers raises" do
    parked = []
    scope = scope_over(surfaces: parking(parked), watchers: ->(_task) { raise Lain::Error, "the watchers blew up" })

    Timeout.timeout(5) do
      Sync do |task|
        expect { scope.open(task) }.to raise_error(Lain::Error, "the watchers blew up")
        scope.close
      end
    end

    expect(parked.size).to eq(1)
    expect(parked.none?(&:running?)).to be(true)
  end

  it "farewells the fleet after the surfaces, not before" do
    Sync do |task|
      scope_over.open(task).close

      expect(supervisor).to have_received(:stop).once
    end
  end

  # The path a bad reactor takes: nothing was opened, so there is nothing to
  # stop -- and the fleet's farewell is still owed.
  it "closes cleanly when it was never opened" do
    expect { scope_over.close }.not_to raise_error
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

  # What a cockpit's command reader waits on: a parked call or a listed
  # question, whichever surface saw it. A LEVEL, asked afresh every time.
  describe described_class::Attention do
    it "reports nothing outstanding when no surface has said what to watch" do
      expect(described_class.new.outstanding?).to be(false)
    end

    it "reports outstanding while ANY watched surface has something waiting" do
      attention = described_class.new
      attention.track { false }
      attention.track { true }

      expect(attention.outstanding?).to be(true)
    end

    it "asks again each time, so a settled surface stops counting" do
      waiting = [:call]
      attention = described_class.new
      attention.track { waiting.any? }

      expect { waiting.clear }.to change(attention, :outstanding?).from(true).to(false)
    end
  end
end
