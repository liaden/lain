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

# The nvim end of the question round trip, recorded: what
# {Lain::Frontend::Neovim::QuestionView} posts a document through
# (`open_question`), so an example can assert WHICH set's document reached the
# editor rather than merely that something did. The same double
# inbox_view_spec/question_view_spec use, here because T16's consumer wiring is
# only real if both production objects are on the far side of it.
class RecordingQuestionEditor
  def initialize(refusal: nil)
    @refusal = refusal
    @opened = []
  end

  attr_reader :opened

  def open_question(lines, digest)
    @opened << [lines, digest]
    @refusal
  end

  def documents = @opened.map(&:first)
  def digests = @opened.map(&:last)
end

# The changeset review as {Lain::CLI::HumanReplies} sees it (T11): the three
# gestures the sidebar and the diff pair send back, each answering an outcome
# that says in its own word whether it landed, and what to tell the human when
# it did not. Recorded rather than doubled so an example can assert WHICH row,
# WHICH stamp and WHICH direction reached the far side -- the half of the wire
# that a `have_received` on the consumer cannot see.
class RecordingChangesetReview
  # The three gestures name their own success, so the outcome answers all three
  # words: {Lain::CLI::HumanReplies#gestured} takes the predicate as a block
  # precisely so neither gesture has to be renamed to share one with the other.
  Outcome = Struct.new(:landed, :report) do
    def opened? = landed
    def marked? = landed
    def asked? = landed
  end

  def initialize(landed: true, raising: nil)
    @landed = landed
    @raising = raising
    @gestures = []
  end

  attr_reader :gestures

  def open(line, generation: nil) = record([:open, line, generation])
  def mark(line, state, generation: nil) = record([:mark, line, state, generation])
  def ask(anchor_id, question) = record([:ask, anchor_id, question])

  private

  def record(gesture)
    raise @raising if @raising

    @gestures << gesture
    Outcome.new(@landed, "the sidebar has re-rendered since you looked")
  end
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
  #
  # It announces an {Announcement} -- a whole set wearing its one-line summary
  # -- because that is what `Notifying#ask` hands its thunk on every model-path
  # ask, and therefore what every item in a real run carries. It used to
  # forward the bare String it was handed, and that is not a small difference:
  # the two arms take different code paths through the drain, so a file whose
  # every item took the String arm could not see a defect on the arm production
  # always takes. Two of them were live here (a whitespace-only line resolving
  # a set with a fabricated record; a refused answer parking the agent) under
  # green examples. {#announced_text} is the other arm, and it says so.
  def announced(asker, question)
    announced_text(asker, announcement(question))
  end

  # The bare-String arm, which is production too: the approval gate and
  # {Gherkin::Approval} ask through an `#ask`-shaped duck, and `Notifying`
  # hands the thunk the String they passed rather than the set `#ask` wraps it
  # in. Named so an example that means this arm says so.
  def announced_text(asker, question)
    asker.ask(question)
    Lain::CLI::HumanReplies::InboxItem.asked(question, asker.last_question)
  end

  # One free-text question, wearing its summary -- the set `AskHuman#ask`
  # builds from a String, which is what the model path announces.
  def announcement(question)
    return question if question.is_a?(Lain::Tools::AskHuman::Announcement)

    announcement_of(Lain::Question.new(id: "answer", body: question))
  end

  # A set whose questions are NAMED, for an example that has to tell which set
  # received an answer: the ids are what the prose answer prints back.
  def announcement_of(*questions)
    Lain::Tools::AskHuman::Announcement.new(Lain::Question::Set.new(questions:))
  end

  def question_of(id) = Lain::Question.new(id:, body: "which #{id}?")

  # Ask, announce, and leave the item LISTED: a blank answer resolves nothing
  # and retires nothing, so this is how an example gets an item into the inbox
  # view without answering it.
  def listed(asker, question)
    announced(asker, question).tap do
      allow(conductor).to receive(:read_reply).and_return("")
      replies.drain_at_prompt
    end
  end

  # Runs the reply surfaces for real (they are Async tasks), pumps until the
  # expectation the caller is waiting on holds, and always stops them. The ensure
  # is what makes "always" true: an unmet condition raises, and unstopped surfaces
  # keep the Sync block from ever returning.
  def with_surfaces(timeout: 3, &block)
    Sync do |task|
      surfaces = replies.surfaces(task)
      begin
        pumped_until(task, timeout:, &block)
      ensure
        surfaces.each(&:stop)
      end
    end
  end

  # For the negative: run the surfaces for a fixed window and assert what did NOT
  # arrive. Running out the clock is the success here, so it cannot go through
  # `with_surfaces`, whose timeout is a failure.
  def surfaces_settle(duration: 0.3)
    Sync do |task|
      surfaces = replies.surfaces(task)
      begin
        settle_for(task, duration)
      ensure
        surfaces.each(&:stop)
      end
    end
  end

  describe "#drain_at_prompt" do
    # A typed reply answers the WHOLE set in prose (T14), so what reaches the
    # asker is the AnswerSet's own rendering rather than the bare line -- the
    # human's words blockquoted inside a record that says they were typed, not
    # chosen. `eq("go left")` used to pass here only because the harness put a
    # String on the queue where production puts a set.
    it "lists every queued question and resolves the live promise with one read answer" do
      Sync do
        announced(ask_human, "what now?")
        allow(conductor).to receive(:read_reply).with(tty, "human> ").and_return("go left")

        answer = replies.drain_at_prompt

        expect(answer).to include("in prose rather than by selection").and include("> go left")
        expect(output.string).to include("what now?")
        expect(ask_human.last_answer.body["answer"]).to eq(answer)
      end
    end

    # The other arm, and it is not a legacy one: an `#ask`-shaped duck (the
    # approval gate) hands `Notifying`'s thunk a String, so there is no set to
    # render an answer against and the line the human typed IS the answer.
    it "delivers the typed line verbatim for a question asked as a bare String" do
      Sync do
        announced_text(ask_human, "what now?")
        allow(conductor).to receive(:read_reply).and_return("go left")

        expect(replies.drain_at_prompt).to eq("go left")
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

    # One space, and the record claimed the human was shown the set and
    # answered nothing -- a sentence nobody said. The drain guarded
    # `answer.empty?`, `Given#spoken` then dropped the blank prose, and what
    # was left rendered through the SELECTIONS arm as a perfectly non-empty
    # document -- so the caller's own `strip.empty?` guard was testing a
    # rendered document rather than the human's line, and passed.
    it "treats a whitespace-only line as no answer at all, on a set as on a bare String" do
      Sync do
        announced(ask_human, "q1?")
        allow(conductor).to receive(:read_reply).and_return("   ")

        expect(replies.drain_at_prompt).to eq("")
        expect(ask_human.pending?).to be(true)
        expect(ask_human.last_answer).to be_nil
      end
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

  # T14: the arrival note is the FIRST thing a human sees, and the item has
  # carried its own attribution since T11 -- so a two-agent fleet's arrivals
  # are told apart before the drain is ever opened, not only once it is.
  describe "the arrival note" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "names the asker that asked it" do
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("which db?") }
        surfaces.each(&:stop)
        run.stop
      end

      expect(output.string).to include("? #{ask_human.last_question.from.to_s[0, 19]} which db?")
    end
  end

  # T14, and the sharpest edge this chunk opened. The drain prints a whole
  # markdown DOCUMENT now, naming specific questions -- so `/inbox` typed at
  # the `human>` prompt of a PARKED set must render, and answer, that set. It
  # used to render the document (and build the prose answer) against whichever
  # item was OLDEST, then resolve the set actually being served with it: the
  # human read one set's questions and a different set got their answer, which
  # is exactly what `compose.rb`'s "NOTHING IS EVER SUBMITTED THAT THE HUMAN
  # DID NOT SEE" forbids.
  describe "`/inbox` typed at the reply prompt of a parked set" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "answers the set whose document it printed -- the one being served, never the oldest listed" do
      other = other_asker
      Sync { listed(ask_human, announcement_of(question_of("db"))) } # older, still pending, still listed
      typed = ["/inbox", "use postgres"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(other, announcement_of(question_of("region"))) }
      already_printed = output.string.size # only what the SERVED item's drain prints is under test
      with_surfaces { other.last_answer }
      drained = output.string[already_printed..]

      expect(other.last_answer.body["answer"]).to include("`region`")
      expect(other.last_answer.body["answer"]).not_to include("`db`")
      expect(drained).to include("## `region`")
      expect(drained).not_to include("## `db`")
      expect(ask_human.pending?).to be(true) # the older set is untouched by an answer it never saw
    end
  end

  # T14 round 3: an answer the record cannot carry is a REFUSAL, not a dead
  # line. Everything else that ends a served question -- answered, withdrawn,
  # unwound, raised out of the read -- means the item is gone and
  # #serve_question's ensure retires it unconditionally, which is what keeps a
  # set withdrawn while the human types from listing forever. A refused answer
  # is the one exit where the opposite is true: the question is still
  # outstanding, and the human can simply retype something the record can hold.
  # Getting that wrong parks the agent forever AND deletes the only line that
  # could unpark it.
  describe "an answer the record cannot carry" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "refuses it, keeps the question answerable, and takes the retry" do
      typed = ["/inbox", "x" * (70 * 1024), "postgres"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("beyond the 65536-byte maximum")
      expect(ask_human.last_answer.body["answer"]).to include("> postgres")
      expect(replies.pending?).to be(false)
    end

    it "leaves the question pending and still listed when the human gives up instead of retyping" do
      Sync do
        typed = ["x" * (70 * 1024), ""]
        allow(conductor).to receive(:read_reply) { typed.shift.to_s }
        announced(ask_human, "q1?")

        replies.drain_at_prompt
      end

      expect(output.string).to include("beyond the 65536-byte maximum")
      expect(ask_human.pending?).to be(true)

      already_printed = output.string.size
      Sync do
        allow(conductor).to receive(:read_reply).and_return("")
        replies.drain_at_prompt
      end
      expect(output.string[already_printed..]).to include("q1?") # a later drain still offers it
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

  # T11's inbound half, on the consumer's side of the rail. Three acked verbs,
  # which is why they arrive here at all: an acked command lands on the command
  # inbox and this fiber is the sole consumer of every verb on it. All three
  # obey the recorded rule -- the editor sends a LINE or a STAMP, never a
  # digest -- because a hunk key IS a digest and only the rendering that drew
  # the row can turn a row back into one.
  describe "the changeset review's gestures on the editor rail" do
    let(:editor) { RecordingEditorRail.new }
    let(:review) { RecordingChangesetReview.new }

    before do
      replies.bind_editor(editor)
      replies.bind_changeset_review(review)
    end

    it "opens the row a sidebar gesture names, carrying the rendering's stamp" do
      editor.push(["review_open", [4, 3]])

      with_surfaces { review.gestures.any? }

      expect(review.gestures).to eq([[:open, 4, 3]])
      expect(editor.refusals).to be_empty
    end

    # The STATE rides the wire rather than being toggled here: what the human
    # pressed says which way they meant it, and a toggle computed from a
    # rendering that has since moved flips the wrong hunk.
    it "marks the hunk a row names, in the direction the human pressed" do
      editor.push(["review_mark", [4, "reviewed", 3]])

      with_surfaces { review.gestures.any? }

      expect(review.gestures).to eq([[:mark, 4, "reviewed", 3]])
    end

    # No stamp, and the difference is real: an anchor id is one Ruby minted and
    # handed to the editor, so it names the same anchor in every rendering,
    # while a line only names one in the rendering that drew it.
    it "asks about the anchor an id names, with no stamp beside it" do
      editor.push(["review_ask", ["anchor-1", "why this way?"]])

      with_surfaces { review.gestures.any? }

      expect(review.gestures).to eq([[:ask, "anchor-1", "why this way?"]])
    end

    it "tells the editor, in the editor, when a gesture did not land" do
      replies.bind_changeset_review(RecordingChangesetReview.new(landed: false))
      editor.push(["review_open", [4, 1]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/re-rendered/))
    end

    # Null over a nil check, one surface further: no review open is an object
    # that answers, so no route here asks whether one was bound.
    it "refuses every gesture when no review is open" do
      replies.bind_changeset_review(nil)
      editor.push(["review_mark", [4, "reviewed", 1]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/no changeset review is open/))
    end

    # The killer this loop already had an answer for, now covering three more
    # verbs: a raise on ANY route would take :LainReply -- the other surface on
    # this one fiber -- down with it, and the editor would go quiet with no sign
    # why.
    it "keeps serving :LainReply after a review gesture that raises" do
      replies.bind_changeset_review(RecordingChangesetReview.new(raising: "the changeset moved under you"))
      Sync { listed(ask_human, "still there?") }
      editor.push(["review_open", [4, 1]])
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals).to contain_exactly(a_string_matching(/the changeset moved under you/))
    end

    # `NotImplementedError` is a `ScriptError`, not a `StandardError`, so the
    # guard that exists precisely because NOTHING a command does may kill this
    # fiber walked straight past it: :LainReply died with no refusal rendered
    # and the editor went quiet with no sign why. An abstract duck is not
    # hypothetical here -- {Frontend::Neovim::RpcThread::Listener}'s own base
    # raises exactly this class.
    it "keeps serving :LainReply after a review gesture raises something that is not a StandardError" do
      replies.bind_changeset_review(RecordingChangesetReview.new(raising: NotImplementedError.new("abstract")))
      Sync { listed(ask_human, "still there?") }
      editor.push(["review_open", [4, 1]])
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
      expect(editor.refusals).to contain_exactly(a_string_matching(/abstract/))
    end

    # The refusal's OWN failure, which is the last line of the one method whose
    # comment forbids anything killing this fiber -- and it reaches the editor,
    # the thing that just proved it can fail. It escaped every guard above it.
    it "survives the editor raising while being told a gesture did not land" do
      replies.bind_changeset_review(RecordingChangesetReview.new(raising: "hunk gone"))
      allow(editor).to receive(:review_refused).and_raise("editor gone")
      Sync { listed(ask_human, "still there?") }
      editor.push(["review_open", [4, 1]])
      editor.push(["reply", ["yes"]])

      with_surfaces { !ask_human.pending? }

      expect(ask_human.last_answer.body["answer"]).to eq("yes")
    end

    # A surface that answers the gesture but not the OUTCOME duck used to hand
    # the human "undefined method 'opened?' for nil", which names nothing they
    # can act on. The NoMethodError still rides along -- nothing is masked here,
    # it is labelled.
    it "says what went wrong when a review surface answers an outcome lain cannot read" do
      replies.bind_changeset_review(Class.new { def open(_line, **) = nil }.new)
      editor.push(["review_open", [4, 1]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/could not answer this gesture.*opened\?/m))
    end

    # WHY {Gestures} resolves its surfaces per call rather than holding them.
    # The route table is memoized, so a Gestures built once and held would have
    # frozen whatever was bound THEN -- and a review opened afterwards would be
    # ignored in silence, the exact failure the frontend rail uses a bound
    # accessor to prevent. Serving one command first is what makes the memo real
    # before the bind, so this cannot pass by accident.
    it "sees a review bound after the route table has already been built" do
      replies.bind_changeset_review(nil)
      later = RecordingChangesetReview.new
      editor.push(["review_open", [1, 1]])
      with_surfaces { editor.refusals.any? }

      replies.bind_changeset_review(later)
      editor.push(["review_mark", [4, "reviewed", 3]])
      with_surfaces { later.gestures.any? }

      expect(later.gestures).to eq([[:mark, 4, "reviewed", 3]])
    end
  end

  # T16: the inbox's OWN gestures, which is where this consumer had a hole
  # rather than a defect. T15 bound <CR> and `r` to :LainOpen and the editor
  # has been sending `["open", [line, generation]]` ever since -- and nothing
  # popped it, so the verb fell through this loop in silence and pressing enter
  # on an inbox item did nothing whatsoever in a live session.
  #
  # Wired with the PRODUCTION objects on both sides deliberately: a real
  # {Lain::Frontend::Neovim::Buffers} over a real InboxView and a real
  # QuestionView. The second half of the same hole was that production Buffers
  # built its InboxView with NO question surface, so it resolved to `Unwired`
  # and would have refused every gesture a consumer sent it -- invisible to
  # T15's specs, which injected the surface themselves.
  describe "the inbox's gestures on the editor rail" do
    let(:editor) { RecordingEditorRail.new }
    let(:nvim) { RecordingQuestionEditor.new }
    let(:question_view) { Lain::Frontend::Neovim::QuestionView.new(rpc: nvim) }
    let(:session) { Lain::Session.new }
    let(:views) { Lain::Frontend::Neovim::Buffers.new(store:, session:, questions: question_view) }
    # Every rendering the inbox has produced, newest last: what the human would
    # be looking at, which is how "the new set is listed" is asserted without
    # reaching into the view.
    let(:renderings) { [] }

    before do
      replies.bind_editor(editor, views:)
      views.initial
    end

    # Ask, announce, leave the item LISTED (`listed`'s own contract: a blank
    # answer resolves nothing), and render the arrival into the inbox view --
    # which is the drain thread's job in production, done inline here. Answers
    # the Q event, whose digest is what an answer names.
    def list(asker, question)
      Sync { listed(asker, question) }
      asker.last_question.tap do |event|
        renderings << views.updates(Lain::Telemetry::Message.from_event(event))
                           .fetch(Lain::Frontend::Neovim::InboxView::NAME)
      end
    end

    # What the editor sends back with the gesture: the stamp on the rendering
    # it is holding, which for a spec is always the newest one.
    def stamp = views.generation_of(Lain::Frontend::Neovim::InboxView::NAME)

    it "opens the set the cursor's line names, in the editor the gesture came from" do
      question = list(ask_human, "which db?")
      editor.push(["open", [1, stamp]])

      with_surfaces { nvim.opened.any? }

      expect(nvim.digests).to eq([question.digest])
      expect(nvim.documents.last.join("\n")).to include("which db?")
      expect(editor.refusals).to be_empty
    end

    it "opens the set on the line pressed, not whichever the inbox lists first" do
      list(ask_human, "which db?")
      second = list(other_asker, "deploy now?")
      editor.push(["open", [2, stamp]])

      with_surfaces { nvim.opened.any? }

      expect(nvim.digests).to eq([second.digest])
    end

    it "tells the editor when the line names no set, rather than opening nothing in silence" do
      editor.push(["open", [1, stamp]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/no question set/))
      expect(nvim.opened).to be_empty
    end

    # The gate, from the consumer's side: a stamp this view no longer holds is
    # REFUSED, never resolved against whatever rendering happens to be newest.
    it "refuses a gesture from a rendering the view no longer holds" do
      list(ask_human, "which db?")
      editor.push(["open", [1, stamp + 999]])

      with_surfaces { editor.refusals.any? }

      expect(nvim.opened).to be_empty
    end

    # `pin` has sat in the same state as `open` since B4: the editor sends it,
    # the view can honour it, and nothing popped it.
    it "pins the turn a :LainPin gesture names" do
      timeline = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
      views.updates(Lain::Telemetry::TurnUsage.new(digest: timeline.head_digest, model: "m",
                                                   stop_reason: :end_turn, usage: {}))
      editor.push(["pin", [1]])

      with_surfaces { session.pins.any? }

      expect(session.pins).to eq([timeline.head_digest])
      expect(editor.refusals).to be_empty
    end

    it "tells the editor when the pinned line names no turn" do
      editor.push(["pin", [4]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/no turn/))
      expect(session.pins).to be_empty
    end

    # Null over a nil check, one object further: a session with no editor has
    # no views either, and the gestures that can only come FROM an editor
    # answer without anybody asking whether one is attached. Driven through the
    # route table rather than the resolvers, which moved to
    # {Lain::CLI::HumanReplies::Gestures} -- so this now also pins that
    # unbinding REBUILDS that object, which a stale memoized table would hide.
    it "answers the gestures honestly with no editor bound at all" do
      replies.bind_editor(nil)

      expect { replies.send(:routes)["open"].call([1, 1]) }.not_to raise_error
      expect { replies.send(:routes)["pin"].call([1]) }.not_to raise_error
    end

    # T16's own ACs. The advance belongs HERE, on the consumer, and nowhere
    # else: {Frontend::Neovim::QuestionView}'s lock is not reentrant and its
    # `submit` runs inside it, so a set opened from the submit callable raises
    # `ThreadError: recursive locking` on the human's `:w` (question_view_spec
    # pins that). The consumer pops the hand-off AFTER the write has returned
    # and the lock is long gone, which is the only place the next set can open
    # from.
    describe "advancing after a submitted document" do
      # Exactly {Frontend::Neovim::CommandInbox#answered}'s push -- the verb and
      # the ONE array of arguments -- so what this spec puts on the rail is what
      # production's QuestionView hands it.
      let(:question_view) do
        Lain::Frontend::Neovim::QuestionView.new(
          rpc: nvim, submit: ->(digest, answers) { editor.push(["question_answered", [digest, answers]]) }
        )
      end

      # The human's `:w`, minus nvim: the document as it was handed to the
      # editor, written back citing the set it was opened for.
      def submit_open_document(digest)
        expect(question_view.wrote(nvim.documents.last, digest)).to be_nil
      end

      def open_first
        editor.push(["open", [1, stamp]])
        with_surfaces { nvim.opened.any? }
      end

      it "loads the next pending set when one is submitted" do
        first = list(ask_human, "which db?")
        second = list(other_asker, "deploy now?")
        open_first
        submit_open_document(first.digest)

        with_surfaces { nvim.opened.size > 1 }

        expect(nvim.digests).to eq([first.digest, second.digest])
        expect(nvim.documents.last.join("\n")).to include("deploy now?")
      end

      it "loads the one the inbox lists first among those remaining" do
        first = list(ask_human, "which db?")
        second = list(other_asker, "deploy now?")
        list(other_asker, "ship it?")
        open_first
        submit_open_document(first.digest)

        with_surfaces { nvim.opened.size > 1 }

        expect(nvim.digests).to eq([first.digest, second.digest])
      end

      # The panel's PROBE N at the seam that produced it: two submits in a row.
      # A row is retired by the agent's committed turn, not by the answer, so
      # after the second `:w` the FIRST set is still listed -- and an advance
      # that skipped only the set just answered handed it back as a blank
      # document, losing the human's ticks and making the third set unreachable.
      # Silently, because the second answer to a resolved set is dropped.
      it "keeps walking forward through a burst of submits, never back onto an answered set" do
        first = list(ask_human, "which db?")
        second = list(other_asker, "deploy now?")
        third = list(other_asker, "ship it?")
        open_first
        submit_open_document(first.digest)
        with_surfaces { nvim.opened.size > 1 }

        submit_open_document(second.digest)
        with_surfaces { nvim.opened.size > 2 }

        expect(nvim.digests).to eq([first.digest, second.digest, third.digest])
        expect(nvim.documents.last.join("\n")).to include("ship it?")
      end

      # The other surface answering is the same fact: :LainReply and the
      # terminal prompt both route through the ONE delivery path, so a set
      # answered there is not offered again by the editor's advance either.
      it "counts an answer that arrived at another surface, not only the editor's own" do
        first = list(ask_human, "which db?")
        second = list(other_asker, "deploy now?")
        editor.push(["reply", ["postgres"]])
        with_surfaces { !ask_human.pending? }

        editor.push(["open", [2, stamp]])
        with_surfaces { nvim.opened.any? }
        submit_open_document(second.digest)
        surfaces_settle

        expect(nvim.digests).to eq([second.digest])
        expect(first).not_to be_nil
      end

      # "Returns to the inbox" is the absence of a second document plus a view
      # holding no set: the human is left where the remaining rows are. The
      # advance says nothing on this path on purpose -- see
      # {Lain::CLI::HumanReplies#advance} -- so a stray warning would be the
      # failure, not the silence.
      it "returns to the inbox when the last set is submitted" do
        only = list(ask_human, "which db?")
        open_first
        submit_open_document(only.digest)

        surfaces_settle

        expect(nvim.opened.size).to eq(1)
        expect(question_view).not_to be_open
        expect(editor.refusals).to be_empty
        expect(renderings.last.join("\n")).to include("which db?")
      end

      # Ruling 2 is what makes this hold: {QuestionView#open} refuses while a
      # set is open and does NOT post on refusal, so no arrival can re-render
      # over a half-ticked document. If one ever can, the RequestBuffer clobber
      # defect is back.
      it "leaves an open set untouched when another arrives, and lists the new one" do
        first = list(ask_human, "which db?")
        open_first
        list(other_asker, "deploy now?")

        surfaces_settle

        expect(nvim.opened.size).to eq(1)
        expect(question_view.digest).to eq(first.digest)
        expect(renderings.last.join("\n")).to include("which db?").and include("deploy now?")
      end

      it "does not advance when the set is abandoned rather than submitted" do
        first = list(ask_human, "which db?")
        list(other_asker, "deploy now?")
        open_first
        question_view.abandoned(first.digest)

        surfaces_settle

        expect(nvim.opened.size).to eq(1)
        expect(question_view).not_to be_open
        expect(renderings.last.join("\n")).to include("which db?")
      end
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
