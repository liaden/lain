# frozen_string_literal: true

require "async"
require "fileutils"
require "neovim"
require "timeout"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApprovalViewSpecSupport
  # The minimal effect {Approval::Queue::Pending} reads: a name, an input, and
  # the tool_use_id the park record correlates on (auto_surface_spec's fixture
  # shape, and approval_surfaces_spec's).
  Effect = Struct.new(:name, :input, :tool_use_id)

  # An editor inlet that RECORDS instead of rendering. It answers the duck
  # {Lain::Frontend::Neovim::RpcThread} publishes -- nil once the post is
  # queued, a refusal sentence when nothing took it -- so a spec can drive both
  # halves without a real editor.
  class SpyRpc
    attr_reader :posts
    attr_accessor :refusal

    def initialize(refusal: nil)
      @posts = []
      @refusal = refusal
    end

    def set_approval(lines, generation, rows, calls, call_index)
      @posts << { lines:, generation:, rows:, calls:, call_index: }
      @refusal
    end

    def last = @posts.last
  end
end

# lain://approval, the editor's own surface on {Lain::Approval::Queue}.
#
# EVERY EXAMPLE THAT MATTERS DRIVES A REAL QUEUE AND A REAL PARKED FIBER. The
# claim under test is not "a buffer gets some lines" -- an implementation that
# renders and wires nothing passes that -- it is that answering from the editor
# UNPARKS the gated call with the verdict the human pressed, that a surface
# which lost the race changes nothing, and that a pending the clock already
# denied can never be resolved by a keypress on the row it left behind.
#
# The queue's timeout is short on purpose: it is the COUNTERFACTUAL. A view
# that resolved nothing leaves its pending to the fail-closed clock, which
# denies it and signs the denial `timeout` -- so "nothing happened" is visible
# in the verdict and in the journal rather than being quiet.
RSpec.describe Lain::Frontend::Neovim::ApprovalView do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:rpc) { ApprovalViewSpecSupport::SpyRpc.new }
  let(:view) { described_class.new(rpc:) }

  def effect(name = "bash", input = { "command" => "pwd" }, id = "tu_1")
    ApprovalViewSpecSupport::Effect.new(name, input, id)
  end

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

  # A real queue with real gated fibers parked in it. The block runs with every
  # pending admitted and the view already rendered, and the result carries the
  # verdicts the gated fibers finally received -- the only evidence that a
  # decision reached the agent rather than merely the journal.
  #
  # `with_timeout` bounds the whole thing, so a view that resolves nothing
  # fails in words instead of hanging: under parallel_rspec a hung worker
  # reports as "fewer examples, zero failures".
  # Who a call is asked on behalf of, riding the context the gate's policy seam
  # threads -- one per call, because separating a fleet's rows is exactly
  # the claim, and a fixture that could only name them all at once could not
  # state it.
  def asked_by(requester) = Lain::Approval::PolicySwitch::Requested.new(nil, requester)

  def gated(timeout: 0.4, calls: [effect], requesters: nil,
            outstanding: Lain::Approval::Queue::Outstanding::NONE, &block)
    Sync do |task|
      queue = Lain::Approval::Queue.new(journal:, timeout:)
      asking = requesters || calls.map { "agent" }
      parked = calls.zip(asking).map do |call, requester|
        task.async { queue.adjudicate(call, asked_by(requester), outstanding:).approved? }
      end
      task.with_timeout(10) { answered(queue, parked, &block) }
    ensure
      parked&.each(&:stop)
    end
  end

  # The bounded half: every call admitted and rendered, then the example's own
  # gesture, then the verdicts the gated fibers actually received.
  def answered(queue, parked)
    spun_until { queue.count == parked.size }
    view.sweep(queue)
    outcome = yield(queue)
    { outcome:, verdicts: parked.map(&:wait) }
  end

  # A scheduler yield that is not a wall-clock wait: the parked fibers only
  # make progress when this one gives the reactor a turn. Deliberately NOT
  # named `pumped_until` -- that is a shared helper with a different signature
  # (spec/support/wait_until.rb), and shadowing it here would read as a call to
  # the shared one.
  def spun_until(limit: 5000)
    ticks = 0
    until yield
      raise "condition never held" if (ticks += 1) > limit

      Async::Task.current.sleep(0.001)
    end
  end

  # The stamp on the buffer the human is looking at.
  def generation = rpc.last[:generation]

  describe "the round trip that was never written" do
    it "resolves the parked call with the verdict pressed in the editor" do
      result = gated { |_queue| view.decide(1, "approve", generation:) }

      expect(result[:verdicts]).to eq([true])
      expect(result[:outcome]).to be_decided
    end

    it "denies when the human presses deny -- the two verdicts are not swapped" do
      result = gated { |_queue| view.decide(1, "deny", generation:) }

      expect(result[:verdicts]).to eq([false])
      expect(decisions.map { |record| record.fetch("verdict") }).to eq(["deny"])
    end

    it "signs its decision with its own surface, so a transcript never reads it as the terminal's" do
      gated { |_queue| view.decide(1, "approve", generation:) }

      expect(decisions.map { |record| record.fetch("surface") }).to eq([described_class::SURFACE])
      expect(described_class::SURFACE).not_to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
    end

    it "answers the row the cursor is on, not the first one" do
      result = gated(calls: [effect("bash", { "command" => "one" }, "tu_1"),
                             effect("write", { "path" => "two" }, "tu_2")]) do |_queue|
        view.decide(2, "approve", generation:)
      end

      expect(result[:verdicts][1]).to be(true)
      expect(decisions.first).to include("tool" => "write", "verdict" => "approve",
                                         "surface" => described_class::SURFACE)
    end
  end

  describe "first answer wins, and the loser changes nothing" do
    it "leaves the terminal's answer standing when the terminal got there first" do
      result = gated do |queue|
        queue.first.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        view.decide(1, "deny", generation:)
      end

      expect(result[:verdicts]).to eq([true])
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Frontend::ApprovalPolicy::SURFACE])
    end

    it "names the surface that beat it and the verdict it gave, so the refusal is not a mystery" do
      result = gated do |queue|
        queue.first.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        view.decide(1, "deny", generation:)
      end

      expect(result[:outcome].report).to include(Lain::Frontend::ApprovalPolicy::SURFACE, "approve")
    end

    it "refuses its OWN second answer: one row cannot be answered twice" do
      result = gated do |_queue|
        [view.decide(1, "approve", generation:), view.decide(1, "deny", generation:)]
      end

      expect(result[:outcome].map(&:decided?)).to eq([true, false])
      expect(result[:verdicts]).to eq([true])
      expect(decisions.size).to eq(1)
    end
  end

  describe "the timeout is real and fails closed" do
    let(:window) { 0.1 }

    it "never resolves a pending the clock already denied" do
      result = gated(timeout: 0.05) do |queue|
        spun_until { queue.first.nil? || queue.first.decided? }
        view.decide(1, "approve", generation:)
      end

      expect(result[:verdicts]).to eq([false])
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Approval::Queue::TIMEOUT_SURFACE])
    end

    # THE MUTATION THAT SURVIVED EVERYTHING ELSE, and the narrow window it
    # lives in. The example below waits for the queue to be EMPTY, which a view
    # that rendered every parked call -- decided or not -- passes unchanged.
    #
    # A pending is DECIDED before it LEAVES: `Approval::Queue#settle` removes it
    # in an ensure that runs on the gated fiber, so between the answer and that
    # fiber's next turn the queue still lists a call nobody can answer any more.
    # Rendering it is a row that looks live and can only refuse. The
    # `queue.count` assertion is the precondition: without it this example goes
    # vacuous the moment the removal stops being deferred.
    it "drops a row the instant it is answered, before its parked fiber has even woken" do
      gated(timeout: window) do |queue|
        queue.first.approve(surface: "elsewhere")

        expect(queue.count).to eq(1)
        expect(queue.first).to be_decided
        view.sweep(queue)
        expect(rpc.last[:rows]).to eq(0)
      end

      expect(rpc.last[:lines]).to eq(described_class::EMPTY)
    end

    it "drops the expired row from the next rendering rather than leaving it answerable" do
      gated(timeout: 0.05) do |queue|
        expect(rpc.last[:rows]).to eq(1)
        spun_until { queue.none? }
        view.sweep(queue)
      end

      expect(rpc.last[:rows]).to eq(0)
      expect(rpc.last[:lines]).to eq(described_class::EMPTY)
    end

    # The poll interval is 60 seconds here on purpose: only the watch's OWN
    # teardown sweep can clear the row in that window, so an implementation
    # that merely polls -- and leaves a stale row when the ask's surfaces are
    # stopped -- fails this and passes nothing else differently.
    it "re-renders when its watch stops, so a torn-down ask leaves no row claiming to be answerable" do
      unpolled = described_class.new(rpc:, poll_interval: 60)

      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 30)
        parked = task.async { queue.call(effect, nil) }
        watcher = task.async { unpolled.watch(queue) }
        task.with_timeout(10) do
          spun_until { rpc.last && rpc.last[:rows] == 1 }
          parked.stop
          spun_until { queue.none? }
          expect(rpc.last[:rows]).to eq(1)
          watcher.stop
          spun_until { rpc.last[:rows].zero? }
        end
      end
    end
  end

  describe "a gesture is resolved against the rendering the human is looking at" do
    it "refuses a rendering it no longer holds rather than guessing" do
      result = gated { |_queue| view.decide(1, "approve", generation: generation + 10_000) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:outcome].report).to include(described_class::BUFFER)
      expect(result[:verdicts]).to eq([false])
    end

    it "refuses a line that names no row" do
      result = gated do |_queue|
        [view.decide(0, "approve", generation:), view.decide(9, "approve", generation:)]
      end

      expect(result[:outcome].map(&:decided?)).to eq([false, false])
      expect(result[:verdicts]).to eq([false])
    end

    it "refuses an unknown verdict rather than letting anything fall toward approve" do
      result = gated { |_queue| view.decide(1, "yes", generation:) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:outcome].report).to include("approve", "deny", '"yes"')
      expect(result[:verdicts]).to eq([false])
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Approval::Queue::TIMEOUT_SURFACE])
    end

    it "resolves an OLD rendering's row to the call that rendering drew, never to its neighbour" do
      result = gated(calls: [effect("bash", { "command" => "one" }, "tu_1"),
                             effect("write", { "path" => "two" }, "tu_2")]) do |queue|
        stale = generation
        queue.first.approve(surface: "elsewhere")
        view.sweep(queue)
        view.decide(1, "deny", generation: stale)
      end

      # Line 1 of the stale rendering was the call already answered, so the
      # gesture changes nothing -- it does NOT deny the survivor that moved up
      # into that row.
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("tool") }).to eq(%w[bash write])
      expect(decisions.first.fetch("surface")).to eq("elsewhere")
      expect(decisions.last.fetch("surface")).to eq(Lain::Approval::Queue::TIMEOUT_SURFACE)
    end
  end

  # Nothing in this block turns on WHICH way the clock finally decided, so the
  # counterfactual window is short: what is under test is what reached the
  # editor, and a parked call that outlives the example is stopped anyway.
  describe "rendering" do
    let(:window) { 0.1 }

    it "shows the tool and its input the way the terminal prompt does" do
      gated(timeout: window) { |_queue| nil }

      expect(rpc.last[:lines].first).to include("bash", { "command" => "pwd" }.inspect)
    end

    # The literal this example used to assert -- "agent" for every row --
    # was the defect, not the contract. What the row has to carry is the ACTOR,
    # so two calls parked by two actors render two distinguishable rows.
    it "names who is asking, so a fleet's rows are separable" do
      gated(timeout: window,
            calls: [effect("bash", { "command" => "one" }, "tu_1"),
                    effect("bash", { "command" => "two" }, "tu_2")],
            requesters: %w[agent researcher]) { |_queue| nil }

      expect(rpc.last[:lines].first(2))
        .to contain_exactly(a_string_starting_with("agent  "), a_string_starting_with("researcher  "))
    end

    # `y` on a row is a FULL approval signing surface "nvim", so a row that
    # said nothing about the file's secrets would let a human release them from
    # the editor having been shown no warning at all -- the terminal's warning
    # and this one are the same sentence for exactly that reason.
    describe "a pending whose approval would release sensitive regions" do
      let(:secret) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
      let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=#{secret}\n") }
      let(:outstanding) { Lain::Approval::Queue::Outstanding.new(path: "/repo/.env", regions:) }

      def row(requester: "researcher")
        gated(timeout: window, outstanding:, requesters: [requester]) { |_queue| nil }
        rpc.last[:lines].first
      end

      it "warns on the row, in the terminal prompt's own words" do
        expect(row).to include('"/repo/.env": 1 sensitive region outstanding -- ')
      end

      it "puts the warning ahead of the unbounded input, where a narrow window still shows it" do
        expect(row.index("sensitive region")).to be < row.index("bash(")
      end

      # The ACTOR leads, whichever one it is -- asserted against a requester
      # that is not the queue's default, so the example cannot pass on a row
      # that names everybody the same.
      it "still leads with the requester, so a fleet's rows stay separable" do
        expect(row).to start_with("researcher  ")
        expect(row(requester: "agent")).to start_with("agent  ")
      end

      it "puts none of the regions' bytes in the editor" do
        expect(row).not_to include(secret)
      end

      it "leaves an ordinary row exactly as it was, bar the actor it now names" do
        gated(timeout: window, requesters: %w[researcher]) { |_queue| nil }

        expect(rpc.last[:lines].first).to eq("researcher  bash(#{{ "command" => "pwd" }.inspect})")
      end
    end

    it "stamps how many leading lines are rows, so the editor's keys are inert on the rest" do
      gated(timeout: window) { |_queue| nil }

      expect(rpc.last[:rows]).to eq(1)
      expect(rpc.last[:lines].size).to be > 1
      expect(rpc.last[:lines].last).to include("LainApprove", "LainDeny")
    end

    it "OBSERVES the queue and never drains it, so the terminal surface still sees the pending" do
      taken = gated(timeout: window) { |queue| Async::Task.current.with_timeout(2) { queue.dequeue } }

      expect(taken[:outcome].tool).to eq("bash")
      expect(taken[:verdicts]).to eq([false])
    end

    it "posts once per CHANGE, not once per poll" do
      gated(timeout: window) do |queue|
        3.times { view.sweep(queue) }
        expect(rpc.posts.size).to eq(1)
      end
    end

    it "keeps retrying while the editor refuses the post, so a full queue is not a lost rendering" do
      rpc.refusal = described_class::DETACHED

      gated(timeout: window) do |queue|
        view.sweep(queue)
        expect(rpc.posts.size).to eq(2)
        rpc.refusal = nil
        view.sweep(queue)
        view.sweep(queue)
        expect(rpc.posts.size).to eq(3)
      end
    end

    it "hands out no rendering the editor refused, so a gesture citing one is refused too" do
      rpc.refusal = described_class::DETACHED

      result = gated(timeout: window) { |_queue| view.decide(1, "approve", generation: rpc.last[:generation]) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:verdicts]).to eq([false])
    end
  end

  # An approval's command is UNBOUNDED, and one `input.inspect` line is how
  # a human ends up approving a command they never read: past the right edge of
  # a narrow window there is nothing to scroll to, because the row IS the
  # buffer line. So an item is a RECORD now -- a summary line the list stays
  # quiet with, and the call in full underneath it, foldable like every other
  # lain record.
  #
  # WHICH BREAKS POSITION ADDRESSING IN TWO PLACES AT ONCE, and both are pinned
  # here. Ruby resolved a keypress as `rendering[line - 1]`, which answers the
  # NEIGHBOUR the moment an item spans two lines; and the editor's own inert
  # test (`line <= b:lain_approval_rows`) would make every continuation line a
  # keypress about nothing. The rendering now carries a line -> call map, and
  # `rows` counts answerable LINES -- which is what protocol 12's history entry
  # already says it counts ("how many of its leading lines are answerable
  # calls"), so the stamp's MEANING is unchanged and only its value stopped
  # assuming one line per call.
  describe "an item longer than one line" do
    let(:window) { 0.15 }

    # Comfortably past {Lain::Frontend::Neovim::ApprovalView::WIDTH} without
    # being a wall of text in a failure message.
    let(:long_command) { "git log --oneline --graph --decorate --all #{"--author=someone " * 12}" }

    def long_call(id) = effect("bash", { "command" => "#{long_command}#{id}" }, id)

    def three_long_calls = %w[tu_1 tu_2 tu_3].map { |id| long_call(id) }

    # The item starting on `line`, read back the way the runtime's fold reads
    # it: the summary, then every line carrying the continuation indent.
    def item_at(line)
      lines = rpc.last[:lines]
      [lines[line - 1]] + lines.drop(line).take_while { |text| text.start_with?(described_class::INDENT) }
    end

    # Wrapped lines put back together: the indent off, the pieces joined with
    # nothing, because the wrap is a hard cut at a column and adds no bytes.
    def reassembled(lines) = lines.map { |line| line.delete_prefix(described_class::INDENT) }.join

    # The 1-based buffer line each item starts on, taken from what the editor
    # was actually GIVEN rather than computed from the fixture -- an off-by-one
    # in the drawing is exactly what these examples are here to catch.
    def item_starts
      lines = rpc.last[:lines]
      (1..rpc.last[:rows]).reject { |line| lines[line - 1].start_with?(described_class::INDENT) }
    end

    it "summarises on the item's first line and carries the whole command in the rest" do
      gated(timeout: window, calls: [long_call("tu_1")]) { |_queue| nil }

      item = item_at(1)
      expect(item.size).to be > 1
      expect(item.first.length).to be <= described_class::WIDTH
      expect(item.first).not_to include(long_command)
      expect(reassembled(item.drop(1))).to include(long_command)
    end

    it "gives each parked call exactly one summary line, whatever its command's length" do
      gated(timeout: window, calls: three_long_calls) { |_queue| nil }

      expect(item_starts.size).to eq(3)
      expect(item_starts.map { |line| item_at(line).first }).to all(start_with("agent  "))
    end

    # What a CLOSED fold leaves on screen is the summary line and nothing else
    # (`10_folds.lua`'s foldtext), so the summary alone has to say who is asking
    # and what would be released -- otherwise collapsing the list hides the very
    # facts a `y` is about.
    it "leaves a self-sufficient line behind when the item is collapsed onto its summary" do
      gated(timeout: window, calls: [long_call("tu_1")]) { |_queue| nil }

      expect(item_at(1).first).to start_with("agent  ").and include("bash(")
    end

    it "counts answerable LINES in the stamp, so the keys are inert only past the list" do
      gated(timeout: window, calls: three_long_calls) { |_queue| nil }

      expect(rpc.last[:rows]).to eq(item_starts.sum { |line| item_at(line).size })
      expect(rpc.last[:lines][rpc.last[:rows]]).to eq("")
      expect(rpc.last[:lines].last).to include("LainApprove", "LainDeny")
    end

    # {Lain::Frontend::Neovim::ApprovalView::Rendering}'s own property, pinned
    # at the layer it lives at rather than only through a live editor: `calls`
    # is one entry per PARKED CALL, not one per row, so a single item wrapping
    # into several rows still gets exactly one. `call_index` is `rows`-shaped
    # and every one of its entries names that same, only member.
    it "carries one calls entry per parked call, and every row of a wrapped item resolves to it" do
      gated(timeout: window, calls: [long_call("tu_1")]) { |_queue| nil }

      expect(rpc.last[:calls].size).to eq(1)
      expect(rpc.last[:calls].first).to include(long_command)
      expect(rpc.last[:call_index].size).to eq(rpc.last[:rows])
      expect(rpc.last[:call_index].uniq).to eq([1])
    end

    # Three items, three `calls` entries, and `call_index` a CONSECUTIVE run
    # per item -- built from the SAME walk that draws `item_starts`, so a row
    # answering the wrong call here would be the identical defect the
    # cursor-resolution examples above already guard, seen from the wire
    # payload's own shape instead of a decided verdict.
    it "keeps call_index's runs lined up with which of three parked calls each row belongs to" do
      gated(timeout: window, calls: three_long_calls) { |_queue| nil }

      expect(rpc.last[:calls].size).to eq(3)
      item_starts.each_with_index do |start, position|
        run = rpc.last[:call_index][start - 1, item_at(start).size]
        expect(run.uniq).to eq([position + 1])
      end
    end

    it "answers the item the summary line belongs to, never its neighbour" do
      result = gated(timeout: window, calls: three_long_calls) do |_queue|
        view.decide(item_starts.last, "approve", generation:)
      end

      expect(result[:verdicts]).to eq([false, false, true])
      expect(decisions.first).to include("tool" => "bash", "verdict" => "approve",
                                         "surface" => described_class::SURFACE)
    end

    it "answers that same item from a CONTINUATION line, and is never inert on one" do
      result = gated(timeout: window, calls: three_long_calls) do |_queue|
        view.decide(item_starts.last + 1, "approve", generation:)
      end

      expect(result[:outcome]).to be_decided
      expect(result[:verdicts]).to eq([false, false, true])
    end

    # The line BETWEEN two items is the second one's summary, not the first
    # one's tail: an item owns its own lines and no more.
    it "stops an item at its own last line, so the next summary answers the next call" do
      result = gated(timeout: window, calls: three_long_calls) do |_queue|
        [view.decide(item_starts[0], "deny", generation:), view.decide(item_starts[1], "approve", generation:)]
      end

      expect(result[:verdicts]).to eq([false, true, false])
    end

    # THE CUT MUST NOT EAT THE WARNING, and this is the one way the record
    # rendering could have made the surface WORSE than it found it. The row used
    # to be one unwrapped line, so {Approval::Queue::Outstanding#preamble}'s
    # sentence was always in the buffer somewhere; an elided summary whose body
    # carried only the CALL puts a long enough path's warning nowhere at all.
    # `y` here is a full approval signing surface "nvim", and this is the
    # surface whose whole premise is that a human reads what they approve -- so
    # the item carries the WHOLE row, and the summary is a cut prefix OF it
    # rather than a separate sentence that can lose a clause the body never had.
    describe "a cut that lands inside the sensitive-region warning" do
      # Deep enough that `requester + preamble` alone overruns WIDTH, so the
      # elision falls INSIDE the warning rather than after it -- which is the
      # only arrangement that can lose the sentence.
      let(:deep_path) { "/#{"vendor/" * 11}.env" }
      let(:secrets) { (1..4).map { |n| "KEY_#{n}=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE#{n}\n" }.join }
      let(:outstanding) do
        Lain::Approval::Queue::Outstanding.new(path: deep_path,
                                               regions: Lain::Sensitivity::Regions.detect(secrets))
      end

      def cut_item
        gated(timeout: window, outstanding:, calls: [effect]) { |_queue| nil }
        item_at(1)
      end

      it "cuts inside the warning -- the arrangement the rest of this block is about" do
        expect(cut_item.first).to end_with(described_class::ELISION)
        expect(cut_item.first).not_to include("outstanding")
      end

      # Read back the way a human reads a wrapped paragraph -- indent stripped,
      # lines rejoined -- rather than line by line. The body is HARD-wrapped
      # (see {ApprovalView::BODY}: a command's spaces are load-bearing, so a
      # word-boundary wrap is not available here), so the sentence legitimately
      # straddles a line break. A break is display; a missing clause is loss,
      # and only the second is what this block is about.
      it "still puts the whole warning in the item, where a human about to press y can read it" do
        expect(reassembled(cut_item)).to include("4 sensitive regions outstanding")
      end

      it "carries the WHOLE row below the summary, warning and call alike" do
        item = cut_item
        whole = reassembled(item.drop(1))

        expect(whole).to include(outstanding.preamble).and include("bash(")
        expect(whole).to start_with(item.first.delete_suffix(described_class::ELISION))
      end

      it "puts none of the regions' bytes in the editor, however it wrapped them" do
        expect(cut_item.join).not_to include("sk-ant-api03")
      end
    end

    # {Fold::INDENT} is what `05_records.lua`'s CONTINUATION is pinned against
    # -- see `fold_spec.rb`, the ONE place that reads the Lua source. Reading
    # it again here would be a second pin to the same fact rather than a
    # second fact, so this only checks that this view draws by that same
    # constant and not a spelling of its own.
    describe "the indent this view marks continuations with" do
      it "is Fold's, not a spelling of its own" do
        expect(described_class::INDENT).to equal(Lain::Frontend::Neovim::Fold::INDENT)
      end
    end
  end

  # The width bar, on this view's OWN sentences. Every refusal here comes back
  # as a {Decided#report} and is echoed by {Lain::CLI::HumanReplies::Gestures}
  # through `review_refused`, which is one `nvim_echo` into the MESSAGE AREA --
  # `&columns` wide over `&cmdheight` lines, never the window a cockpit split
  # narrows ({Lain::Review::Surface::Neovim::MARKED}'s measurement). A sentence
  # that does not fit one line raises `Press ENTER or type command to continue`,
  # which blocks RPC on the very gesture it is refusing.
  #
  # MEASURED RENDERED, NEVER AS THE TEMPLATE, which is the trap this block
  # exists to avoid: `%<verdicts>s` expands to "approve/deny" and
  # `%<generation>s` to digits, so a bar checked against the format string
  # measures something a good deal shorter than what the editor receives.
  #
  # The substitutions are driven through {ApprovalView#decide} at the WIDE end
  # of what each really carries -- a six-digit stamp, a four-digit line, the
  # longest surface name in `lib/` ("secret_oracle") -- so the bar holds for
  # hour six of a session rather than only for its first rendering.
  #
  # Each example also pins the REMEDY clause, deliberately: the cheap way to
  # pass a width bar is to delete the half of the sentence that says what to do
  # next, and a refusal that names a condition without its remedy is the loop
  # this rail exists to break.
  describe "the refusals this view puts on the message rail" do
    # The rail's own prefix, added by `65_review.lua` before the echo, so the
    # bar is measured against what nvim actually renders.
    let(:prefix) { "lain: " }

    # Comfortably inside the cockpit nvim pane's 110-column message area, and
    # inside an ordinary 80-column terminal too -- the same narrow-safe choice
    # `Review::Surface::Neovim`'s own `< 60` and `< 40` pins already make.
    let(:bar) { 80 }

    let(:window) { 0.1 }

    def refusal_for(&block) = gated(timeout: window, &block)[:outcome].report

    def width_of(report) = (prefix + report).length

    it "keeps the stale-rendering refusal inside the message area, six-digit stamp and all" do
      report = refusal_for { |_queue| view.decide(1, "approve", generation: 123_456) }

      expect(width_of(report)).to be <= bar
      expect(report).to include(described_class::BUFFER, "press again")
    end

    it "keeps the no-such-row refusal inside the message area, four-digit line and all" do
      report = refusal_for { |_queue| view.decide(1234, "approve", generation:) }

      expect(width_of(report)).to be <= bar
      expect(report).to include(described_class::BUFFER, "1234")
    end

    it "keeps the unknown-verdict refusal inside the message area, both verdicts named" do
      report = refusal_for { |_queue| view.decide(1, "yes", generation:) }

      expect(width_of(report)).to be <= bar
      expect(report).to include('"yes"', "approve/deny")
    end

    it "keeps the lost-the-race refusal inside the message area, longest surface name and all" do
      report = refusal_for do |queue|
        queue.first.approve(surface: "secret_oracle")
        view.decide(1, "deny", generation:)
      end

      expect(width_of(report)).to be <= bar
      expect(report).to include("secret_oracle", "approved", "stands")
    end
  end

  # The buffer a gated agent is waiting on was the one lain:// surface that
  # did not exist until the first pending, so a human looking for it at rest
  # found nothing -- and `:buffer lain://approval` answered `E94`.
  describe "#prime" do
    it "posts the at-rest projection, so the buffer exists before anything is parked" do
      view.prime

      expect(rpc.last[:lines]).to eq(described_class::EMPTY)
    end

    # `runtime/62_approval.lua`'s `if rows > 0` guard is the whole reason this
    # is safe to do at attach: zero rows creates the buffer and opens no window.
    it "carries no rows, so the runtime creates the buffer and takes no window" do
      view.prime

      expect(rpc.last[:rows]).to eq(0)
    end

    # The empty rendering's OTHER two members, so a nil creeping into either
    # crosses the wire silently: an unparked list has no calls to publish and
    # nothing for its (also empty) call_index to point into.
    it "carries no calls or call_index either, agreeing with the empty row count" do
      view.prime

      expect(rpc.last[:calls]).to eq([])
      expect(rpc.last[:call_index]).to eq([])
    end

    # The escalation trigger this card was given, pinned so it cannot rot: the
    # `@shown = nil` in {#initialize} is what makes the FIRST sweep render even
    # an empty queue, and a prime that recorded the empty list as "what the
    # screen shows" would make that sweep skip -- putting the surface back to
    # being one a session only ever gets by being gated.
    it "leaves the first sweep still rendering, even of a queue with nothing in it" do
      view.prime

      Sync do
        queue = Lain::Approval::Queue.new(journal:, timeout: 0.1)
        view.sweep(queue)
      end

      expect(rpc.posts.size).to eq(2)
    end

    # The stamp is handed out only for lines the editor TOOK ({#render}'s rule),
    # and the prime is no exception -- so a gesture citing a rendering nothing
    # ever wrote is still refused.
    it "hands out no stamp when the editor refuses the primed post" do
      rpc.refusal = described_class::DETACHED
      view.prime

      expect(view.decide(1, "approve", generation: rpc.last[:generation])).not_to be_decided
    end
  end

  # THE FOLD HALF IS NOT ASSERTABLE FROM HERE, and a review found that out the
  # expensive way: two of this card's acceptance criteria -- "the items are
  # closed by default" and "only its summary line remains visible" -- were
  # covered by examples that grepped the runtime SOURCE for a registration.
  # Mutating `spanning_record` to `return true` makes every line its own record,
  # so nothing folds and three approvals are a wall of text; the whole committed
  # suite stayed green through it. A fold is a property of a WINDOW in a running
  # editor, and only a running editor can be asked.
  #
  # :seam, at the mirror path, because that is what a seam with an obvious
  # subject does (spec/support/tags.rb): two real components -- this view and
  # the injected lua runtime -- with no double between them, over a real
  # headless nvim. :nvim as well, so a machine without the binary EXCLUDES it
  # rather than dying in the spawn (that tag's own note: the guard has to be a
  # filter, never a per-example skip).
  describe "the fold surface, in a real editor", :nvim, :seam do
    # A socket this example NAMED. Never a glob, never one found on disk: a
    # sibling agent on this chunk attached to a stranger's editor that way, and
    # the failure mode is driving somebody else's session.
    around do |example|
      socket = File.join(Dir.tmpdir, "lain-t9-approval-fold-#{Process.pid}-#{rand(1_000_000)}.sock")
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
      Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
      @socket = socket
      example.run
    ensure
      @inspector = nil
      kill_editor(pid)
      FileUtils.rm_f(socket)
    end

    # By PID, the one this block spawned. `pkill -f nvim` would match a human's
    # own cockpit -- and this shell's argv besides.
    def kill_editor(pid)
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # A THIRD connection, so observing never disturbs the frontend's own.
    def inspector = @inspector ||= Neovim.attach_unix(@socket)

    def buffer_lines
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local buf = vim.fn.bufnr(...)
        if buf == -1 then return {} end
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      LUA
    end

    # `foldclosed()` per line, read INSIDE the window holding the buffer: folds
    # are a window fact, and nvim_buf_call's temporary window carries none of
    # the window-local fold options at all. -1 means "not in a closed fold";
    # any other value is the line the closed fold containing it STARTS on, so a
    # run of the same number is one item collapsed onto that line.
    def fold_state
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local buf = vim.fn.bufnr(...)
        local win = vim.fn.win_findbuf(buf)[1]
        if win == nil then return { "no window showing the buffer" } end
        return vim.api.nvim_win_call(win, function()
          return vim.tbl_map(vim.fn.foldclosed, vim.fn.range(1, vim.fn.line("$")))
        end)
      LUA
    end

    let(:long_command) { "git log --oneline --graph --decorate --all #{"--author=someone " * 12}" }

    # A call that fits inside {ApprovalView::WIDTH}, so a two-item fixture has
    # one item that is unambiguously ONE row -- which is what lets an example
    # name the second item's fold by a line number rather than by a range.
    let(:short_command) { "pwd" }

    # Parked calls, rendered through the REAL frontend into the REAL editor:
    # the view is the frontend's own, so the post takes the RpcThread and the
    # runtime's set_approval, exactly as a gated session does. The optional
    # block runs against the live editor once the rendering has landed, and
    # whatever it returns is merged into the reading -- which is how an example
    # observes a fold BEFORE its own gesture as well as after.
    #
    # THE REACTOR RUNS ON ITS OWN THREAD, and that is not tidiness -- it is the
    # arrangement buffers_spec already uses, for a reason this block rediscovered
    # by hanging for five seconds. The inspector's msgpack round trips are
    # blocking IO; driven from INSIDE the Sync that holds the parked fiber they
    # deadlock the two against each other. The editor is read from the example's
    # own thread, and the queue lives on the worker's.
    def rendered_fold_state(commands: [long_command], &probe)
      @release = Thread::Queue.new
      screen = nil
      frontend = Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: @socket)
      # `Neovim#run` answers its own teardown, never the block's value, so the
      # reading is carried out rather than returned.
      frontend.run { |handle| screen = read_screen(handle, commands, &probe) }
      screen
    end

    # The hint line is the rendering's LAST, and the at-rest projection's is
    # not -- so waiting on it waits for the sweep rather than for the prime,
    # which lands first and would otherwise satisfy a line-count wait.
    def read_screen(handle, commands)
      worker = Thread.new { park_and_sweep(handle, commands) }
      waited_for { buffer_lines.last == described_class::HINT }
      probed = block_given? ? yield : {}
      { lines: buffer_lines, folds: fold_state }.merge(probed)
    ensure
      @release.push(:done)
      raise "the parked approval's thread never stopped" unless worker&.join(20)
    end

    def park_and_sweep(handle, commands)
      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 60)
        parked = commands.each_with_index.map do |command, index|
          task.async { queue.call(effect("bash", { "command" => command }, "tu_#{index}"), nil) }
        end
        task.with_timeout(20) { swept(handle, queue, commands.size) }
      ensure
        parked&.each(&:stop)
      end
    end

    def swept(handle, queue, count)
      spun_until { queue.count == count }
      handle.approval_view.sweep(queue)
      spun_until { !@release.empty? }
    end

    # Wall clock, because this one waits on the RPC thread rather than on a
    # fiber -- {#spun_until}'s scheduler yield would never let it make progress.
    def waited_for(timeout: 10)
      deadline = Time.now + timeout
      until yield
        raise "the editor never showed the rendering" if Time.now > deadline

        sleep 0.02
      end
    end

    # The same drive taken one step further: the parked call is ANSWERED and
    # the view re-rendered, so an example can read what the editor did with a
    # list that went empty. The optional block runs while the call is still
    # parked, which is where a human's own split has to happen for it to be a
    # window lain did not open.
    def surface_after_emptying(&setup)
      @release = Thread::Queue.new
      @empty = Thread::Queue.new
      surface = nil
      frontend = Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: @socket)
      frontend.run { |handle| surface = read_windows(handle, &setup) }
      surface
    end

    def read_windows(handle)
      worker = Thread.new { park_answer_and_sweep(handle) }
      observed_windows { yield if block_given? }
    ensure
      @release.push(:done)
      raise "the parked approval's thread never stopped" unless worker&.join(20)
    end

    # Both readings, either side of the queue emptying: the block is the
    # example's own chance to act on the editor while a call is still parked.
    def observed_windows
      waited_for { buffer_lines.last == described_class::HINT }
      parked = windows_showing
      taken = yield
      @empty.push(:now)
      waited_for { buffer_lines == described_class::EMPTY }
      { parked:, taken:, emptied: windows_showing }
    end

    def park_answer_and_sweep(handle)
      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 60)
        parked = task.async { queue.call(effect("bash", { "command" => long_command }, "tu_1"), nil) }
        task.with_timeout(20) { emptied(handle, queue) }
      ensure
        parked&.stop
      end
    end

    # Answered through the QUEUE rather than through a keypress: what is under
    # test is what the editor does when a list goes empty, and a decision made
    # anywhere -- the terminal, the clock, another surface -- empties it the
    # same way.
    def emptied(handle, queue)
      spun_until { queue.one? }
      handle.approval_view.sweep(queue)
      spun_until { !@empty.empty? }
      queue.first.approve(surface: described_class::SURFACE)
      handle.approval_view.sweep(queue)
      spun_until { !@release.empty? }
    end

    # How many windows show the buffer, how many of those lain opened for
    # itself, and how many TABPAGES the editor still has. `w:lain_approval_opened`
    # is the runtime's own mark, so a window answering false here is one lain
    # must leave alone; the tab count is what catches a close that took a whole
    # tabpage with it.
    def windows_showing
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local buf = vim.fn.bufnr(...)
        local wins = buf == -1 and {} or vim.fn.win_findbuf(buf)
        local opened = 0
        for _, win in ipairs(wins) do
          if vim.w[win].lain_approval_opened then opened = opened + 1 end
        end
        return { showing = #wins, opened = opened, tabs = #vim.api.nvim_list_tabpages() }
      LUA
    end

    # A window the HUMAN made, in the one way a human most easily makes one:
    # splitting the window lain already opened. `:vsplit` copies window OPTIONS
    # and not window VARIABLES (`10_folds.lua`'s probe J), which is the whole
    # reason the mark is a variable -- so this window carries none of lain's.
    def human_split
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local buf = vim.fn.bufnr(...)
        vim.api.nvim_win_call(vim.fn.win_findbuf(buf)[1], function() vim.cmd("vsplit") end)
        return #vim.fn.win_findbuf(buf)
      LUA
    end

    # lain's window ALONE in its own tabpage, with another tabpage open beside
    # it -- the arrangement that separates "the last window there is" from "the
    # last window in this tab". `:only` is how a human gets there.
    def alone_in_its_tab
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local buf = vim.fn.bufnr(...)
        local win = vim.fn.win_findbuf(buf)[1]
        vim.cmd("tabnew")
        vim.api.nvim_set_current_win(win)
        vim.cmd("only")
        return #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
      LUA
    end

    # A window lain opened that the human has since made their own: they send it
    # to another buffer and later bring the list back into it themselves. The
    # window is the same one; whose it is has changed. Answers whether lain still
    # claims it.
    def human_reclaims_window
      inspector.exec_lua(<<~LUA, [described_class::BUFFER])
        local name = ...
        local win = vim.fn.win_findbuf(vim.fn.bufnr(name))[1]
        vim.api.nvim_win_call(win, function()
          vim.cmd("enew")
          vim.cmd("buffer " .. name)
        end)
        return vim.w[win].lain_approval_opened == true
      LUA
    end

    # What nvim would DISPLAY for the closed fold at `line`: 'foldtext'
    # evaluated in the window that holds the fold, which is the only place
    # `v:foldstart` is set. A buffer read cannot see this -- a blank line reads
    # blank either way; what differs is whether nvim has room LEFT OVER to fill
    # with the 'fold' fillchar, which is what draws the bar.
    def fold_display(line)
      inspector.exec_lua(<<~LUA, [described_class::BUFFER, line])
        local name, line = ...
        local buf = vim.fn.bufnr(name)
        local win = vim.fn.win_findbuf(buf)[1]
        return vim.api.nvim_win_call(win, function()
          return { text = vim.fn.foldtextresult(line), width = vim.api.nvim_win_get_width(win) }
        end)
      LUA
    end

    # `foldtext()`'s general statement (10_folds.lua:208-217) padding
    # every closed fold, not only a blank one, needs a fold whose closed
    # summary is SHORTER than the window -- and lain://approval's own WIDTH
    # (96) always cuts a wrapped summary past this harness's 80-column
    # default, so going through the real view can never show the gap the fix
    # closes. A throwaway window with a hand-built manual fold measures
    # `foldtext()` directly, the same function every record-shaped view
    # shares, with content this example controls.
    #
    # THIS SETS `foldtext` ITSELF, so it deliberately bypasses
    # `10_folds.lua`'s own INSTALLATION of that option (`install_folds`, the
    # `BufWinEnter` autocmd) -- a break there would still read green through
    # this helper. That wiring is what `fold_display` and the pre-existing
    # blank-trailer example already drive, against the real `ApprovalView`
    # window; this helper is narrower on purpose, for the width reason above.
    def manual_fold_display(lines)
      inspector.exec_lua(<<~LUA, [lines])
        local lines = ...
        vim.cmd("botright new")
        local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        vim.bo[buf].buftype = "nofile"
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.wo[win].foldmethod, vim.wo[win].foldtext = "manual", "v:lua.__lain.foldtext()"
        vim.cmd(("1,%dfold"):format(#lines))
        return { text = vim.fn.foldtextresult(1), width = vim.api.nvim_win_get_width(win) }
      LUA
    end

    # `zo` on a row, from the window that holds the buffer, answering the row's
    # fold state afterwards.
    def open_fold_at(line)
      inspector.exec_lua(<<~LUA, [described_class::BUFFER, line])
        local name, line = ...
        local buf = vim.fn.bufnr(name)
        local win = vim.fn.win_findbuf(buf)[1]
        return vim.api.nvim_win_call(win, function()
          vim.api.nvim_win_set_cursor(win, { line, 0 })
          vim.cmd("silent! foldopen!")
          return vim.fn.foldclosed(line)
        end)
      LUA
    end

    # The item's lines, put back together the way the drawing side cut them
    # apart -- {ApprovalView#body_for}'s indent removed, nothing else.
    def reassembled(lines) = lines.map { |line| line.delete_prefix(described_class::INDENT) }.join

    def item_rows(lines) = lines.take_while { |line| !line.empty? }

    # lain://approval is a FORM, not a log: the call a human is being
    # asked about is the FIRST record, and the at-rest re-open used to land on
    # the LAST line -- the key hints -- leaving the pending call folded behind
    # a summary cut at {ApprovalView::WIDTH}. A command longer than the summary
    # was then in the buffer and on no screen.
    it "shows the parked call in full at rest, with none of it folded away" do
      screen = rendered_fold_state
      item = item_rows(screen[:lines])

      expect(item.size).to be > 1
      expect(screen[:folds].first(item.size)).to all(eq(-1))
      expect(reassembled(item)).to include(long_command)
    end

    # The other half of that, and the reason the trailer must still be its OWN
    # record (`05_records.lua`'s measurement): the hints get a fold of their
    # own, so they can neither steal the at-rest open nor swallow the item
    # above them into a fold that opens with them.
    it "leaves the key hints in a fold of their own rather than letting them take the list's" do
      screen = rendered_fold_state

      expect(screen[:lines].last).to eq(described_class::HINT)
      expect(screen[:folds].last).to eq(screen[:lines].size)
      expect(screen[:folds].first).to eq(-1)
    end

    # A closed fold displays 'foldtext' and then FILLS the rest of the
    # line with the 'fold' fillchar, so a blank trailer whose foldtext is the
    # empty string renders as a full-width bar of dots -- a line the human
    # reads as damage. Measured through `foldtextresult()` rather than by
    # reading the buffer, because the buffer line is blank in both worlds.
    it "renders the blank line above the hints as blank, not as a bar of fold fill" do
      screen = rendered_fold_state { { blank: fold_display(buffer_lines.index("") + 1) } }
      blank = screen[:lines].index("") + 1

      expect(screen[:folds][blank - 1]).to eq(blank)
      expect(screen[:blank]["text"]).to match(/\A +\z/)
      expect(screen[:blank]["text"].length).to be >= screen[:blank]["width"]
    end

    # The general statement, scenario 1. The key-hint line's own
    # one-line fold is the blank trailer's defect with the special case
    # removed: non-blank text, still with nothing left over for nvim to fill,
    # so it wore a trail of fold fillchars before this fix padded every
    # closed fold rather than only the blank one.
    it "pads the key-hint line's closed fold to the window width, with no fill trailing it" do
      screen = rendered_fold_state { { hint: fold_display(buffer_lines.size) } }

      expect(screen[:lines].last).to eq(described_class::HINT)
      expect(screen[:hint]["text"]).to start_with(described_class::HINT)
      expect(screen[:hint]["text"].length).to be >= screen[:hint]["width"]
    end

    # Scenario 2. The `span > 1` branch appends "  (+N lines)" to the
    # summary and never padded at all -- invisible only because a record row
    # is open at rest today (the round's own measurement). Padding has to
    # account for the SUFFIXED line's display width, not the raw line's, or a
    # multi-line record closed by a human (`zc`, or a second parked item
    # landing behind the live one) would still trail fill past the marker.
    it "pads a closed multi-line record's summary to the window width, suffix included" do
      screen = rendered_fold_state do
        { multiline: manual_fold_display(["a short summary line", "  continuation one", "  continuation two"]) }
      end

      expect(screen[:multiline]["text"]).to match(/\Aa short summary line {2}\(\+2 lines\) *\z/)
      expect(screen[:multiline]["text"].length).to be >= screen[:multiline]["width"]
    end

    # The claim the fold surface exists at all, restated where the new at-rest
    # default leaves it observable: with two calls parked, the one that is not
    # live is closed onto its summary. The mutant that deletes the surface
    # reads -1 here (nothing folded), and one that makes every line its own
    # record cannot close a multi-line item onto line 1 at all.
    it "closes every item but the live one onto its summary" do
      screen = rendered_fold_state(commands: [long_command, short_command])
      second = item_rows(screen[:lines]).size

      expect(screen[:folds].first(second - 1)).to all(eq(-1))
      expect(screen[:folds][second - 1]).to eq(second)
    end

    # Folds are per-record, so a gesture on one row is a statement about that
    # row and nothing else -- the property that makes "open the one you are
    # about to answer" a safe instruction to give a human.
    it "leaves the other item's fold alone when one of them is opened" do
      screen = rendered_fold_state(commands: [long_command, short_command]) do
        second = item_rows(buffer_lines).size
        { second:, before: fold_state, reopened: open_fold_at(second) }
      end
      second = screen[:second]

      expect(screen[:before][second - 1]).to eq(second)
      expect(screen[:reopened]).to eq(-1)
      expect(screen[:folds].first(second - 1)).to eq(screen[:before].first(second - 1))
    end

    # The window is opened BECAUSE a call was parked (`set_approval`'s
    # `rows > 0`), so it has to go when there is nothing left to answer --
    # otherwise every session that was ever gated ends up with a pane showing
    # "(no approvals pending)" for the rest of its life. `parked` is read first
    # so this cannot pass by closing windows lain never opened.
    it "takes back the window it opened once nothing is parked" do
      surface = surface_after_emptying

      expect(surface[:parked]).to eq({ "showing" => 1, "opened" => 1, "tabs" => 1 })
      expect(surface[:emptied]["showing"]).to eq(0)
    end

    # The other side of that, and the one a mark on the WINDOW is what makes
    # possible: a human who split lain's window to keep the list in view owns
    # that window, and an emptied queue must not take it.
    it "leaves a window the human opened themselves, which carries none of lain's marks" do
      surface = surface_after_emptying { human_split }

      expect(surface[:emptied]["showing"]).to eq(1)
      expect(surface[:emptied]["opened"]).to eq(0)
    end

    # "The last window there is" and "the last window in this tab" are not the
    # same count, and closing on the first takes the human's TABPAGE with it --
    # focus lands in a tab they were not looking at, because a queue drained.
    # The empty list staying put is the documented cost of the exception.
    it "leaves its window alone rather than closing the tabpage it is the last window of" do
      surface = surface_after_emptying { alone_in_its_tab }

      expect(surface[:taken]).to eq(1)
      expect(surface[:emptied]["tabs"]).to eq(2)
      expect(surface[:emptied]["showing"]).to eq(1)
    end

    # A mark that never expires stops describing the window it is on. lain opened
    # this one, so the mark was true when it was written -- but the human has
    # since sent the window elsewhere and brought the list back into it
    # deliberately, which is the same gesture as opening it themselves.
    it "gives up its claim on a window the human has taken over and brought back" do
      surface = surface_after_emptying { human_reclaims_window }

      expect(surface[:taken]).to be(false)
      expect(surface[:emptied]["showing"]).to eq(1)
      expect(surface[:emptied]["opened"]).to eq(0)
    end
  end

  describe "the surface nobody wired" do
    it "refuses the render honestly rather than reporting one that never happened" do
      expect(described_class::Detached.set_approval([], 1, 0, [], [])).to eq(described_class::DETACHED)
    end

    it "is the DEFAULT, so an unwired view can never claim a row is on screen" do
      unwired = described_class.new

      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 0.4)
        parked = task.async { queue.call(effect, nil) }
        task.with_timeout(10) do
          spun_until { queue.one? }
          unwired.sweep(queue)
          expect(unwired.decide(1, "approve", generation: 1)).not_to be_decided
          expect(parked.wait).to be(false)
        end
      end
    end
  end
end
