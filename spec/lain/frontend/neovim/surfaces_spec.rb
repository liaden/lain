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
  subject(:surfaces) { described_class.new(rpc:, approval_view:) }

  # The frontend's own approval surface, handed over exactly as
  # {Lain::Frontend::Neovim} hands over the one the repl binds. There is no
  # default for it (see the constructor), so every example states it.
  let(:approval_view) { Lain::Frontend::Neovim::ApprovalView.new(rpc:) }

  let(:rpc) do
    Class.new do
      attr_reader :views, :renders, :approvals

      def initialize
        @views = []
        @renders = []
        @approvals = []
      end

      def post_view(name, lines, editable: false, generation: nil) = @views << [name, lines, editable, generation]
      def post_render(lines) = @renders << lines

      # lain://approval's own inlet, and the reason it is a SEPARATE method
      # rather than a fourth `post_view`: the runtime writes b:lain_approval_rows
      # from it, and a buffer primed through `set_view` would have no row count
      # at all -- so its `y`/`n` gestures would be inert on a list that looks
      # answerable ({Lain::Frontend::Neovim::ApprovalView}'s own note).
      def set_approval(lines, generation, rows) = @approvals << { lines:, generation:, rows: }

      def names = @views.map(&:first)
      def stamps = @views.to_h { |posted| [posted.first, posted.last] }
    end.new
  end

  def tool_output(bytes) = Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes:)

  describe "#prime" do
    # The six views that ride `post_view`. lain://approval is primed too (see
    # below) and is deliberately NOT in this list: it goes out through
    # `set_approval`, so a seventh name here would mean the buffer had been
    # created without its row count.
    it "posts every projection's at-rest state, so an idle session shows the whole buffer set" do
      surfaces.prime

      expect(rpc.names).to contain_exactly(Lain::Frontend::Neovim::JournalView::NAME,
                                           Lain::Frontend::Neovim::Buffers::TimelineView::NAME,
                                           Lain::Frontend::Neovim::Buffers::WORKSPACE,
                                           Lain::Frontend::Neovim::Buffers::DIFF,
                                           Lain::Frontend::Neovim::InboxView::NAME,
                                           Lain::Frontend::Neovim::RequestBuffer::REQUEST)
    end

    # UX4. A human who went looking for the approval surface at rest found no
    # buffer at all, because this collaborator did not hold the view that draws
    # it -- the view hung off {Lain::Frontend::Neovim} and only ever rendered
    # from its own watch fiber, which nothing spawns until a call is gated.
    it "primes lain://approval through its own inlet, so the surface exists before anything is parked" do
      surfaces.prime

      expect(rpc.approvals.last[:lines]).to eq(Lain::Frontend::Neovim::ApprovalView::EMPTY)
    end

    it "primes it with no rows, so the runtime's `if rows > 0` guard takes no window" do
      surfaces.prime

      expect(rpc.approvals.last[:rows]).to eq(0)
    end

    # PANEL FIX 1, and it is the defect the panel's revert probe found rather
    # than a tightening for its own sake: with `approval_view:` DEFAULTED, the
    # `approval_view: @approval_view` argument could be deleted from
    # {Lain::Frontend::Neovim}'s one call site and all four live `:nvim`
    # examples stayed GREEN -- Surfaces would build a second view of its own,
    # prime it, and put a buffer on screen that the repl's bound view knows
    # nothing about. That is UX4 again, one level in, and the live specs cannot
    # see it because priming and handing-over are different claims.
    #
    # So the hand-over is UNREPRESENTABLE-IF-MISSING rather than merely
    # untested, which is the doctrine {Lain::Sensitivity::Policy} already
    # follows by building its own Filter so that a disagreeing pair cannot be
    # constructed at all. The one production call site already passes it.
    it "cannot be built without the approval view, so the mis-wire fails at construction" do
      expect { described_class.new(rpc:) }.to raise_error(ArgumentError, /approval_view/)
    end

    # The other half of the constructor's promise: required is not enough on
    # its own, because a constructor could take the view and prime something
    # else. The object the editor's `y` resolves through is the one
    # {Lain::CLI::Repl} bound -- {Lain::Frontend::Neovim}'s own -- and a
    # Surfaces that primed a view of its own would leave the buffer on screen
    # and the object answering gestures as two different objects, drifting
    # apart in silence.
    it "primes the view it was HANDED rather than one of its own" do
      approval_view = Class.new do
        attr_reader :primes

        def initialize = @primes = 0
        def prime = @primes += 1
      end.new

      described_class.new(rpc:, approval_view:).prime

      expect(approval_view.primes).to eq(1)
      expect(rpc.approvals).to be_empty
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

    # A reminder is bytes off disk -- a manifest path, a memory title -- so it
    # can be invalid UTF-8, and `String#split` RAISES on those. Nothing above
    # this rescues it: {Surfaces#prime} rescues only ClosedQueueError, so
    # {Lain::Frontend::Neovim#drain}'s `rescue StandardError` records a worker
    # death and every view goes dark AT ATTACH. `legible`'s scrub is the house
    # answer two files over (Review::Surface::Text, ReviewView).
    it "primes a workspace whose reminders are not valid UTF-8, rather than taking every view dark" do
      reminders = [(+"reminder caf\xE9 here").force_encoding(Encoding::UTF_8)]
      session = Class.new do
        def initialize(reminders) = @reminders = reminders
        attr_reader :reminders

        def pinned?(_digest) = false
      end.new(reminders)

      expect { described_class.new(rpc:, approval_view:, session:).prime }.not_to raise_error
      expect(rpc.views.flat_map { |view| view[1] }).to include(/reminder caf\?* here/)
    end

    it "swallows a render queue closed under it -- an RPC thread dead this early is loud elsewhere" do
      dead = closed_rpc

      expect { over(dead).prime }.not_to raise_error
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

    # T17/F17. `nvim_buf_set_lines` refuses an item containing a newline and the
    # render rides `nvim_exec_lua` as a NOTIFY, so a view that emits one loses
    # every later write to its buffer in silence -- the frozen-view defect
    # manual QA found on lain://timeline. lain://inbox was the second exposure:
    # its rows interpolate a model-authored question, and a question is prose.
    it "keeps a multi-line question on one inbox row, so the row still names its set" do
      surfaces.post(Lain::Telemetry::Message.new(digest: "blake3:q2", kind: :message, from: "orchestrator",
                                                 to: "human", payload: { "question" => "which db?\nand why?" },
                                                 causal_parents: [], correlation: nil))

      posted = rpc.views.select { |view| view.first == Lain::Frontend::Neovim::InboxView::NAME }.flat_map { |view| view[1] }
      expect(posted.grep(/\n/)).to be_empty
      expect(posted).to include(/which db\? and why\?/)
    end

    it "swallows a render queue closed under it, so a last render racing the death is not a second failure" do
      dead = closed_rpc

      expect { over(dead).post(tool_output("hello")) }.not_to raise_error
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

  # Every view over ONE inlet, which is what the two closed-queue examples
  # need: an approval view built over a LIVE double while the rest posted into
  # a dead one would leave the last thing {Surfaces#prime} does still working,
  # and the rescue under test is the one covering all of them.
  def over(inlet) = described_class.new(rpc: inlet, approval_view: Lain::Frontend::Neovim::ApprovalView.new(rpc: inlet))

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
      def set_approval(*) = raise(ClosedQueueError)
    end.new
  end
end
