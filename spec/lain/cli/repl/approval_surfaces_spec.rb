# frozen_string_literal: true

require "async"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApprovalSurfacesSpecSupport
  # The minimal effect a {Approval::Queue::Pending} reads -- a name, an input,
  # and the tool_use_id the park record correlates on (auto_surface_spec's own
  # fixture shape).
  Effect = Struct.new(:name, :input, :tool_use_id)

  # A surface stand-in with the real surfaces' SHAPE: record the queue handed
  # to it, then park forever, exactly as `loop { decide(queue.dequeue) }` and
  # AutoSurface's poll loop do. It OBSERVES without consuming (queue.rb's
  # two-surface discipline), so the sibling human surface still sees every
  # pending and this spy can never make the fan-out pass by stealing the work.
  # Parking rather than returning is deliberate: a stand-in that fell off the
  # end of its block would look identical whether it was given a fiber or
  # merely called, and "given a fiber" is the whole claim under test.
  class SpySurface
    # Long enough that the spy never busies the reactor, short enough that a
    # stopped task unwinds promptly.
    POLL = 0.01

    attr_reader :queues

    def initialize
      @queues = []
    end

    def watch(queue)
      @queues << queue
      loop { Async::Task.current.sleep(POLL) }
    end
  end
end

# The fan-out {Repl#respond} depends on and no spec exercised: `watch(task)`
# spawns one fiber per LIVE surface over one queue, splats the opt-in auto
# surface in without leaving a nil hole, and spawns nothing at all when no
# queue was wired (--yolo).
#
# Every example asserts on an effect a fiber HAD -- a pending approved by a
# sibling, a queue a spy was handed, a read the conductor served -- because
# "passes because nothing ran" is the easy failure in a three-fiber test. The
# queue's timeout is short on purpose: it is the counterfactual. A surface that
# never got a fiber leaves its pending to the fail-closed clock, which denies
# it and signs the denial `timeout`, so the absence is visible rather than
# quiet.
RSpec.describe Lain::CLI::Repl::ApprovalSurfaces do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # A REAL queue, not a double: the claim is that N surfaces watch ONE queue
  # and a SIBLING fiber wakes the parked gated call, and only the real
  # park/decide path can show that.
  let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.5) }
  let(:notifier) { ApprovalSurfacesSpecSupport::SpySurface.new }
  let(:auto_surface) { ApprovalSurfacesSpecSupport::SpySurface.new }
  let(:tty) { instance_double(Lain::Frontend::TTY) }
  # The seam {#approval_surface}'s reader routes through. "y" is the ONLY way a
  # pending can end up approved at all, so an approval is proof this reader ran
  # -- on the TTY surface's own fiber, since the gated fiber is parked.
  let(:conductor) { instance_double(Lain::CLI::Conductor, read_reply: "y") }

  let(:editor) { ApprovalSurfacesSpecSupport::SpySurface.new }

  def surfaces(approvals: queue, auto: nil, attached: nil)
    described_class.new(approvals:, notifier:, auto_surface: auto, tty:, conductor:)
                   .tap { |built| built.bind_editor(attached) }
  end

  def effect = ApprovalSurfacesSpecSupport::Effect.new("bash", { "command" => "ls" }, "tu_1")

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

  # Spawn the fan-out and drive ONE real gated call through it. Returns the
  # verdict the gated fiber received and the tasks `watch` handed back; the
  # spies, the conductor, and the journal carry the rest of the evidence.
  # `with_timeout` bounds the whole thing so a fan-out that spawned no
  # answerer AND no clock fails in words rather than hanging the suite.
  def fan_out(auto: nil, attached: nil)
    Sync do |task|
      watched = surfaces(auto:, attached:).watch(task)
      gated = task.async { queue.call(effect, nil) }
      { verdict: task.with_timeout(2) { gated.wait }, watched: }
    ensure
      watched&.each { |surface| surface&.stop }
    end
  end

  # The --yolo shape: no queue was wired. `watch`'s return is handed back for
  # the example to assert on, and anything it DID spawn is stopped -- a fan-out
  # that ignored the guard would otherwise park its fibers forever and hang
  # this Sync instead of failing it.
  def watch_without_a_queue
    Sync do |task|
      watched = surfaces(approvals: nil, auto: auto_surface, attached: editor).watch(task)
      watched
    ensure
      watched&.each { |surface| surface&.stop }
    end
  end

  it "answers the parked call at the TTY surface it builds -- a sibling fiber, never the gated one" do
    expect(fan_out[:verdict]).to be(true)
  end

  it "routes that surface's read through the conductor, over THIS session's tty" do
    fan_out

    expect(conductor).to have_received(:read_reply).with(tty, /approve bash/)
  end

  it "signs the decision with the TTY surface's own name, so a transcript names who approved" do
    fan_out

    expect(decisions.last.fetch("surface")).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
  end

  it "hands the notifier the SAME queue the TTY surface watches" do
    fan_out

    expect(notifier.queues).to contain_exactly(be(queue))
  end

  it "hands the opt-in auto surface that same queue when one is wired" do
    fan_out(auto: auto_surface)

    expect(auto_surface.queues).to contain_exactly(be(queue))
  end

  it "spawns one fiber per live surface: three, under --auto-approve" do
    expect(fan_out(auto: auto_surface)[:watched].size).to eq(3)
  end

  # T36. These two examples and the one above are the closest anything came to
  # pinning the editor surface's ABSENCE as correct, and they did not: the
  # counts they assert are counts for the inputs they give, and an unattached
  # editor really is two. What was missing was any example giving the other
  # input at all -- which is the same shape as a capability with no reachable
  # construction, one step further out.
  describe "--nvim: the editor's own approval list is the fourth peer" do
    it "spawns a fiber for it too, so a parked call is drawn where the human is looking" do
      expect(fan_out(attached: editor)[:watched].size).to eq(3)
    end

    it "hands it the SAME queue the TTY surface watches, never a copy" do
      fan_out(attached: editor)

      expect(editor.queues).to contain_exactly(be(queue))
    end

    it "makes four with --auto-approve, and the human surface still answers through all of them" do
      result = fan_out(auto: auto_surface, attached: editor)

      expect(result[:watched].size).to eq(4)
      expect(result[:verdict]).to be(true)
    end

    it "spawns nothing for an editor that is not attached, which is every headless chat" do
      watched = fan_out[:watched]

      expect(watched).to contain_exactly(an_instance_of(Async::Task), an_instance_of(Async::Task))
      expect(editor.queues).to be_empty
    end
  end

  it "compacts the absent auto surface away rather than leaving a nil hole in the set" do
    watched = fan_out[:watched]

    # Repl#respond's ensure walks this set to stop each surface, so a nil
    # member is a hole in the shutdown path, not a cosmetic detail.
    expect(watched).to contain_exactly(an_instance_of(Async::Task), an_instance_of(Async::Task))
  end

  it "still lets the human surface answer with all three watching -- the third is additive" do
    expect(fan_out(auto: auto_surface)[:verdict]).to be(true)
  end

  describe "--yolo: no queue was wired" do
    it "spawns nothing at all, and says so by answering nil" do
      expect(watch_without_a_queue).to be_nil
    end

    it "hands no surface the queue it does not have" do
      watch_without_a_queue

      expect([notifier.queues, auto_surface.queues, editor.queues]).to all(be_empty)
    end

    it "builds no approval policy either: an unwatched session pays for no surface" do
      expect(Lain::Frontend::ApprovalPolicy).not_to receive(:new)

      watch_without_a_queue
    end
  end

  it "memoizes the policy it builds, so every watch of one session shares one surface" do
    built = surfaces

    expect(built.approval_surface).to be(built.approval_surface)
  end
end
