# frozen_string_literal: true

require "async"

# The snapshot duck, plus a hook so a stop can be made to land ON the settled
# path -- the case the `rescue`/`else` split exists to keep out of the
# cancellation arm. In a module body for the reason every other spec fixture
# here is (Lint/ConstantDefinitionInBlock).
module ToolDeliverySpecSupport
  class Snapshots
    attr_reader :written

    def initialize(trail: [], &hook)
      @written = []
      @trail = trail
      @hook = hook
    end

    def prime
      @trail << :prime
      self
    end

    def write(timeline:, paths:)
      @trail << :write
      @written << [timeline, paths]
      @hook&.call
    end
  end
end

# Where ONE tool-calling turn's results land on the Timeline: settled, or torn
# by an interrupt mid-dispatch. The REAL tear -- a live `Async` cancel
# arriving while a tool is genuinely parked -- is
# spec/lain/seams/tool_cancellation_spec.rb; what is pinned here is this
# object's own contract, driven with a handler that raises the stop directly so
# each arm is reachable without a clock.
RSpec.describe Lain::Agent::ToolDelivery do
  let(:journal) { [] }
  let(:raised) { [] }
  let(:snapshots) { ToolDeliverySpecSupport::Snapshots.new }
  let(:session) { Lain::Session.new }
  let(:response) { tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }]) }

  # The tear window's own shape: a user turn, then the assistant turn carrying
  # the calls, committed and unanswered.
  let(:timeline) do
    Lain::Timeline.empty(store: Lain::Store.new)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: response.content)
  end

  # Every `let` these examples drive is forced BEFORE any reactor opens. RSpec
  # memoizes a `let` under a Mutex, and a Mutex taken inside an `Async` task is
  # owned by the FIBER rather than by the thread -- so a FIRST read from inside
  # `Sync` parks the reactor's fiber on a lock the example's own fiber is
  # holding, and the reactor sits in `select` until the watchdog fires. A read
  # of an already-memoized `let` never takes the lock, which is why forcing them
  # here is the whole fix. (watchdog.rb's header records the same class of trap,
  # found the expensive way.)
  before { [response, timeline, session, snapshots, journal, raised] }

  def delivery_over(handler, slot: snapshots)
    described_class.new(runner: Lain::Agent::ToolRunner.new(handler:), snapshots: slot, journal:)
  end

  def echoing = Lain::Effect::Handler::Mock.new { |effect, _| Lain::Tool::Result.ok("ran #{effect.tool_use_id}") }

  # `Async::Stop` is not a StandardError, so it travels straight through the
  # handler's gate-3 conversion -- which is exactly how a real interrupt reaches
  # this object.
  def stopping_after(id)
    Lain::Effect::Handler::Mock.new do |effect, _|
      raise Async::Stop if effect.tool_use_id == id

      Lain::Tool::Result.ok("ran #{effect.tool_use_id}")
    end
  end

  def perform(handler, **rest)
    committed = nil
    Sync { delivery_over(handler, **rest).perform(response, timeline:, session:) { |turn| committed = turn } }
    committed
  end

  describe "a turn that settles" do
    it "commits every result as one user turn and snapshots the workspace after it" do
      committed = perform(echoing)

      expect(committed.head.role).to eq("user")
      expect(committed.head.content.map { |block| block["content"] }).to eq(["ran tu_1", "ran tu_2"])
      expect(snapshots.written.map(&:first)).to eq([committed])
    end

    it "journals no cancellation" do
      perform(echoing)

      expect(journal.grep(Lain::Telemetry::ToolCancelled)).to be_empty
    end
  end

  describe "a turn torn mid-dispatch" do
    let(:torn) do
      committed = nil
      Sync do
        delivery_over(stopping_after("tu_2")).perform(response, timeline:, session:) { |t| committed = t }
      rescue Async::Stop => e
        raised << e
      end
      committed
    end

    it "commits the finished tool's own output beside a cancellation for the rest" do
      expect(torn.head.content.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
      expect(torn.head.content.first["content"]).to eq("ran tu_1")
      expect(torn.head.content.last["is_error"]).to be(true)
    end

    it "re-raises the interrupt, so a stop still ends the run it was asked to end" do
      torn

      expect(raised.first).to be_a(Async::Stop)
    end

    it "journals what was cancelled against the assistant turn that made the calls" do
      torn

      expect(journal.grep(Lain::Telemetry::ToolCancelled).first)
        .to have_attributes(head: timeline.head_digest, cancelled: ["tu_2"],
                            running: ["tu_2"], completed: ["tu_1"])
    end

    # The uninterruptible region is kept free of file IO, and a lost snapshot is
    # re-derived from disk on the next mutating turn.
    it "writes no workspace snapshot" do
      torn

      expect(snapshots.written).to be_empty
    end
  end

  # The interrupt OUTRANKS a repair that cannot be built. A stranded call whose
  # id no tool_result can name (gate 4) makes the whole turn unanswerable, and
  # before this fix the builder's bare ArgumentError escaped ahead of the
  # `raise e` and REPLACED the stop -- so a Ctrl-C on a turn carrying a
  # malformed tool_use id surfaced as an ArgumentError with no cancellation
  # commit and no record. Now the refusal is named and swallowed, and the stop
  # still lands; the honest torn head it leaves is what the load-side repair
  # refuses namedly.
  it "lets the interrupt through when a stranded call names an id no result can pair to" do
    unpairable = tool_response(["tu_1", "echo", { "text" => "a" }], ["", "echo", {}])
    chain = Lain::Timeline.empty(store: Lain::Store.new)
                          .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                          .commit(role: :assistant, content: unpairable.content)
    committed = nil

    Sync do
      delivery_over(stopping_after("tu_1")).perform(unpairable, timeline: chain, session:) { |t| committed = t }
    rescue Async::Stop => e
      raised << e
    end

    expect(raised.first).to be_a(Async::Stop)
    expect(committed).to be_nil
    expect(journal.grep(Lain::Telemetry::ToolCancelled)).to be_empty
  end

  # A stop landing on the SETTLED path -- here, on the snapshot write that
  # follows the commit -- must not re-enter the cancellation arm and answer, a
  # second time, calls the first commit already answered. `rescue`/`else` is
  # what makes that structural: an `else` body is not covered by the rescue.
  it "does not commit twice when the stop lands after the settled commit" do
    stopping_snapshots = ToolDeliverySpecSupport::Snapshots.new { raise Async::Stop }
    committed = nil

    Sync do
      expect do
        delivery_over(echoing, slot: stopping_snapshots)
          .perform(response, timeline:, session:) { |turn| committed = turn }
      end.to raise_error(Async::Stop)
    end

    expect(committed.to_a.map(&:role)).to eq(%w[user assistant user])
    expect(committed.head.content.map { |block| block["is_error"] }).to eq([false, false])
    expect(journal.grep(Lain::Telemetry::ToolCancelled)).to be_empty
  end

  # git missing from PATH once left the turn's tool calls unanswered: the
  # prime raised before any tool ran. A failed shadow store now costs the turn
  # its shadow record, never its answers.
  it "answers every call when the shadow store cannot run git", :seam do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |state|
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state })
        no_git = ->(*, **) { raise Errno::ENOENT, "git" }
        scope = Lain::Workspace::Snapshot::Scope::ShadowGit.new(paths:, shell_out_factory: no_git)
        slot = Lain::Agent::SnapshotSlot.new(root:, scope:, paths:)

        committed = perform(echoing, slot:)

        expect(committed.head.content.map { |block| block["content"] }).to eq(["ran tu_1", "ran tu_2"])
      end
    end
  end

  describe "the snapshot slot it is handed" do
    it "is primed before any tool runs, so a baseline predates the turn's first write" do
      trail = []
      recording = Lain::Effect::Handler::Mock.new do |effect, _|
        trail << effect.tool_use_id
        Lain::Tool::Result.ok("ran")
      end

      perform(recording, slot: ToolDeliverySpecSupport::Snapshots.new(trail:))

      expect(trail).to eq([:prime, "tu_1", "tu_2", :write])
    end

    # Read at each settle rather than captured at construction: a posture flip
    # between two turns has to reach the very next snapshot.
    it "writes each settle through whichever writer the slot holds by then", :seam do
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |state|
          notes = []
          log = Lain::Workspace::SnapshotLog.new(observer: ->(event) { notes << event.body.fetch("snapshot_scope") })
          slot = Lain::Agent::SnapshotSlot.new(root:, scope: :write_set, log:,
                                               paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state,
                                                                             "HOME" => state }))
          File.write(File.join(root, "a.rb"), "one")
          session.record_write(File.join(root, "a.rb"))

          perform(echoing, slot:)
          slot.rebind(:shadow_git)
          perform(echoing, slot:)

          expect(notes).to eq([Lain::Workspace::Snapshot::Scope::WriteSet::NOTE,
                               Lain::Workspace::Snapshot::Scope::ShadowGit::NOTE])
        end
      end
    end
  end
end
