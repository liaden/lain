# frozen_string_literal: true

require "timeout"

# T9: the Ruby half of the question round trip. The object is {Compose}'s buffer
# discipline with one half removed and one substituted -- there is no #settle,
# because nothing waits for a question, and the generation stamp is the set's
# own content digest (ruling 6) rather than a hand-rolled counter.
#
# Every example here is really an example about ONE of three things: which set a
# write is allowed to answer, that a refusal comes back as a value rather than
# an exception (the write runs inside nvim's BufWriteCmd rpcrequest, where a
# raise is what leaves the human's text on the floor), and that the answer
# leaves this object through a rail rather than through a promise.
RSpec.describe Lain::Frontend::Neovim::QuestionView do
  def option(id, label) = Lain::Question::Option.new(id:, label:)

  def question(id, body:, options: [], arity: Lain::Question::SINGLE)
    Lain::Question.new(id:, body:, options:, arity:)
  end

  let(:storage) do
    question("storage", body: "Which storage engine?",
                        options: [option("postgres", "PostgreSQL"), option("sqlite", "SQLite")])
  end

  let(:notes) { question("notes", body: "Anything else?") }
  let(:asked) { Lain::Question::Set.new(questions: [storage, notes]) }
  let(:later) { Lain::Question::Set.new(questions: [question("timing", body: "And when?")]) }

  # The attached editor, recording what it was asked to open. The duck's whole
  # contract is its return: nil means the document landed, a String is the
  # notice saying why it did not ({Lain::Frontend::Neovim::RenderInlet}'s shape).
  let(:editor) do
    Class.new do
      attr_reader :opened

      def initialize(refusal: nil)
        @refusal = refusal
        @opened = []
      end

      def open_question(lines, digest)
        @opened << [lines, digest]
        @refusal
      end

      def documents = @opened.map(&:first)
      def digests = @opened.map(&:last)
    end
  end

  let(:attached) { editor.new }
  let(:handed) { [] }
  let(:submit) { ->(digest, answers) { handed << [digest, answers] } }
  let(:notices) { [] }
  let(:notify) { ->(message) { notices << message } }

  def view(rpc: attached, **seams) = described_class.new(rpc:, submit:, notify:, **seams)

  # What the editor was handed for the set it opened last -- the human's
  # starting text, which every write below is an edit of.
  def buffer = attached.documents.last

  def tick(lines, id)
    lines.map { |line| line.start_with?("- [ ] `#{id}`") ? line.sub("- [ ] ", "- [x] ") : line }
  end

  describe "#open -- the set the buffer holds" do
    it "hands the editor the set's rendered document, stamped with its digest" do
      subject = view

      expect(subject.open(asked, "digest-a")).to be_nil
      expect(attached.documents).to eq([["## `storage` (choose one)",
                                         "Which storage engine?",
                                         "",
                                         "- [ ] `postgres` PostgreSQL",
                                         "- [ ] `sqlite` SQLite",
                                         "",
                                         "## `notes` (write your answer below)",
                                         "Anything else?"]])
      expect(attached.digests).to eq(["digest-a"])
      expect(subject).to be_open
      expect(subject.digest).to eq("digest-a")
    end

    # {Compose::DETACHED}'s shape: the object that failed is the one that knows
    # why, so the caller is handed the sentence rather than a boolean it would
    # have to invent one from.
    it "answers the editor's own notice when no editor took the document" do
      subject = view(rpc: editor.new(refusal: described_class::DETACHED))

      expect(subject.open(asked, "digest-a")).to eq(described_class::DETACHED)
      expect(subject).not_to be_open
    end

    # Ruling 2, enforced HERE rather than hoped for in the caller: the buffer
    # holds exactly one set, the one being answered. Without this the panel's
    # probe walked straight into the {RequestBuffer} clobber -- a second open
    # re-renders over a half-ticked document and the first set's answer can then
    # never be written.
    it "refuses a second set over an unanswered one, leaving the first answerable" do
      subject = view
      subject.open(asked, "digest-a")
      edits = tick(buffer, "sqlite")

      expect(subject.open(later, "digest-b")).to eq(format(described_class::OCCUPIED, "digest-a"))
      expect(attached.digests).to eq(["digest-a"])
      expect(subject.digest).to eq("digest-a")
      expect(subject.wrote(edits, "digest-a")).to be_nil
      expect(handed.size).to eq(1)
    end

    # Re-opening the SAME set is the worse half: the digest still matches, so a
    # write of the pre-render text would submit successfully against a buffer
    # the human is no longer looking at. Focusing the window is the lua half's
    # job; re-rendering is nobody's.
    it "refuses to reopen the set it is already holding" do
      subject = view
      subject.open(asked, "digest-a")

      expect(subject.open(asked, "digest-a")).to eq(described_class::ALREADY_OPEN)
      expect(attached.opened.size).to eq(1)
    end

    it "opens the next set once the one it was holding has been answered" do
      subject = view
      subject.open(asked, "digest-a")
      subject.wrote(tick(buffer, "sqlite"), "digest-a")

      expect(subject.open(later, "digest-b")).to be_nil
      expect(subject.digest).to eq("digest-b")
    end

    # The digest is the whole of a write's identity (ruling 6), so a blank one
    # would let any buffer answer any set -- and `nil == nil` is exactly how it
    # would happen. Loud, and at the door.
    it "refuses to open a set under a digest that names nothing" do
      expect { view.open(asked, nil) }.to raise_error(ArgumentError, /digest/)
      expect { view.open(asked, "  ") }.to raise_error(ArgumentError, /digest/)
      expect(attached.opened).to be_empty
    end
  end

  describe "#wrote -- the BufWriteCmd's rpcrequest, on the RPC thread" do
    it "parses the edited document and hands the answer set on exactly once" do
      subject = view
      subject.open(asked, "digest-a")

      expect(subject.wrote(tick(buffer, "sqlite"), "digest-a")).to be_nil
      expect(handed.size).to eq(1)
      digest, answers = handed.first
      expect(digest).to eq("digest-a")
      expect(answers.fetch("storage").option_ids).to eq(["sqlite"])
      expect(answers.questions).to eq(asked)
    end

    it "reads the human's indented prose back as the comment on the question it sits under" do
      subject = view
      subject.open(asked, "digest-a")
      subject.wrote([*tick(buffer, "postgres"), "  we already run one"], "digest-a")

      _, answers = handed.first
      expect(answers.fetch("notes").comment).to eq("we already run one")
    end

    it "closes the view once the answer is handed on, so a repeat write answers nothing" do
      subject = view
      subject.open(asked, "digest-a")
      subject.wrote(tick(buffer, "sqlite"), "digest-a")

      expect(subject).not_to be_open
      expect(subject.wrote(tick(buffer, "postgres"), "digest-a")).to eq(described_class::STALE)
      expect(handed.size).to eq(1)
    end

    # Ruling 6. The write cites a digest, and a digest this view is not holding
    # is DROPPED rather than reinterpreted against whatever is open now -- which
    # is the whole reason the stamp is the set's content digest.
    it "drops a write citing an earlier set and leaves the open one open" do
      subject = view
      subject.open(asked, "digest-a")
      first = buffer
      subject.wrote(tick(first, "sqlite"), "digest-a")
      subject.open(later, "digest-b")

      expect(subject.wrote(tick(first, "postgres"), "digest-a")).to eq(described_class::STALE)
      expect(handed.map(&:first)).to eq(["digest-a"])
      expect(subject.digest).to eq("digest-b")
    end

    # Unreachable today -- the rail is a queue push onto an inbox nothing ever
    # closes -- but the close still precedes the hand-off, because a rail that
    # DID raise would otherwise leave the set open and the human's retry would
    # submit a second time. That is the "exactly once" AC broken in the one
    # direction nothing else covers.
    it "closes the set before handing it on, so a raising rail cannot be retried into a second submit" do
      subject = described_class.new(rpc: attached, submit: ->(_digest, _answers) { raise "rail closed" }, notify:)
      subject.open(asked, "digest-a")

      expect { subject.wrote(tick(buffer, "sqlite"), "digest-a") }.to raise_error(RuntimeError, "rail closed")
      expect(subject).not_to be_open
    end

    it "drops a write citing no set at all" do
      subject = view
      subject.open(asked, "digest-a")

      expect(subject.wrote(buffer, nil)).to eq(described_class::STALE)
      expect(handed).to be_empty
    end
  end

  describe "#wrote -- a document the grammar refuses" do
    let(:stray) { "not indented, not an option" }
    let(:open_view) { view }

    before { open_view.open(asked, "digest-a") }

    it "answers the failure naming the offending line rather than raising past its caller" do
      failure = nil

      expect { failure = open_view.wrote([*buffer, stray], "digest-a") }.not_to raise_error
      expect(failure).to include("line 9", stray)
    end

    it "hands nothing on and leaves the set open" do
      open_view.wrote([*buffer, stray], "digest-a")

      expect(handed).to be_empty
      expect(open_view).to be_open
      expect(open_view.digest).to eq("digest-a")
    end

    # The write is refused INSIDE the rpcrequest, so nvim leaves the buffer
    # modified with the human's text in it. A re-render here would overwrite the
    # very edit they have to go fix.
    it "does not re-render over the human's text" do
      open_view.wrote([*buffer, stray], "digest-a")

      expect(attached.opened.size).to eq(1)
    end

    it "reports an edit to the rendered body as the line it cannot read" do
      edited = buffer.map { |line| line == "Which storage engine?" ? "Which storage engine, really?" : line }
      failure = open_view.wrote(edited, "digest-a")

      expect(failure).to include("line 2", "Which storage engine, really?")
      expect(handed).to be_empty
    end
  end

  describe "#abandoned -- the buffer unloaded unwritten" do
    it "hands nothing on, closes the view, and tells the human nothing was submitted" do
      subject = view
      subject.open(asked, "digest-a")
      subject.abandoned("digest-a")

      expect(handed).to be_empty
      expect(subject).not_to be_open
      expect(notices).to eq([described_class::ABANDONED_NOTICE])
    end

    # The unload that follows a successful submit names a set this view no
    # longer holds, so it must not report "nothing was submitted" over an answer
    # that was.
    it "says nothing when the abandoned set is not the open one" do
      subject = view
      subject.open(asked, "digest-a")
      subject.wrote(tick(buffer, "sqlite"), "digest-a")
      subject.abandoned("digest-a")

      expect(notices).to be_empty
    end

    it "leaves a later set open when an earlier one is abandoned" do
      subject = view
      subject.open(asked, "digest-a")
      subject.wrote(tick(buffer, "sqlite"), "digest-a")
      subject.open(later, "digest-b")
      subject.abandoned("digest-a")

      expect(subject.digest).to eq("digest-b")
      expect(subject).to be_open
    end
  end

  # The object's two threads meeting. #wrote reads the open set, parses, and
  # swaps it away; #open reads the same slot and installs into it -- so the
  # digest guard, which protects only the READ, is not the whole story. Left
  # unsynchronized, an #open landing inside a write is posted to the editor and
  # then destroyed by the write's swap: the buffer is on screen, `open?` is
  # false, every later write answers STALE and nothing tells the human.
  describe "the guard and the swap, from two threads" do
    let(:entered) { Thread::Queue.new }
    let(:released) { Thread::Queue.new }

    # Stands in for "time passes inside #wrote". In production the parse is that
    # window, and it is the slowest thing this object does.
    let(:submit) do
      lambda do |digest, answers|
        handed << [digest, answers]
        entered.push(:inside)
        released.pop
      end
    end

    it "admits no open into a write in progress, and loses neither set" do
      subject = view
      subject.open(asked, "digest-a")
      lines = tick(buffer, "sqlite")
      rpc_thread = Thread.new { subject.wrote(lines, "digest-a") }
      entered.pop
      opener = Thread.new { subject.open(later, "digest-b") }
      # Read everything BEFORE releasing the write, so a failure here can never
      # strand either thread on a queue nobody pushes to.
      held_off = opener.join(0.1).nil?
      posted_during = attached.digests.dup
      released.push(:go)

      expect(Timeout.timeout(2) { rpc_thread.value }).to be_nil
      expect(Timeout.timeout(2) { opener.value }).to be_nil
      expect(held_off).to be(true)
      expect(posted_during).to eq(["digest-a"])
      expect(handed.size).to eq(1)
      expect(subject.digest).to eq("digest-b")
    end
  end

  # T16's constraint, made mechanical. The next set has to be opened by the
  # RAIL'S CONSUMER -- the fiber that pops the hand-off queue -- and never by
  # the `submit` callable, because `submit` runs INSIDE this object's lock and
  # that lock is not reentrant. The failure is not subtle and not silent, which
  # is the point of pinning it: a caller who "chains" the next set off the
  # submit gets a ThreadError on the human's `:w`, with the answer already
  # handed on and the buffer left modified.
  describe "the advance cannot chain from inside the write" do
    let(:opened_from_submit) { [] }
    let(:submit) do
      lambda do |digest, answers|
        handed << [digest, answers]
        opened_from_submit << subject_holder.first.open(later, "digest-b")
      end
    end
    let(:subject_holder) { [] }

    it "raises rather than quietly re-entering, which is why the consumer owns the advance" do
      subject = view
      subject_holder << subject
      subject.open(asked, "digest-a")
      lines = tick(buffer, "sqlite")

      expect { subject.wrote(lines, "digest-a") }.to raise_error(ThreadError, /recursive locking/)
      expect(opened_from_submit).to be_empty
    end
  end

  # {Lain::Promise} wraps an Async::Variable and must be resolved on the reactor
  # thread; this object runs on the RPC thread. So the answer leaves here the
  # way every other editor command does -- pushed onto a rail somebody else pops
  # -- and this object never resolves anything itself.
  describe "the hand-off off the RPC thread" do
    let(:rail) { Thread::Queue.new }
    let(:submit) { ->(digest, answers) { rail.push([digest, answers, Thread.current]) } }

    it "enqueues the answer on the rail from the writing thread and never waits for a consumer" do
      subject = view
      subject.open(asked, "digest-a")
      lines = tick(buffer, "sqlite")
      rpc_thread = Thread.new { subject.wrote(lines, "digest-a") }

      expect(Timeout.timeout(2) { rpc_thread.value }).to be_nil
      expect(rail.size).to eq(1)
      digest, answers, pushed_from = rail.pop
      expect([digest, answers.fetch("storage").option_ids]).to eq(["digest-a", ["sqlite"]])
      expect(pushed_from).to eq(rpc_thread)
    end
  end
end
