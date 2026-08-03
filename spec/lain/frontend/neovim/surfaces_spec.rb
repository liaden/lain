# frozen_string_literal: true

# The frontend's PROJECTIONS, as the one collaborator that owns them: the
# journal's append view, the read-only buffer set, and the editable request
# buffer, plus the two things the frontend ever asked of all three together --
# prime them at attach, and post one event's projections. {Lain::Frontend::Neovim}
# was holding the three objects AND those two loops beside its three-thread
# lifecycle, which is two responsibilities and one `Metrics/ClassLength` away
# from the limit.
RSpec.describe Lain::Frontend::Neovim::Surfaces do
  # The render inlet as these views address it ({RpcThread}'s outbound duck),
  # recorded rather than driven: nothing here touches nvim.
  subject(:surfaces) { described_class.new(rpc:) }

  let(:rpc) do
    Class.new do
      attr_reader :views, :renders

      def initialize
        @views = []
        @renders = []
      end

      def post_view(name, lines, editable: false, generation: nil) = @views << [name, lines, editable, generation]
      def post_render(lines) = @renders << lines

      def names = @views.map(&:first)
      def stamps = @views.to_h { |posted| [posted.first, posted.last] }
    end.new
  end

  def tool_output(bytes) = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes:)

  describe "#prime" do
    it "posts every projection's at-rest state, so an idle session shows the whole buffer set" do
      surfaces.prime

      expect(rpc.names).to contain_exactly(Lain::Frontend::Neovim::JournalView::NAME,
                                           Lain::Frontend::Neovim::Buffers::TimelineView::NAME,
                                           Lain::Frontend::Neovim::Buffers::WORKSPACE,
                                           Lain::Frontend::Neovim::Buffers::DIFF,
                                           Lain::Frontend::Neovim::InboxView::NAME,
                                           Lain::Frontend::Neovim::RequestBuffer::REQUEST)
    end

    it "primes the one editable view as editable, so the human's edit is not locked out" do
      surfaces.prime

      editable = rpc.views.select { |posted| posted[2] }.map(&:first)
      expect(editable).to eq([Lain::Frontend::Neovim::RequestBuffer::REQUEST])
    end

    # The stamp is the editor's only honest answer to "which rendering am I
    # looking at" (T16), so it rides with the rendering it belongs to -- and
    # ONLY the inbox has one, because it is the only view whose gesture
    # resolves through a rendering index.
    it "stamps the inbox's post with the rendering the gesture must name, and stamps no other view" do
      surfaces.prime

      stamps = rpc.stamps
      expect(stamps.fetch(Lain::Frontend::Neovim::InboxView::NAME)).to be_a(Integer)
      expect(stamps.except(Lain::Frontend::Neovim::InboxView::NAME).values.compact).to be_empty
    end

    it "swallows a render queue closed under it -- an RPC thread dead this early is loud elsewhere" do
      expect { described_class.new(rpc: closed_rpc).prime }.not_to raise_error
    end
  end

  describe "#post" do
    it "appends the journal's lines for an event the journal presents" do
      surfaces.post(tool_output("hello"))

      expect(rpc.renders).to eq([["[t1 stdout] hello"]])
    end

    it "appends nothing for an event that renders no journal lines" do
      surfaces.post(Lain::Telemetry::TurnUsage.new(digest: "blake3:x", model: "m", stop_reason: :end_turn, usage: {}))

      expect(rpc.renders).to be_empty
    end

    it "posts every view the event moved" do
      surfaces.post(tool_output("hello"))

      expect(rpc.names).to include(Lain::Frontend::Neovim::Buffers::WORKSPACE)
    end

    # The stamp's absence is ARITY, not a value, and the two must not be
    # confusable: `[name, lines, generation].compact` sent `[name, generation]`
    # for a view with no lines, and lua's `local name, lines, gen = ...` binds
    # position 2 as the LINES. Nothing produces nil lines today, which is
    # exactly why it needs pinning rather than leaving.
    it "never lets a missing stamp shift another argument into its place" do
      queue = Lain::Frontend::Neovim::RenderQueue.new(capacity: 4)
      queue.post_view("lain://timeline", nil)
      queue.post_view("lain://inbox", nil, generation: 5)

      expect(queued_args(queue)).to eq([["lain://timeline", nil], ["lain://inbox", nil, 5]])
    end

    # A stamp that repeated would name two different renderings, which is the
    # whole defect it closes: the buffer the human holds must be nameable.
    it "moves the inbox's stamp on with each rendering it posts" do
      surfaces.prime
      surfaces.post(Lain::Telemetry::Message.new(digest: "blake3:q1", kind: :message, from: "orchestrator",
                                                 to: "human", payload: { "question" => "which db?" },
                                                 causal_parents: [], correlation: nil))

      stamps = rpc.views.select { |posted| posted.first == Lain::Frontend::Neovim::InboxView::NAME }.map(&:last)
      expect(stamps.size).to eq(2)
      expect(stamps.uniq).to eq(stamps)
    end

    it "swallows a render queue closed under it, so a last render racing the death is not a second failure" do
      expect { described_class.new(rpc: closed_rpc).post(tool_output("hello")) }.not_to raise_error
    end
  end

  # The resend worker's half: the edited lines become a fresh record, which the
  # {Lain::Frontend::Neovim::Resender} then delivers. Surfaces owns the buffer
  # they are rebuilt through, so it owns this hand-off.
  describe "#resend" do
    it "answers nothing when no request has ever been rendered" do
      expect(surfaces.resend(["{}"])).to be_nil
    end
  end

  # What the queue would send to `nvim_exec_lua`, drained through a client
  # double: the argument LIST is the wire contract, so it is what is asserted.
  def queued_args(queue)
    sent = []
    session = Class.new do
      def initialize(sent) = @sent = sent
      def notify(_method, _lua, args) = @sent << args
    end.new(sent)
    queue.drain(Struct.new(:session).new(session))
    sent
  end

  # A render queue that has already been closed: {Lain::Frontend::Neovim::RenderQueue#close}'s
  # shape, which is what every producer meets once the RPC thread dies.
  def closed_rpc
    Class.new do
      def post_view(*, **) = raise(ClosedQueueError)
      def post_render(*) = raise(ClosedQueueError)
    end.new
  end
end
