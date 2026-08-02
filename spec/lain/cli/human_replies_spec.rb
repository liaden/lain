# frozen_string_literal: true

require "async"

# The editor's command rail as {Lain::CLI::HumanReplies} sees it: the same duck
# {Lain::Frontend::Neovim}'s CommandInbox satisfies -- a non-blocking pop, a
# refusal rendered back in the editor, and whether there is an editor at all --
# with BOTH directions recorded, so an example can assert the whole round trip
# rather than only the half that leaves.
#
# `pop` takes and ignores its argument for the same reason the real adapter's
# does: the caller drains a Thread::Queue non-blockingly and the duck has to
# accept that call.
class RecordingEditorRail
  def initialize(*commands)
    @commands = commands
    @refusals = []
  end

  attr_reader :refusals

  def push(command) = @commands.push(command)
  def pop(*) = @commands.shift
  def review_refused(message) = @refusals << message
  def attached? = true
end

# T13: #drain_at_prompt is the `/inbox`-at-`you>` half of this class -- the
# SAME TTY drain UX #answer_loop's read_drained_answer calls at `human>`
# (`@tty.drain_inbox`), reused rather than a second presentation, and the
# SAME @ask_human resolution (#reply) rather than a second answer path. It
# exists because the OM-6 supervisor's fleet outlives a single ask: a
# subagent can post a question through `announce` (Wiring) at ANY time, but
# only #answer_loop's fiber -- alive only DURING an ask -- drains `@questions`
# otherwise, so a question posted while the human sits idle at `you>` has no
# live watcher until this runs.
RSpec.describe Lain::CLI::HumanReplies do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                            history_path: File.join(@dir, "history"))
  end
  let(:store) { Lain::Store.new }
  let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }]) }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent:) }
  let(:questions) { Async::Queue.new }
  let(:conductor) { instance_double(Lain::CLI::Conductor) }
  let(:replies) { described_class.new(tty:, conductor:, ask_human:, questions:) }

  describe "#drain_at_prompt" do
    it "lists every queued question and resolves the live ask_human promise with one read answer" do
      Sync do
        ask_human.ask("what now?")
        questions.enqueue("what now?")
        allow(conductor).to receive(:read_reply).with(tty, "human> ").and_return("go left")

        answer = replies.drain_at_prompt

        expect(answer).to eq("go left")
        expect(output.string).to include("what now?")
        expect(ask_human.last_answer.body["answer"]).to eq("go left")
      end
    end

    it "renders the honest empty state and never reads a reply when nothing is queued" do
      allow(conductor).to receive(:read_reply)

      answer = replies.drain_at_prompt

      expect(answer).to eq("")
      expect(output.string).to include("no questions pending")
      expect(conductor).not_to have_received(:read_reply)
    end

    it "retires the answered item from the inbox list -- a second call starts fresh" do
      Sync do
        ask_human.ask("q1?")
        questions.enqueue("q1?")
        allow(conductor).to receive(:read_reply).and_return("42")
        replies.drain_at_prompt

        allow(conductor).to receive(:read_reply).and_return("")
        replies.drain_at_prompt
      end

      expect(output.string.scan("no questions pending").size).to eq(1)
    end

    it "leaves the human's own answer empty (never a raise) when the human types nothing" do
      Sync do
        ask_human.ask("q1?")
        questions.enqueue("q1?")
        allow(conductor).to receive(:read_reply).and_return("")

        expect { replies.drain_at_prompt }.not_to raise_error
      end

      expect(ask_human.pending?).to be(true) # unanswered -- an empty line never resolves
    end

    it "keeps a blank-answered question listable -- a still-pending item is never dropped from the view" do
      Sync do
        ask_human.ask("q1?")
        questions.enqueue("q1?")
        allow(conductor).to receive(:read_reply).and_return("") # human types nothing, leaves the item

        replies.drain_at_prompt
        replies.drain_at_prompt # a second /inbox must still show the unanswered question
      end

      expect(ask_human.pending?).to be(true)
      expect(output.string.scan("q1?").size).to be >= 2 # listed by BOTH drains, not silently dropped
    end
  end

  # T16's editor leg, from the wire IN. Everything here starts from a command
  # shaped EXACTLY as runtime.lua sends it -- `[verb, args]`, args an Array,
  # annotations String-keyed because they crossed msgpack -- because the defect
  # this file was missing lived precisely there: both sides had green specs and
  # the seam between them was never crossed, so `review_done` arrived as flat
  # positionals and every `:LainReviewDone` was silently refused.
  describe "the editor's command rail" do
    let(:editor) { RecordingEditorRail.new }
    let(:review_journal) { StringIO.new }
    let(:review) { Lain::Epic::Review.new(journal: Lain::Journal.new(io: review_journal), epic_slug: "alpha") }
    let(:written) do
      Lain::Epic::Intake::Written.new(
        graph: Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "b2", title: "the thing")])
      )
    end
    let(:path) { File.join(@dir, "epic.md") }

    # The wire's own shape: one array argument, String keys throughout.
    def review_done(generation, slug = "alpha", annotations = [])
      ["review_done", [generation, slug, annotations]]
    end

    def annotation(line:, text: "tighten this AC", anchor_text: "## b2 the thing")
      { "line" => line, "text" => text, "anchor_text" => anchor_text }
    end

    def open_review
      File.write(path, written.bytes)
      replies.bind_editor(editor)
      review.open(path:, written:)
    end

    # Runs the reply surfaces for real (they are Async tasks), pumps the reactor
    # until the expectation the caller is waiting on holds, and always stops
    # them. `sleep` here parks the fiber under Async's scheduler, so the
    # consumer fiber's own poll tick gets its turn.
    def with_surfaces(timeout: 3)
      Sync do |task|
        surfaces = replies.surfaces(task)
        deadline = Async::Clock.now + timeout
        task.sleep(0.02) until yield || Async::Clock.now > deadline
        surfaces.compact.each(&:stop)
      end
    end

    it "settles the bound review from the wire's array-of-args, with what is on disk" do
      token = open_review
      File.write(path, written.bytes.sub("the thing", "a sharper thing"))
      replies.bind_review(review, token:)
      editor.push(review_done(token.generation))

      with_surfaces { token.resolved? }

      expect(token).to be_resolved
      expect(token.await.account.changes).to eq({ retitled: ["b2"] })
      expect(editor.refusals).to be_empty
    end

    it "hands the annotations through String-keyed, exactly as they crossed msgpack" do
      token = open_review
      replies.bind_review(review, token:)
      settled = nil
      allow(review).to receive(:settle) { |*args, **kwargs| settled = [args, kwargs] }
      editor.push(review_done(token.generation, "alpha", [annotation(line: 3)]))

      with_surfaces { settled }

      expect(settled).to eq([[token.generation],
                             { disk: written.bytes, annotations: [annotation(line: 3)] }])
    end

    it "tells the editor when the done gesture names no open review" do
      open_review
      editor.push(review_done(9))

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/generation 9 is not open/))
    end

    # The killer this loop had no answer for: settle raising anything that is
    # not NotOpen took the fiber down, and :LainReply -- the OTHER surface on
    # this one fiber -- died with it, silently.
    it "keeps serving :LainReply after a settle that raises" do
      token = open_review
      replies.bind_review(review, token:)
      FileUtils.rm(path)
      ask_human.ask("still there?")
      editor.push(review_done(token.generation))
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals).to contain_exactly(a_string_matching(/epic\.md/))
    end

    it "keeps serving :LainReply after an annotation the wire dropped a key from" do
      token = open_review
      replies.bind_review(review, token:)
      ask_human.ask("still there?")
      editor.push(review_done(token.generation, "alpha", [{ "line" => 3, "anchor_text" => "## b2 the thing" }]))
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals.size).to eq(1)
    end

    # One reader for every integer off the wire (Epic::WireInteger). `.to_i`
    # would turn "7abc" into 7 -- a generation nobody sent, keyed onto a review
    # somebody else is holding.
    it "refuses a generation the wire cannot mean, rather than coercing it onto a live review" do
      token = open_review
      replies.bind_review(review, token:)
      editor.push(review_done("#{token.generation}abc"))

      with_surfaces { editor.refusals.any? }

      expect(token).not_to be_resolved
      expect(editor.refusals).to contain_exactly(a_string_matching(/generation must be a positive canonical integer/))
    end

    # A wire generation that IS canonical still names its review: the editor
    # stamps msgpack integers today, but a String is what JSON and a hand-typed
    # command produce, and both key one review.
    it "settles a review named by a canonical String generation" do
      token = open_review
      replies.bind_review(review, token:)
      editor.push(review_done(token.generation.to_s))

      with_surfaces { token.resolved? }

      expect(token).to be_resolved
    end

    # Null over a nil check: no editor is an object that answers, not a branch.
    it "spawns no editor surface when no editor was bound" do
      replies.bind_editor(nil)

      Sync do |task|
        surfaces = replies.surfaces(task)

        expect(surfaces.compact.size).to eq(1)
        surfaces.compact.each(&:stop)
      end
    end
  end
end
