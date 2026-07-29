# frozen_string_literal: true

# The resend delivery pipeline: one edited-buffer hand-off becomes a projection
# on the render Channel AND -- when a real bridge is wired -- an offer that
# reaches the provider.
#
# Pure: the worker THREAD stays in {Neovim}, so nothing here spawns anything and
# this runs untagged on every plain `rspec`. It had no spec at all, which left
# the two orderings below -- projection before dispatch, and the rebuild staying
# UNFORCED for an unbridged resend -- as comments rather than tests. Both are
# the sort of thing a refactor reverses silently.
module ResenderSpecSupport
  # Records the render lines it is handed, and can be told to behave like a
  # queue that has since closed.
  class FakeRpc
    attr_reader :renders

    def initialize(closed: false)
      @renders = []
      @closed = closed
    end

    def post_render(lines)
      raise ClosedQueueError if @closed

      @renders << lines
    end
  end

  # A wired bridge: records the call, optionally fires the upfront hook, and
  # answers a notice. Forces the rebuild block only when asked to, which is the
  # axis {Unbridged} sits on the other end of.
  class FakeBridge
    attr_reader :calls, :rebuilt

    def initialize(notice: nil, announce: false, force_rebuild: false)
      @notice = notice
      @announce = announce
      @force_rebuild = force_rebuild
      @calls = 0
      @rebuilt = []
    end

    def offer(on_attempt:)
      @calls += 1
      on_attempt.call if @announce
      @rebuilt << yield if @force_rebuild
      @notice
    end
  end

  # Rebuilding is the expensive, fallible half; this records whether it was ever
  # forced and can be made to raise, which is what an edit that parses as JSON
  # but is not request-shaped does.
  class FakeRequestBuffer
    attr_reader :rebuilds

    def initialize(raising: false)
      @raising = raising
      @rebuilds = 0
    end

    def rebuild(resent)
      @rebuilds += 1
      raise ArgumentError, "not request-shaped" if @raising

      "rebuilt:#{resent}"
    end
  end
end

RSpec.describe Lain::Frontend::Neovim::Resender do
  subject(:resender) { described_class.new(channel:, rpc:, bridge:, request_buffer:) }

  let(:channel) { Lain::Channel::DropOldest.new }
  let(:rpc) { ResenderSpecSupport::FakeRpc.new }
  let(:bridge) { ResenderSpecSupport::FakeBridge.new }
  let(:request_buffer) { ResenderSpecSupport::FakeRequestBuffer.new }
  let(:resent) { "resent-record" }

  describe "a resend with nothing to deliver" do
    it "does nothing at all for nil -- no projection, no offer, no render" do
      resender.deliver(nil)

      expect(channel.size).to eq(0)
      expect(bridge.calls).to eq(0)
      expect(rpc.renders).to be_empty
    end
  end

  describe "the delivery order" do
    it "pushes the projection onto the render Channel" do
      resender.deliver(resent)

      expect(channel.size).to eq(1)
      expect(channel.pop).to eq(resent)
    end

    # The whole point of the ordering: the human's diff must never wait on a
    # model round trip. A bridge that blocks must find the projection ALREADY
    # queued -- so the probe reads the queue depth at the moment it is offered
    # to, which is the only place that ordering is observable.
    it "pushes the projection BEFORE offering to the bridge, so a blocking wire cannot delay the diff" do
      depth_when_offered = nil
      queue = channel
      probing_bridge = Object.new
      probing_bridge.define_singleton_method(:offer) do |on_attempt: nil, &_rebuild|
        _ = on_attempt # the real signature carries it; this probe only reads the queue
        depth_when_offered = queue.size
        nil
      end

      described_class.new(channel:, rpc:, bridge: probing_bridge, request_buffer:).deliver(resent)

      expect(depth_when_offered).to eq(1)
    end
  end

  describe "the upfront attempt notice" do
    let(:bridge) { ResenderSpecSupport::FakeBridge.new(announce: true) }

    # S2: the human is told an attempt is under way rather than watching an idle
    # diff while the wire blocks.
    it "renders the attempt line when the bridge fires its hook" do
      resender.deliver(resent)

      expect(rpc.renders).to include([described_class::ATTEMPT])
    end

    it "does not render an attempt line when the bridge never fires the hook" do
      described_class.new(channel:, rpc:, bridge: ResenderSpecSupport::FakeBridge.new, request_buffer:)
                     .deliver(resent)

      expect(rpc.renders).to be_empty
    end

    # Best-effort: a dead render queue must not become a "resend failed"
    # narrative, and the hook fires before the slot is staged, so the dispatch
    # itself is untouched.
    it "swallows a closed render queue rather than failing the resend" do
      closed_rpc = ResenderSpecSupport::FakeRpc.new(closed: true)

      expect { described_class.new(channel:, rpc: closed_rpc, bridge:, request_buffer:).deliver(resent) }
        .not_to raise_error
      expect(bridge.calls).to eq(1)
    end
  end

  describe "the bridge's notice" do
    it "renders a notice through the same append path every render takes" do
      noticed = ResenderSpecSupport::FakeBridge.new(notice: "resend: refused mid-flight")

      described_class.new(channel:, rpc:, bridge: noticed, request_buffer:).deliver(resent)

      expect(rpc.renders).to eq([["resend: refused mid-flight"]])
    end

    # nil is projection-only's NORMAL, not an error, so it must render nothing
    # rather than an empty line.
    it "renders nothing at all when the bridge answers nil" do
      resender.deliver(resent)

      expect(rpc.renders).to be_empty
    end
  end

  describe "the rebuild, which rides a block" do
    # The reason it is a block: an unbridged resend must stay byte-identical to
    # the pure projection it was, never raising over an edit that parses as JSON
    # but would not rebuild into a Request.
    it "is NOT forced when the bridge declines without asking for it" do
      resender.deliver(resent)

      expect(request_buffer.rebuilds).to eq(0)
    end

    it "is forced, once, when a wired bridge asks for it" do
      forcing = ResenderSpecSupport::FakeBridge.new(force_rebuild: true)

      described_class.new(channel:, rpc:, bridge: forcing, request_buffer:).deliver(resent)

      expect(request_buffer.rebuilds).to eq(1)
      expect(forcing.rebuilt).to eq(["rebuilt:#{resent}"])
    end

    # The combination that makes the laziness matter: a non-rebuildable edit,
    # unbridged, still delivers its projection and never raises.
    it "delivers the projection for an edit that could never rebuild, so long as nobody forces it" do
      raising = ResenderSpecSupport::FakeRequestBuffer.new(raising: true)

      expect { described_class.new(channel:, rpc:, bridge:, request_buffer: raising).deliver(resent) }
        .not_to raise_error
      expect(channel.size).to eq(1)
      expect(raising.rebuilds).to eq(0)
    end
  end

  # Against the REAL Null, not a stand-in: this is the configuration plain
  # --nvim actually runs, and the claim is that it is projection-only.
  describe "against the real Unbridged default" do
    subject(:resender) do
      described_class.new(channel:, rpc:, bridge: Lain::Frontend::Neovim::Unbridged, request_buffer:)
    end

    it "journals the projection, renders no notice, and never forces the rebuild" do
      resender.deliver(resent)

      expect(channel.size).to eq(1)
      expect(rpc.renders).to be_empty
      expect(request_buffer.rebuilds).to eq(0)
    end

    it "never raises even when the edit could not rebuild into a Request" do
      raising = ResenderSpecSupport::FakeRequestBuffer.new(raising: true)
      unbridged = described_class.new(channel:, rpc:, bridge: Lain::Frontend::Neovim::Unbridged,
                                      request_buffer: raising)

      expect { unbridged.deliver(resent) }.not_to raise_error
    end
  end
end
