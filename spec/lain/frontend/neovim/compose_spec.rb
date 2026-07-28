# frozen_string_literal: true

require "timeout"

# T15: the C-g compose round trip, Ruby end. The whole point of this object is
# the SPLIT -- #open runs on Reline's input loop and must return instantly,
# #settle runs in the caller's own loop and is where the waiting happens -- so
# every example here is really an example about which half is which.
#
# Nothing here fabricates a Reline dispatch. {Compose} is driven directly and
# {Lain::Frontend::LineEditor}'s own specs own the keypress path: a spec that
# invokes the private action method by hand proves nothing about the path that
# actually runs (it is exactly how a key-name/byte type mismatch survived a
# green suite once).
RSpec.describe Lain::Frontend::Neovim::Compose do
  # An attached editor, recording the draft and the generation it was posted
  # with. The duck's whole contract is its return: nil means the draft landed,
  # a String is the notice saying why it did not.
  let(:editor) do
    Class.new do
      attr_reader :opened

      def initialize(refusal: nil)
        @refusal = refusal
        @opened = []
      end

      def open_compose(lines, generation)
        @opened << [lines, generation]
        @refusal
      end

      def drafts = @opened.map(&:first)

      def generations = @opened.map(&:last)
    end
  end

  let(:notices) { [] }
  let(:notify) { ->(message) { notices << message } }
  let(:attached) { editor.new }

  def compose(rpc: attached, timeout: 2)
    described_class.new(rpc:, notify:, timeout:)
  end

  # The editor answers whatever generation it was handed -- what a real
  # runtime.lua does from b:lain_compose_generation.
  def answer_write(subject, lines)
    subject.wrote(lines, attached.generations.last)
  end

  def answer_abandon(subject)
    subject.abandoned(attached.generations.last)
  end

  describe "#open -- the key handler, which may never block" do
    it "posts the draft to the editor and hands the prompt its marker" do
      subject = compose

      expect(subject.open("draft text")).to eq(subject.marker)
      expect(attached.drafts).to eq([["draft text"]])
      expect(subject).to be_pending
    end

    it "posts a multi-line draft as one line per line, empty lines kept" do
      compose.open("first\n\nthird")

      expect(attached.drafts).to eq([["first", "", "third"]])
    end

    it "posts an empty draft as a single empty line, never nothing" do
      compose.open("")

      expect(attached.drafts).to eq([[""]])
    end

    # The seam hands #open the RAW buffer, backslashes present; T14's #read
    # strips them before #settle ever sees the text. Joining once at #open is
    # what keeps the posted draft, the compared marker and the kept draft one
    # string.
    it "joins continuation backslashes out of the draft before posting it" do
      subject = compose
      subject.open("first \\\nsecond")

      expect(attached.drafts).to eq([["first ", "second"]])
      expect(subject.draft).to eq("first \nsecond")
    end

    # The constraint the whole card is shaped by: this runs inside Reline's
    # keypress dispatch, where a wait has nothing left to interrupt it.
    it "returns without waiting even though no answer will ever arrive" do
      subject = compose(timeout: 30)

      expect { Timeout.timeout(2) { subject.open("draft") } }.not_to raise_error
    end
  end

  describe "#settle -- the caller's own loop, outside the input loop" do
    it "hands back the edited text when the editor wrote the buffer" do
      subject = compose
      subject.open("draft text")
      answer_write(subject, ["edited text"])

      expect(subject.settle(subject.marker)).to eq("edited text")
      expect(subject).not_to be_pending
    end

    it "joins a multi-line write into one message" do
      subject = compose
      subject.open("draft")
      answer_write(subject, %w[one two])

      expect(subject.settle(subject.marker)).to eq("one\ntwo")
    end

    it "leaves a line that is not the marker exactly as it came" do
      subject = compose
      subject.open("draft")

      expect(subject.settle("something else entirely")).to eq("something else entirely")
    end

    it "passes nil through untouched, so EOF at the prompt still ends the read" do
      expect(compose.settle(nil)).to be_nil
    end

    # What makes a caller's re-prompt loop terminate. The loop repeats only
    # when the block FIRES, so a pass-through -- EOF above all -- must never
    # fire it, or a closed stdin would spin the prompt forever. (It would have:
    # my first draft of the wiring line looped on the return value instead.)
    it "does not yield on a pass-through, so a re-prompt loop cannot spin on EOF" do
      subject = compose
      yielded = false

      expect(subject.settle(nil) { yielded = true }).to be_nil
      subject.open("draft")
      expect(subject.settle("a normal line") { yielded = true }).to eq("a normal line")
      expect(yielded).to be(false)
    end

    it "has no marker at all when nothing is composing" do
      expect(compose.marker).to be_nil
    end
  end

  # PANEL BLOCKER 1 (Linus). #settle used to answer the DRAFT on every
  # non-write path, and Repl dispatches whatever #settle returns -- so a human
  # who read their draft in the editor, decided against it and closed the
  # buffer had it sent to the model unreviewed. That is the same defect the
  # card was told to avoid in Reline's vi_histedit, arriving by another door.
  describe "abandoning the buffer sends nothing (panel PAC3)" do
    it "answers the caller's re-prompt rather than the abandoned draft" do
      subject = compose
      subject.open("half-finished thought I decided against")
      answer_abandon(subject)

      expect(subject.settle(subject.marker) { :re_prompted }).to eq(:re_prompted)
      expect(notices).to eq([described_class::ABANDONED_NOTICE])
      expect(subject).not_to be_pending
    end

    it "never answers the draft, even with no re-prompt block to fall back on" do
      subject = compose
      subject.open("half-finished thought I decided against")
      answer_abandon(subject)

      expect(subject.settle(subject.marker)).to be_nil
    end

    # The key action already replaced the prompt's buffer with the marker, so
    # by now Compose holds the only copy. Yielding it is what stops "not
    # dispatched" from quietly meaning "destroyed".
    it "hands the draft to the re-prompt, so the human's text has a reader" do
      subject = compose
      subject.open("half-finished thought I decided against")
      answer_abandon(subject)
      handed = nil

      subject.settle(subject.marker) { |draft| handed = draft }

      expect(handed).to eq("half-finished thought I decided against")
    end

    it "keeps the draft for recovery, so abandoning discards nothing" do
      subject = compose
      subject.open("half-finished thought I decided against")
      answer_abandon(subject)
      subject.settle(subject.marker) { nil }

      expect(subject.draft).to eq("half-finished thought I decided against")
    end

    it "prefers a write that landed before the unload" do
      subject = compose
      subject.open("draft text")
      answer_write(subject, ["edited text"])
      answer_abandon(subject)

      expect(subject.settle(subject.marker)).to eq("edited text")
    end
  end

  describe "no editor attached" do
    it "says composing needs an attached editor and leaves the prompt alone" do
      subject = compose(rpc: editor.new(refusal: described_class::DETACHED))

      expect(subject.open("draft text")).to be_nil
      expect(subject).not_to be_pending
      expect(notices).to eq([described_class::DETACHED])
    end

    it "is the default, so an unwired Compose never pretends to have an editor" do
      subject = described_class.new(notify:)

      expect(subject.open("draft text")).to be_nil
      expect(notices).to eq([described_class::DETACHED])
    end
  end

  # PANEL BLOCKER 1, second half: a dead editor must not send the stale draft
  # either. The bound exists so the prompt returns control, not so it invents
  # a message.
  describe "a dead editor never wedges the prompt (panel PAC3b)" do
    it "answers the caller's re-prompt with a notice once the bound expires" do
      subject = compose(timeout: 0.05)
      subject.open("draft the editor never answered for")

      expect(subject.settle(subject.marker) { :re_prompted }).to eq(:re_prompted)
      expect(notices).to eq([described_class::TIMED_OUT])
      expect(subject).not_to be_pending
    end

    it "keeps the draft for recovery rather than sending it" do
      subject = compose(timeout: 0.05)
      subject.open("draft the editor never answered for")
      subject.settle(subject.marker) { nil }

      expect(subject.draft).to eq("draft the editor never answered for")
    end

    it "hands the draft to the re-prompt here too, not only on an abandon" do
      subject = compose(timeout: 0.05)
      subject.open("draft the editor never answered for")
      handed = nil

      subject.settle(subject.marker) { |draft| handed = draft }

      expect(handed).to eq("draft the editor never answered for")
    end

    it "bounds the wait rather than blocking on it" do
      subject = compose(timeout: 0.05)
      subject.open("draft text")

      expect { Timeout.timeout(3) { subject.settle(subject.marker) } }.not_to raise_error
    end
  end

  # PANEL SHOULD-FIX 3 (Jeremy). #open armed the compose and only #await
  # disarmed it, so a human who changed their mind and typed something else
  # left it armed forever -- and a marker pasted out of their own scrollback,
  # prompts later, blocked for the full bound and answered with a stale draft.
  describe "a compose the human walked away from (panel P1d/P1e)" do
    it "disarms when the prompt returns anything but the marker" do
      subject = compose(timeout: 30)
      subject.open("the draft I abandoned")

      expect(subject.settle("never mind, different question")).to eq("never mind, different question")
      expect(subject).not_to be_pending
    end

    it "passes a stale marker pasted from scrollback straight through" do
      subject = compose(timeout: 30)
      subject.open("the draft I abandoned")
      stale = subject.marker
      subject.settle("never mind, different question")

      expect(Timeout.timeout(2) { subject.settle(stale) }).to eq(stale)
    end

    # The nonce is why: a later compose's marker is a different string, so an
    # old one can never be mistaken for the live one even while armed.
    it "gives each compose its own marker, so an old one never matches a new one" do
      subject = compose(timeout: 30)
      subject.open("draft A")
      first = subject.marker
      subject.settle("changed my mind")
      subject.open("draft B")

      expect(subject.marker).not_to eq(first)
      expect(Timeout.timeout(2) { subject.settle(first) }).to eq(first)
    end

    it "passes an embedded or doubled marker through rather than matching loosely" do
      subject = compose(timeout: 30)
      subject.open("draft")
      embedded = "look at this: #{subject.marker} weird huh"

      expect(Timeout.timeout(2) { subject.settle(embedded) }).to eq(embedded)
    end
  end

  # PANEL SHOULD-FIX 4 (Jeremy). Clearing the queue at #open was a cross-thread
  # check-then-act: the clear runs on the prompt thread, #wrote pushes from the
  # RPC thread, so a write in flight when the human pressed C-g again landed
  # after the clear and the NEW compose settled on the OLD answer.
  describe "answers are tagged with the compose they belong to (panel P3b)" do
    it "drops a late answer from an earlier compose and waits for its own" do
      subject = compose(timeout: 2)
      subject.open("draft A")
      first = attached.generations.last
      subject.settle("changed my mind")

      subject.open("draft B")
      subject.wrote(["A's TEXT"], first) # A's in-flight write lands after the clear
      answer_write(subject, ["B's text"])

      expect(Timeout.timeout(3) { subject.settle(subject.marker) }).to eq("B's text")
    end

    it "does not mistake an earlier compose's abandon for its own" do
      subject = compose(timeout: 2)
      subject.open("draft A")
      first = attached.generations.last
      subject.settle("changed my mind")

      subject.open("draft B")
      subject.abandoned(first)
      answer_write(subject, ["B's text"])

      expect(Timeout.timeout(3) { subject.settle(subject.marker) }).to eq("B's text")
    end

    it "times out rather than settling on a stale answer that never matches" do
      subject = compose(timeout: 0.1)
      subject.open("draft A")
      first = attached.generations.last
      subject.settle("changed my mind")

      subject.open("draft B")
      subject.wrote(["A's TEXT"], first)

      expect(subject.settle(subject.marker) { :re_prompted }).to eq(:re_prompted)
      expect(notices).to eq([described_class::TIMED_OUT])
    end
  end

  describe "interrupting while waiting" do
    # A thread parked in #settle, with the parking observable so the raise can
    # never land before the wait has started.
    def waiting_on(subject)
      reached = Thread::Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        reached.push(:in)
        subject.settle(subject.marker)
      end
      reached.pop
      sleep 0.05
      thread
    end

    # The join re-raises what killed the thread; these examples are about what
    # {Compose} is left holding, not about the raise itself.
    def join_interrupted(thread)
      thread.join(5)
    rescue Interrupt
      nil
    end

    # PromptBreaker raises a Break into the prompt thread from its own watcher
    # thread. #settle runs OUTSIDE Reline's input loop, on a plain blocking
    # queue pop, so the raise lands at a scheduler point and unwinds -- which
    # is the whole reason the wait lives here and not in the key handler.
    it "returns control to the caller rather than swallowing the interrupt" do
      subject = compose(timeout: 30)
      subject.open("draft text")

      waiter = waiting_on(subject)
      waiter.raise(Lain::CLI::PromptBreaker::Break.new(:INT))

      expect { waiter.join(5) }.to raise_error(Lain::CLI::PromptBreaker::Break)
    end

    it "leaves nothing composing behind, so the next prompt is a fresh one" do
      subject = compose(timeout: 30)
      subject.open("draft text")

      waiter = waiting_on(subject)
      waiter.raise(Interrupt)
      join_interrupted(waiter)

      expect(subject).not_to be_pending
    end

    # A Break DISCARDS the line editor's buffer, so the draft cannot be
    # recovered from the prompt afterwards. It is captured HERE, before the
    # wait ever starts, which is why an interrupted compose still knows what
    # the human had typed.
    it "still holds the draft it captured before the wait" do
      subject = compose(timeout: 30)
      subject.open("draft text")

      waiter = waiting_on(subject)
      waiter.raise(Lain::CLI::PromptBreaker::Break.new(:INT))
      join_interrupted(waiter)

      expect(subject.draft).to eq("draft text")
    end
  end

  describe "the seam it is registered through" do
    # The handler contract (T14): one String in, replacement text or nil out.
    # Anything else is a TypeError inside Reline's dispatch.
    it "answers the key-action seam's return contract on both paths" do
      expect(compose.open("draft")).to be_a(String)
      expect(compose(rpc: editor.new(refusal: described_class::DETACHED)).open("draft")).to be_nil
    end
  end
end
