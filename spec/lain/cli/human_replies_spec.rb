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
# SAME reply seam rather than a second answer path. It exists because the OM-6
# supervisor's fleet outlives a single ask: a subagent can post a question
# through `announce` ({Lain::CLI::Wiring::Askers}) at ANY time, but only
# #answer_loop's fiber -- alive only DURING an ask -- drains `@questions`
# otherwise, so a question posted while the human sits idle at `you>` has no
# live watcher until this runs.
#
# T11: every answer here NAMES the set it answers. What rides the queue is an
# {Lain::CLI::HumanReplies::InboxItem} carrying the Q event's digest and the
# asker that asked it, and the reply seam this class holds is the run's
# {Lain::Tools::AskHuman::Directory} -- so an answer reaches the asker that
# asked, and retires the item it answered rather than whichever is at the head.
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
  let(:parent) { chain("hi") }
  let(:conductor) { instance_double(Lain::CLI::Conductor) }
  let(:notifier) { instance_double(Lain::Notify, question: nil) }
  # The REAL producer of what this class consumes. Both halves of the seam or
  # neither: this file exists because a defect once lived exactly between two
  # sides that each had green specs (see the editor rail below), and "the
  # arrival carries its own digest" is a claim about the pair.
  let(:askers) do
    Lain::CLI::Wiring::Askers.new(notifier:, observer: Lain::Event::ChainWriter::Null.new)
  end
  let(:questions) { askers.questions }
  # The run's routing table, exactly as Wiring hands it over: this class holds
  # the DIRECTORY, never one asker, so an answer goes to whoever asked the set
  # it names.
  let(:directory) { askers.directory }
  let(:ask_human) { askers.enrol(parent).asker }
  let(:replies) { described_class.new(tty:, conductor:, ask_human: directory, questions:) }

  def chain(text)
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => text }])
  end

  # A second agent holding its own asker -- what a subagent is once T10 gives
  # it one, and what makes "who asked" a real question rather than a constant.
  def other_asker(text = "another chat") = askers.enrol(chain(text)).asker

  # Asking IS announcing ({Wiring::Askers#announce}): the arrival lands on the
  # queue by itself. What comes back is the item that landed, read off the Q
  # event the ask just wrote.
  def announced(asker, question)
    asker.ask(question)
    Lain::CLI::HumanReplies::InboxItem.asked(question, asker.last_question)
  end

  # Ask, announce, and leave the item LISTED: a blank answer resolves nothing
  # and retires nothing, so this is how an example gets an item into the inbox
  # view without answering it.
  def listed(asker, question)
    announced(asker, question).tap do
      allow(conductor).to receive(:read_reply).and_return("")
      replies.drain_at_prompt
    end
  end

  # Pumps the reactor until the caller's condition holds, or gives up: a
  # condition that never comes true is a FAILING example, never a suite that
  # hangs with nothing to read. `sleep` parks the fiber under Async's
  # scheduler, so the surfaces' own fibers get their turn.
  def pumped_until(task, timeout: 3)
    deadline = Async::Clock.now + timeout
    task.sleep(0.02) until yield || Async::Clock.now > deadline
  end

  # Runs the reply surfaces for real (they are Async tasks), pumps until the
  # expectation the caller is waiting on holds, and always stops them.
  def with_surfaces(timeout: 3, &block)
    Sync do |task|
      surfaces = replies.surfaces(task)
      pumped_until(task, timeout:, &block)
      surfaces.each(&:stop)
    end
  end

  describe "#drain_at_prompt" do
    it "lists every queued question and resolves the live promise with one read answer" do
      Sync do
        announced(ask_human, "what now?")
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
        announced(ask_human, "q1?")
        allow(conductor).to receive(:read_reply).and_return("42")
        replies.drain_at_prompt

        allow(conductor).to receive(:read_reply).and_return("")
        replies.drain_at_prompt
      end

      expect(output.string.scan("no questions pending").size).to eq(1)
    end

    it "leaves the human's own answer empty (never a raise) when the human types nothing" do
      Sync do
        announced(ask_human, "q1?")
        allow(conductor).to receive(:read_reply).and_return("")

        expect { replies.drain_at_prompt }.not_to raise_error
      end

      expect(ask_human.pending?).to be(true) # unanswered -- an empty line never resolves
    end

    it "keeps a blank-answered question listable -- a still-pending item is never dropped from the view" do
      Sync do
        announced(ask_human, "q1?")
        allow(conductor).to receive(:read_reply).and_return("") # human types nothing, leaves the item

        replies.drain_at_prompt
        replies.drain_at_prompt # a second /inbox must still show the unanswered question
      end

      expect(ask_human.pending?).to be(true)
      expect(output.string.scan("q1?").size).to be >= 2 # listed by BOTH drains, not silently dropped
    end

    # Defect 2, the reason an item carries its own attribution: read off "the
    # question asked most recently" instead, every line in the list names
    # whoever asked LAST, so a two-agent inbox says one agent is stuck twice.
    it "names the asker that asked each item, not whoever asked most recently" do
      other = other_asker
      Sync do
        first = announced(ask_human, "which db?")
        second = announced(other, "deploy now?")
        allow(conductor).to receive(:read_reply).and_return("")

        replies.drain_at_prompt

        expect(first.from).not_to eq(second.from)
        expect(output.string).to include(first.from.to_s[0, 19]).and include(second.from.to_s[0, 19])
      end
    end

    # Defect 3: the ensure retired the HEAD, which need not be the item the
    # answer belonged to -- so answering the arriving question dropped the
    # older one from the human's only view of it, while the set it named
    # stayed pending forever.
    it "retires the item the answer named, leaving an older unanswered one listed" do
      other = other_asker
      Sync { listed(ask_human, "q1?") }
      Sync { announced(other, "q2?") }
      allow(conductor).to receive(:read_reply).and_return("go left")

      with_surfaces { other.last_answer }

      expect(other.last_answer.body["answer"]).to eq("go left")
      expect(ask_human.pending?).to be(true)
      Sync do
        allow(conductor).to receive(:read_reply).and_return("")
        output.truncate(output.rewind)
        replies.drain_at_prompt
      end
      expect(output.string).to include("q1?")
      expect(output.string).not_to include("q2?")
    end

    # The directory refuses a name nobody holds rather than guessing, and the
    # refusal is written to be read at a reply prompt: it says the LINE was
    # stale, not that the answer was wrong.
    it "tells the human when an answer names a set nothing is holding, and retires no item" do
      Sync do
        questions.enqueue(Lain::CLI::HumanReplies::InboxItem.new(question: "gone?", from: "blake3:aaa",
                                                                 digest: "blake3:deadbeef", asked_at: Time.now))
        allow(conductor).to receive(:read_reply).and_return("too late")

        replies.drain_at_prompt

        expect(output.string).to include("blake3:deadbeef").and include("inbox line offering it is stale")
        expect(replies.pending?).to be(true)
      end
    end
  end

  # Fix B: a Ctrl-C stops the answer loop mid-question, and the SAME unwind
  # abandons the set inside AskHuman. An item that survives that is a line
  # offering a question nothing is waiting on -- the live way a human answers
  # a ghost.
  describe "a run interrupted while a question is outstanding" do
    it "retires the item it was holding, and refuses a later answer for it with something actionable" do
      asked = nil
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }

      Sync do |task|
        surfaces = replies.surfaces(task)
        # The tool's own dispatch asks, which announces: the arrival reaches
        # the queue by the same path a real run's does.
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("which db?") }
        asked = ask_human.last_question
        run.stop # the sync gate unwinds: the set is withdrawn
        surfaces.each(&:stop) # and the loop holding its inbox line dies with it
      end

      expect(ask_human.pending?).to be(false)
      expect(replies.pending?).to be(false)
      expect { directory.reply("too late", asked.digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /inbox line offering it is stale/)
    end

    # The panel's probe, promoted: the stop lands while the human is TYPING,
    # so the read returns normally into a set that no longer exists. The
    # refusal is right and the human is told -- but the line it refuses must
    # not survive, or every later `/inbox` lists a question that can only ever
    # refuse. The `ensure` retires on EVERY exit for exactly this: the shape
    # the interrupt example above drives is one of several, and a conditional
    # ensure covers only the one somebody thought of.
    it "retires the line when the set is withdrawn while the human is still typing" do
      reading = false
      allow(conductor).to receive(:read_reply) do
        reading = true
        Async::Task.current.sleep(0.2)
        "postgres"
      end

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { reading }
        run.stop # the sync gate unwinds UNDER the reader: the set is withdrawn
        pumped_until(task) { output.string.include?("stale") }
        surfaces.each(&:stop)
      end

      expect(output.string).to include("inbox line offering it is stale")
      expect(replies.pending?).to be(false)
    end

    # The delivery is not a straight line: it writes through the ChainWriter,
    # whose observer this codebase twice documents as a real yield point.
    it "retires the line when the delivery itself raises" do
      allow(conductor).to receive(:read_reply).and_return("postgres")
      allow(directory).to receive(:reply).and_raise(RuntimeError, "store is on fire")

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("store is on fire") }
        surfaces.each(&:stop)
        run.stop
      end

      expect(replies.pending?).to be(false)
    end

    def invocation = Lain::Tool::Invocation.new(context: Lain::Session::Null.instance)
  end

  # The TTY answer surface is the one ruling 7 keeps live whether or not an
  # editor is attached, and it runs on ONE fiber for the whole run. Its two
  # calls reach a real terminal (Reline) and the Store; either raising used to
  # end that fiber permanently and silently, with arrivals still landing on a
  # queue nothing drained. Same guard as the editor rail, for a sharper reason.
  describe "the answer surface under a raise" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "keeps answering after the reply read raises" do
      reads = 0
      allow(conductor).to receive(:read_reply) do
        reads += 1
        raise IOError, "terminal went away" if reads == 1

        "postgres"
      end
      other = other_asker

      Sync do |task|
        surfaces = replies.surfaces(task)
        first = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { reads == 1 }
        second = task.async { other.call({ "question" => "which port?" }, invocation) }
        pumped_until(task) { other.last_answer }
        surfaces.each(&:stop)
        [first, second].each(&:stop)
      end

      expect(output.string).to include("terminal went away")
      expect(other.last_answer.body["answer"]).to eq("postgres") # the surface survived the first raise
    end

    it "keeps answering after a delivery raises, and tells the human why" do
      allow(conductor).to receive(:read_reply).and_return("postgres")
      deliveries = 0
      allow(directory).to receive(:reply).and_wrap_original do |original, *args|
        deliveries += 1
        raise "store is on fire" if deliveries == 1

        original.call(*args)
      end
      other = other_asker

      Sync do |task|
        surfaces = replies.surfaces(task)
        first = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("store is on fire") }
        second = task.async { other.call({ "question" => "which port?" }, invocation) }
        pumped_until(task) { other.last_answer }
        surfaces.each(&:stop)
        [first, second].each(&:stop)
      end

      expect(output.string).to include("store is on fire")
      expect(other.last_answer.body["answer"]).to eq("postgres")
    end
  end

  # Ruling 9's shape, said out loud because the SAME keystroke means the
  # opposite thing one prompt over: a run is PARKED on this set, so declining
  # to answer is still an answer, and the line goes.
  describe "a blank line at human>" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "answers the parked set with an empty answer and retires the line" do
      allow(conductor).to receive(:read_reply).and_return("")

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { !ask_human.pending? }
        surfaces.each(&:stop)
        run.stop
      end

      expect(ask_human.last_answer.body["answer"]).to eq("")
      expect(replies.pending?).to be(false)
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
      Sync { listed(ask_human, "still there?") }
      editor.push(review_done(token.generation))
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals).to contain_exactly(a_string_matching(/epic\.md/))
    end

    it "keeps serving :LainReply after an annotation the wire dropped a key from" do
      token = open_review
      replies.bind_review(review, token:)
      Sync { listed(ask_human, "still there?") }
      editor.push(review_done(token.generation, "alpha", [{ "line" => 3, "anchor_text" => "## b2 the thing" }]))
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals.size).to eq(1)
    end

    # T9's owed branch: the answered document arrives as `[digest, AnswerSet]`
    # -- the digest routes it, and the set renders to the String a Tool::Result
    # carries. The pre-T11 guard asked the WRONG object ("does this asker have
    # anything pending"), which is not "is this digest answerable".
    it "answers the set a written question document names" do
      replies.bind_editor(editor)
      answered = nil
      Sync { answered = listed(ask_human, "which db?") }
      editor.push(["question_answered", [answered.digest, answer_set("postgres, it is already provisioned")]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to include("postgres")
      expect(editor.refusals).to be_empty
    end

    it "refuses a written document naming a set nobody holds, in the editor it came from" do
      replies.bind_editor(editor)
      editor.push(["question_answered", ["blake3:deadbeef", answer_set("too late")]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/blake3:deadbeef/))
    end

    # Null over a nil check: no editor is an object that answers, not a branch.
    it "spawns no editor surface when no editor was bound" do
      replies.bind_editor(nil)

      Sync do |task|
        surfaces = replies.surfaces(task)

        expect(surfaces.size).to eq(1) # only the surfaces that exist -- never a nil beside them
        surfaces.each(&:stop)
      end
    end

    # What QuestionView hands the rail: the parse of the document the human
    # wrote, whole-set prose in the simplest case.
    def answer_set(text)
      set = Lain::Question::Set.new(questions: [Lain::Question.new(id: "db", body: "which db?")])
      Lain::Question::AnswerSet.new(questions: set, text:)
    end
  end
end

# The producer half of the same seam, and the narrowest place the arrival was
# widened: one object owning the run's directory, the queue the reply surfaces
# park on, and the desktop notifier the same arrival fans out to.
RSpec.describe Lain::CLI::Wiring::Askers do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:notifier) { instance_double(Lain::Notify) }
  let(:notified) { [] }
  let(:askers) { described_class.new(notifier:, observer: Lain::Event::ChainWriter::Null.new) }
  let(:set) { Lain::Question::Set.new(questions: [Lain::Question.new(id: "db", body: "which db?")]) }

  before { allow(notifier).to receive(:question) { |agent:, text:| notified << [agent, text] } }

  def chain(text)
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => text }])
  end

  it "enqueues an arrival carrying the set, its digest and its asker -- never a bare String" do
    Sync do
      asker = askers.enrol(parent).asker
      asker.ask(Lain::Tools::AskHuman::Announcement.new(set))

      item = askers.questions.dequeue

      expect(item.digest).to eq(asker.last_question.digest)
      expect(item.from).to eq(asker.last_question.from)
      expect(item.question.set).to eq(set)
    end
  end

  it "names the asking agent to the desktop rather than a hardcoded one" do
    Sync do
      askers.enrol(parent, agent: "lain").asker.ask("which db?")
      askers.enrol(chain("child"), agent: "researcher").asker.ask("deploy now?")

      expect(notified).to eq([["lain", "which db?"], ["researcher", "deploy now?"]])
    end
  end

  # A correlation is 71 characters of hex and dunstify renders it as the
  # TITLE. The fallback names the asker the same way the TTY drain and the
  # nvim inbox name it -- clamped -- and the bound is what is pinned, because
  # the failure is a title no human can read, not a wrong string.
  it "falls back to the asker's own correlation, clamped, and never titles a notification with 71 characters" do
    Sync do
      asker = askers.enrol(parent).asker
      asker.ask("which db?")
      askers.enrol(chain("child"), agent: "a role name nobody kept short").asker.ask("deploy now?")

      expect(notified.map { |agent, _text| agent.length }).to all(be <= described_class::NAME_WIDTH)
      expect(asker.last_question.from).to start_with(notified.first.first)
    end
  end

  it "registers each asker, so an answer naming its set reaches the asker that asked it" do
    Sync do
      asker = askers.enrol(parent).asker
      other = askers.enrol(chain("child")).asker
      asked = asker.ask("which db?")
      other.ask("deploy now?")

      askers.directory.reply("postgres", asked.digest)

      expect(asker.last_answer.body["answer"]).to eq("postgres")
      expect(other.last_answer).to be_nil
    end
  end

  # The seam a child spawn reaches, and the ONLY thing it needs: `enrol` is
  # both halves at once. The keyword is pinned because the card that gives a
  # child its own asker cannot edit `wiring.rb` to add it -- if this keyword
  # goes, that card silently gets {described_class.unwired} and every child
  # question parks where nobody can see it.
  it "reaches the child construction path as ToolsetBuild's askers: keyword" do
    accepted = Lain::CLI::Wiring::ToolsetBuild.instance_method(:initialize).parameters

    expect(accepted).to include(%i[key askers])
  end

  # {ToolsetBuild::NoSwitchboard}'s precedent: a build nobody wired still
  # answers, and answers honestly -- the arrival goes nowhere, rather than the
  # construction raising in a spec that never asks anything.
  it "answers the whole duck unwired, routing an arrival to nobody" do
    Sync do
      unwired = described_class.unwired
      asked = unwired.enrol(parent).asker.ask("which db?")

      expect(unwired.questions.dequeue(timeout: 0).digest).to eq(asked.digest)
      expect(unwired.directory.reply("postgres", asked.digest).body["answer"]).to eq("postgres")
    end
  end

  # Retention is bounded by REGISTRATION lifetime (T8): whoever owns an
  # asker's life holds its registration, and dropping it is what stops the
  # routing -- the seam a child's lease reaps through.
  it "hands back the registration that releases the asker's routing" do
    Sync do
      enrolled = askers.enrol(parent)
      asked = enrolled.asker.ask("which db?")

      enrolled.registration.deregister

      expect { askers.directory.reply("postgres", asked.digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /#{asked.digest}/)
    end
  end
end
