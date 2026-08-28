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

# The nvim end of the approval round trip, recorded: what
# {Lain::Frontend::Neovim::ApprovalView} answers a `y`/`n` gesture with. Its
# `decided?`/`report` pair is the whole duck the consumer reads, so this stands
# in for both outcomes without a real queue -- which the view's own spec drives
# for real.
class RecordingApprovalList
  Answer = Struct.new(:decided?, :report)

  def initialize(landed: true, report: "that call was already answered")
    @landed = landed
    @report = report
    @gestures = []
  end

  attr_reader :gestures

  def decide(line, verdict, generation:)
    @gestures << [line, verdict, generation]
    Answer.new(@landed, @report)
  end
end

# The nvim end of the question round trip, recorded: what
# {Lain::Frontend::Neovim::QuestionView} posts a document through
# (`open_question`), so an example can assert WHICH set's document reached the
# editor rather than merely that something did. The same double
# inbox_view_spec/question_view_spec use, here because this consumer's wiring
# is only real if both production objects are on the far side of it.
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

# The changeset review as {Lain::CLI::HumanReplies} sees it: the three
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

  # LANDED and REFUSED are deliberately DIFFERENT sentences, and that
  # difference is the whole point of this double: a fixture that answers the
  # same `#report` regardless of `#landed` cannot tell an example that pins
  # an ACKNOWLEDGEMENT apart from one that pins a REFUSAL -- both would read
  # the identical string back, and an assertion comparing that string to
  # itself passes for the wrong reason. A panel review caught exactly this:
  # forcing `landed: false` everywhere left every "acknowledges a mark that
  # landed" example green, because the double never distinguished the two
  # things a human can be told.
  LANDED = "marked reviewed: 1 hunk(s) of a.rb"
  REFUSED = "the sidebar has re-rendered since you looked"

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
    Outcome.new(@landed, @landed ? LANDED : REFUSED)
  end
end

# A registered `/word` as the reply prompt sees it: the whole command duck
# {Lain::CLI::Command::Registry} asks of a member -- a name, a usage line, and
# one `call(args, env)` -- with the args RECORDED, so an example can assert that
# a line typed at `human> ` reached the command rather than the asker.
#
# What it returns is the caller's, because a command's outcome is exactly what
# the reply prompt has to sort: rendered text, a {Lain::Renderable}, a Repl
# ACTION it cannot honour, or nil.
class RecordingCommand
  def initialize(name, returns: nil)
    @name = name
    @returns = returns
    @calls = []
  end

  attr_reader :name, :calls

  def usage = "/#{@name} -- a command a spec registered"

  def call(args, _env)
    @calls << args
    @returns
  end
end

# The command that blows up ANSWERING whether it reads the terminal, which is
# the one raise nothing wraps: {Lain::CLI::Command::Registry#invoke} guards the
# CALL, and `#serves_replies?` is asked before any call is made. Its own class
# rather than an option on {RecordingCommand}, because a command that declares
# the message at all is a different duck -- the registry asks `respond_to?`
# first, so a defaulted `serves_replies?` would quietly change every other
# example's command into a declarer.
class HostilePredicateCommand
  def name = "hostile"

  def usage = "/hostile -- a command a spec registered"

  def serves_replies? = raise("serves_replies? blew up")

  def call(_args, _env) = "never reached"
end

# #drain_at_prompt is the `/inbox`-at-`you>` half of this class -- the
# SAME TTY drain UX #answer_loop's read_drained_answer calls at `human>`
# (`@tty.drain_inbox`), reused rather than a second presentation, and the
# SAME reply seam rather than a second answer path. It exists because the
# supervisor's fleet outlives a single ask: a subagent can post a question
# through `announce` ({Lain::CLI::Wiring::Askers}) at ANY time, but only
# #answer_loop's fiber -- alive only DURING an ask -- drains `@questions`
# otherwise, so a question posted while the human sits idle at `you>` has no
# live watcher until this runs.
#
# Every answer here NAMES the set it answers. What rides the queue is an
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

  # A second agent holding its own asker -- what a subagent is once it has one,
  # and what makes "who asked" a real question rather than a constant.
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

  # Every reply surface a running chat has up, in the two lifetimes production
  # gives them: {Lain::CLI::Repl#run} holds the session ones for the
  # conversation and {Lain::CLI::Repl#respond} holds the ask ones for one ask.
  # An example meaning "an ask is in flight" wants both, which is what this is;
  # one meaning "the human is idle at `you>`" wants the session ones ALONE, and
  # says so at its own call site rather than through here.
  def all_surfaces(task) = replies.session_surfaces(task) + replies.surfaces(task)

  # Runs the reply surfaces for real (they are Async tasks), pumps until the
  # expectation the caller is waiting on holds, and always stops them. The ensure
  # is what makes "always" true: an unmet condition raises, and unstopped surfaces
  # keep the Sync block from ever returning.
  def with_surfaces(timeout: 3, &block)
    Sync do |task|
      surfaces = all_surfaces(task)
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
      surfaces = all_surfaces(task)
      begin
        settle_for(task, duration)
      ensure
        surfaces.each(&:stop)
      end
    end
  end

  describe "#drain_at_prompt" do
    # A typed reply answers the WHOLE set in prose, so what reaches the
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
    #
    # It also RETIRES the line, and that half changed in review. It used to
    # render and return, which left the dead question listed and offered it to
    # every later `/inbox` -- "a line that lists forever and can only ever
    # refuse". Nothing else on this path retires it: a drain calls
    # `#resolve_reply` directly, never through {AnswerLoop}, whose own ensure is
    # what settles the `human>` path. The refusal MEANS the set is gone, so
    # nothing is lost by letting the line go with it -- and the re-queue rule
    # (see "a surface stopped while it still holds an unanswered question") is
    # what makes a drain the likely finder of a ghost in the first place.
    it "tells the human when an answer names a set nothing is holding, and lets the stale line go" do
      Sync do
        questions.enqueue(Lain::CLI::HumanReplies::InboxItem.new(question: "gone?", from: "blake3:aaa",
                                                                 digest: "blake3:deadbeef", asked_at: Time.now))
        allow(conductor).to receive(:read_reply).and_return("too late")

        replies.drain_at_prompt

        expect(output.string).to include("blake3:deadbeef").and include("inbox line offering it is stale")
        expect(replies.pending?).to be(false)
      end
    end
  end

  # The arrival note is the FIRST thing a human sees, and the item carries its
  # own attribution -- so a two-agent fleet's arrivals are told apart before the
  # drain is ever opened, not only once it is.
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

    # ONE set can arrive TWICE: a reply too long for the tool's ceiling is
    # handed back on the digest already announced, so the human keeps one
    # inbox row. Keyed on that digest alone the second arrival was swallowed,
    # and somebody who typed 65 KB got a bare `human> ` back with nothing on
    # screen to say why. Keyed on the arrival -- the digest and the stamp
    # `InboxItem.asked` takes -- both are said.
    it "announces a second arrival for a set already announced" do
      typed = ["config.rb"]
      allow(conductor).to receive(:read_reply) { typed.shift || Async::Task.current.sleep(30) }
      item = announced(ask_human, "which db?")
      questions.enqueue(Lain::CLI::HumanReplies::InboxItem.new(question: "too long -- type `send`",
                                                               from: item.from, digest: item.digest,
                                                               asked_at: item.asked_at + 1))

      with_surfaces { output.string.include?("type `send`") }

      expect(output.string.scan("which db?").size).to eq(1)
    end

    # And the half the key must not lose: a re-queued item -- the same arrival,
    # dequeued again by the next dispatched line -- is still announced once.
    it "does not re-announce the same arrival when it is re-queued" do
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }
      item = announced(ask_human, "which db?")

      with_surfaces { output.string.include?("which db?") }
      questions.enqueue(item)
      surfaces_settle

      expect(output.string.scan("which db?").size).to eq(1)
    end
  end

  # The sharpest edge this chunk opened. The drain prints a whole
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

  # QA round 6. `human> ` used to be prose or the ONE string literal
  # `/inbox`, so every other registered `/word` was recorded as an answer -- a
  # human who typed `/status` while a set was parked sent the model the text
  # "/status" and got no status. The registry already parameterises exactly this
  # decision ({Lain::CLI::Command::Registry#dispatch} runs or yields), so the
  # prompt consults it instead of comparing strings.
  #
  # Two exceptions are pinned here rather than left to reading:
  #
  # * `/inbox` is a REPLY SURFACE, not a session command, and stays item-scoped.
  #   Dispatched through the registry it would drain `@inbox.oldest` and
  #   reintroduce the defect {Lain::CLI::HumanReplies::Reply#for}'s docstring
  #   records as fixed. The exception is expressed through the command's own
  #   `serves_replies?`, which is why the REAL {Lain::CLI::Command::Inbox} is
  #   registered below.
  # * a command returning a Repl ACTION has nowhere to go from here (the reply
  #   loop hands back an answer and an item, and nothing else), so it is refused
  #   BY NAME. The real {Lain::CLI::Command::Quit} is registered for the same
  #   reason: the refusal is about what production's `/quit` returns.
  describe "a session command typed at the reply prompt" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
    let(:ruby) { RecordingCommand.new("ruby", returns: "=> 2") }
    # Opaque on purpose: the registry curries it and hands it to the command,
    # and nothing about this seam depends on which collaborators it holds. A
    # strict double is also the loud witness if `/inbox` were ever dispatched --
    # {Lain::CLI::Command::Inbox#call} reads `env.replies`.
    let(:env) { instance_double(Lain::CLI::Command::Env) }
    let(:registry) do
      Lain::CLI::Command::Registry.new([ruby, Lain::CLI::Command::Inbox.new, Lain::CLI::Command::Quit.new])
    end

    before { replies.bind_commands(registry.bind(env)) }

    it "runs the command instead of answering the question" do
      typed = ["/ruby 1 + 1", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ruby.calls).to eq(["1 + 1"])
      expect(ask_human.last_answer.body["answer"]).not_to include("/ruby")
    end

    # A command that runs and shows nothing is indistinguishable from one that
    # was swallowed, which is the defect this card fixes wearing a hat. Both
    # return shapes {Repl#settle_command} delivers are delivered here too.
    it "renders what the command returned, in both of the shapes a command may answer with" do
      structured = RecordingCommand.new("status", returns: Lain::Renderable.new.plain("all quiet"))
      registry.register(structured)
      typed = ["/ruby 1 + 1", "/status", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("=> 2").and include("all quiet")
    end

    it "leaves the question awaiting a reply while the command runs" do
      typed = ["/ruby 1 + 1"]
      allow(conductor).to receive(:read_reply) { typed.shift || Async::Task.current.sleep(30) }

      Sync { announced(ask_human, "which db?") }
      surfaces_settle

      expect(ruby.calls).to eq(["1 + 1"])
      expect(ask_human.pending?).to be(true)
    end

    it "keeps /inbox item-scoped: it answers the set the loop is parked on, never the oldest listed" do
      other = other_asker
      Sync { listed(ask_human, announcement_of(question_of("db"))) } # older, still pending, still listed
      typed = ["/inbox", "use postgres"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(other, announcement_of(question_of("region"))) }
      with_surfaces { other.last_answer }

      expect(other.last_answer.body["answer"]).to include("`region`")
      expect(other.last_answer.body["answer"]).not_to include("`db`")
      expect(ask_human.pending?).to be(true)
    end

    it "refuses a command that would return a Repl action, by name, and keeps the question answerable" do
      typed = ["/quit", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("error:").and include("/quit")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    it "still answers the question with prose" do
      allow(conductor).to receive(:read_reply).and_return("go left")

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    it "still answers the question with an UNREGISTERED slash word" do
      allow(conductor).to receive(:read_reply).and_return("/not-a-command")

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("/not-a-command")
    end

    # Review fix 1. `Registry#invoke` wraps a raise from `#call` into an
    # attributed Lain::Error; NOTHING wraps a raise from `#serves_replies?`,
    # which is asked BEFORE any call. Un-rescued it climbs to
    # {Lain::CLI::HumanReplies::AnswerLoop#exchange}, whose `rescue
    # StandardError` reports the line SETTLED -- so the item is retired while
    # the promise is still pending, and the agent is parked forever with the
    # only line that could unpark it deleted. Measured, before the fix:
    # `replies.pending? == false` against `ask_human.pending? == true`.
    it "survives a raise from the PREDICATE, not only from the call, and keeps the question answerable" do
      registry.register(HostilePredicateCommand.new)
      typed = ["/hostile", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("serves_replies? blew up")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    # Review fix 3, the bound half. See the sibling describe for why this is a
    # regression rather than a new capability.
    it "answers with a line the skill grammar calls malformed, rather than refusing it" do
      allow(conductor).to receive(:read_reply).and_return("@bob/ go left")

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("@bob/ go left")
      expect(output.string).not_to include("malformed")
    end
  end

  # QA round 7. The sibling describe above pins the INLINE `human> `
  # read; this one pins the read one layer in, and they were not the same code.
  # `Reply#drained` handed {Lain::Frontend::TTY::Inbox} a bare reader lambda
  # that consulted no registry at all, so `/inbox` followed by any `/word`
  # recorded that word as the human's answer -- the exact defect the inline
  # prompt had already been fixed for, surviving behind the detour that reaches
  # it. Measured before the fix: `/status` in a drain reached the model as the
  # text "/status" and rendered nothing.
  #
  # The classification is {Lain::CLI::HumanReplies::Reply#classify}, shared with
  # the inline prompt rather than restated here, so the ORDER the registry's
  # lines are drawn in cannot drift between the two prompts.
  describe "a session command typed INSIDE the inbox drain" do
    let(:ruby) { RecordingCommand.new("ruby", returns: "=> 2") }
    let(:env) { instance_double(Lain::CLI::Command::Env) }
    let(:registry) do
      Lain::CLI::Command::Registry.new([ruby, Lain::CLI::Command::Inbox.new, Lain::CLI::Command::Quit.new])
    end

    before { replies.bind_commands(registry.bind(env)) }

    it "runs the command instead of answering the question, and the drain keeps reading" do
      typed = ["/inbox", "/ruby 1 + 1", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ruby.calls).to eq(["1 + 1"])
      expect(ask_human.last_answer.body["answer"]).not_to include("/ruby")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    it "renders what the command returned, through the same delivery the inline prompt uses" do
      typed = ["/inbox", "/ruby 1 + 1", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("=> 2")
    end

    it "still answers the parked question with ordinary prose" do
      typed = ["/inbox", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    # The safety property. An unregistered `/word` here is a MISTYPED command
    # far more often than it is a reply -- and unlike the inline prompt, where
    # the settled precedent is that it is an answer, sending it on is
    # unrecoverable: the model receives it as the human's considered reply to a
    # question they were reading at the time.
    it "refuses an unregistered slash word by name rather than sending it to the model" do
      typed = ["/inbox", "/statsu", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("/statsu")
      expect(ask_human.last_answer.body["answer"]).not_to include("/statsu")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    # A command returning a Repl ACTION has nowhere to go from a reply surface,
    # inline or drained -- {Lain::CLI::HumanReplies::Reply#delivered} is the one
    # place that says so, and this pins that the drain reaches it too.
    it "refuses a command that would return a Repl action, by name, and keeps the question answerable" do
      typed = ["/inbox", "/quit", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("/quit")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
    end

    # `/inbox` names THIS surface ({Lain::CLI::Command::Registry#serves_replies?}),
    # and it is already open. Dispatched it would open a second reader over the
    # same stdin, which is what `spec/reply_surface_discipline_spec.rb` exists
    # to prevent; silently ignored it reads as a wedged prompt. So it is refused
    # by name, like every other line this surface cannot honour.
    it "refuses /inbox typed into the drain it already opened, rather than opening a second reader" do
      typed = ["/inbox", "/inbox", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("/inbox")
      expect(ask_human.last_answer.body["answer"]).to include("go left")
      expect(ask_human.last_answer.body["answer"]).not_to include("/inbox")
    end

    # The refusal names a way forward, so the way forward has to work.
    # {Lain::Skill::Invocation.parse} asks `line.start_with?("/")` on the RAW
    # line, so ONE LEADING SPACE takes a reply out of the grammar entirely --
    # it never reaches the registry, and `Question::Rules.prose` does not
    # strip, so what the model receives is what they typed.
    #
    # This is load-bearing for the whole split rather than a nicety: without
    # it the drain cannot express a reply that opens with a slash word at all,
    # and refusing such a reply would be a dead end rather than a retype.
    it "records a slash-word reply verbatim when the human takes the escape the refusal names" do
      typed = ["/inbox", " /tmp is fine"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("/tmp is fine")
    end

    # A refusal that names no way forward is one the human cannot act on --
    # {Reply#refusal}'s rule, applied to the arm that refuses a REPLY rather
    # than a command.
    it "names that escape in the refusal itself, rather than leaving the human to find it" do
      typed = ["/inbox", "/statsu", "go left"]
      allow(conductor).to receive(:read_reply) { typed.shift.to_s }

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(output.string).to include("start the line with a space")
    end
  end

  # The arm table is a CLOSED set, and the `else` is what keeps it closed.
  # {Lain::CLI::HumanReplies::Reply#typed} and `#replied` both `case` over
  # {Lain::CLI::HumanReplies::Reply#classify}'s answer, and a `case` with no
  # `else` evaluates to nil -- which `#accepted` reads as "nothing typed yet"
  # and re-reads. So a fourth arm added to `#classify` and forgotten at one of
  # the two call sites would SWALLOW every reply the human types, rendering
  # nothing: the exact silent-answer failure this whole card exists to close,
  # reintroduced by the refactor that closed it.
  #
  # Driven through `send` rather than a typed line because there is no line
  # that produces a fourth arm -- the hole opens only when the enum grows, so
  # the enum is what the example has to fake. CLAUDE.md's rule for a
  # non-exhaustive enum ("always have an `else`") stated as a test.
  describe "a classification arm nobody handled" do
    let(:reply) do
      Lain::CLI::HumanReplies::Reply.new(tty:, conductor:,
                                         inbox: Lain::CLI::HumanReplies::Pending.new)
    end

    it "raises from the inline prompt, naming the arm, rather than swallowing the line" do
      allow(reply).to receive(:classify).and_return(:invented)

      expect { reply.send(:typed, "go left", nil) }
        .to raise_error(Lain::Error, /invented/)
    end

    it "raises from the drain, naming the arm, rather than swallowing the line" do
      allow(reply).to receive(:classify).and_return(:invented)

      expect { reply.send(:answerable, "go left") }
        .to raise_error(Lain::Error, /invented/)
    end
  end

  # Review fix 3. `line.strip == "/inbox"` parsed nothing; consulting a registry
  # runs the real skill grammar over every reply line, and
  # {Lain::Skill::Invocation.parse} RAISES on a line that attempts the
  # `@role/skill` shape and breaks it. So `@bob/` -- a perfectly ordinary typed
  # answer -- became a `malformed skill invocation` refusal at a prompt that
  # dispatches no skills and has no malformed invocation to report.
  #
  # Pinned on BOTH paths because the Null is what a caller with no registry
  # gets, which is production until the reply prompt is wired to the command
  # surface: the regression ships without the fix's own payload.
  #
  # `/not-a-command` is the settled precedent this restores it to. An
  # unparseable slash-or-at word at a reply prompt is an ANSWER.
  describe "a reply line the skill grammar calls malformed" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "is an answer, not a refusal, with no registry bound" do
      allow(conductor).to receive(:read_reply).and_return("@bob[/ go left")

      Sync { announced(ask_human, "which db?") }
      with_surfaces { ask_human.last_answer }

      expect(ask_human.last_answer.body["answer"]).to include("@bob[/ go left")
      expect(output.string).not_to include("malformed")
    end
  end

  # An answer the record cannot carry is a REFUSAL, not a dead
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

  # A reply surface no longer lives for one ASK -- it lives
  # for one dispatched LINE ({Lain::CLI::Repl::LineScope}), so it is started and
  # stopped around `/help`, `/status`, and every other command a human types in
  # a second. The fleet outlives all of them, so a subagent can enqueue
  # while one is running: the loop dequeues, renders the note, and parks on a
  # read the human is not looking at, and the line then ends UNDER it.
  #
  # An unanswered item must survive that. Retired, it is off `@questions`
  # (dequeued) AND off `@inbox`, so `pending?` is false, `/inbox` can never list
  # it, and the asker is parked forever with no error and no journal line. The
  # surface's stop says nothing about the QUESTION -- only about the surface --
  # so it goes back on the queue for the next surface (or `/inbox`) to reach.
  describe "a surface stopped while it still holds an unanswered question" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    it "puts the item back rather than destroying it" do
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("which db?") }
        surfaces.each(&:stop) # the LINE ended; the asker is still parked on the answer
        expect(replies.pending?).to be(true)
        run.stop
      end
    end

    # And the recovery is real, not merely a true `pending?`: the next surface up
    # dequeues the SAME item and can answer it, which is what "the asker is still
    # reachable" has to mean.
    it "lets the next surface serve and answer it" do
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }
      run = nil

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("which db?") }
        surfaces.each(&:stop)

        allow(conductor).to receive(:read_reply).and_return("postgres")
        later = replies.surfaces(task)
        pumped_until(task) { !ask_human.pending? }
        later.each(&:stop)
      end

      expect(ask_human.last_answer.body["answer"]).to include("postgres")
    ensure
      run&.stop
    end
  end

  # Fix B: a Ctrl-C stops the answer loop mid-question, and the SAME unwind
  # abandons the set inside AskHuman. An item that survives that is a line
  # offering a question nothing is waiting on -- the live way a human answers
  # a ghost.
  #
  # The review re-decided which of the two mistakes to make here, and the reason
  # is that {HumanReplies} cannot tell the two apart: a stopped surface holding
  # an unanswered item looks identical whether the set was withdrawn under it
  # (this group) or is still parked waiting for an answer (the group above). It
  # now KEEPS the item either way, because destroying a live question is silent
  # and permanent -- the asker waits forever, `pending?` reads false and no
  # `/inbox` can reach it -- where keeping a dead one costs exactly one further
  # arrival note and is then refused and retired. The ghost does not list
  # forever; the second example here is what pins that.
  describe "a run interrupted while a question is outstanding" do
    it "keeps the item it was holding, and refuses a later answer for it with something actionable" do
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
        surfaces.each(&:stop) # and the loop holding its inbox line is stopped with it
      end

      expect(ask_human.pending?).to be(false)
      expect(replies.pending?).to be(true)
      expect { directory.reply("too late", asked.digest) }
        .to raise_error(Lain::Tools::AskHuman::NoPendingQuestion, /inbox line offering it is stale/)
    end

    # The other half of that trade, and the reason it is affordable: a ghost is
    # served ONCE. The next surface takes it off the queue, the human types, the
    # directory refuses it as stale in words they can act on, and the ensure
    # retires it -- so nothing lists a question that can only ever refuse for a
    # second time.
    #
    # BOTH paths owe that, and the second one is the one this card is about.
    # `/inbox` does not go through {AnswerLoop} at all: `#drain_at_prompt` calls
    # `#resolve_reply` directly, so a refusal that only RENDERS leaves the line
    # listed and every later `/inbox` offers the dead question again -- which is
    # verbatim the property the inverted assertion above was traded against, and
    # the re-queue rule is what puts ghosts where `/inbox` finds them.
    it "lets a ghost go when it is /inbox that drained it" do
      strand_a_ghost
      allow(conductor).to receive(:read_reply).and_return("too late")

      answer = replies.drain_at_prompt

      expect(answer).to include("too late")
      expect(output.string).to include("inbox line offering it is stale")
      expect(replies.pending?).to be(false)
    end

    # The same fact as the human meets it: drain twice, and see whether the dead
    # question is offered a second time.
    it "does not offer that dead question to the next /inbox" do
      strand_a_ghost
      allow(conductor).to receive(:read_reply).and_return("too late")
      replies.drain_at_prompt
      already_printed = output.string.length

      replies.drain_at_prompt

      expect(output.string[already_printed..]).not_to include("which db?")
    end

    # Withdraw a set under a parked reader -- the Ctrl-C shape the example above
    # covers -- and leave the re-queued GHOST on the queue for a drain to find.
    def strand_a_ghost
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }
      Sync { |task| withdraw_under_reader(task) }
    end

    def withdraw_under_reader(task)
      surfaces = replies.surfaces(task)
      run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
      pumped_until(task) { output.string.include?("which db?") }
      run.stop              # the set is withdrawn
      surfaces.each(&:stop) # and the LINE ends under the parked reader
    end

    it "serves that ghost once more and then lets it go" do
      allow(conductor).to receive(:read_reply) { Async::Task.current.sleep(30) }

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        pumped_until(task) { output.string.include?("which db?") }
        run.stop
        surfaces.each(&:stop)

        allow(conductor).to receive(:read_reply).and_return("too late")
        later = replies.surfaces(task)
        pumped_until(task) { output.string.include?("inbox line offering it is stale") }
        later.each(&:stop)
      end

      expect(replies.pending?).to be(false)
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

  # `read_reply` answers nil when the stream it reads is closed, and until this
  # was fixed that nil was `.to_s`ed into "" -- the SAME value a human who
  # presses Enter types, and a value this surface delivers as their answer
  # because a parked run has to be told something. So a session whose stdin
  # went away wrote a `message` record `from: "human"` carrying
  # `{"answer" => ""}`: a human utterance in a session with no human attached.
  #
  # The two are one keystroke apart at the terminal and could not be further
  # apart in the record, so the distinction is drawn at the ONE place this
  # class reads a line, and EOF becomes {Lain::Tools::AskHuman::Unanswered} --
  # the answer nobody gave, riding the ordinary reply seam.
  describe "EOF at a reply prompt" do
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    # The parked call, run to completion under the real surfaces: what comes
    # back is the tool_result the model is handed. `run.wait` rather than
    # `run.stop`, deliberately -- a call that PARKED instead of coming back is
    # the defect, so the wait is the assertion and the watchdog is its failure.
    def dispatched
      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        begin
          pumped_until(task) { !ask_human.pending? }
          run.wait
        ensure
          surfaces.each(&:stop)
        end
      end
    end

    it "returns an error result saying nobody will answer, rather than parking forever" do
      allow(conductor).to receive(:read_reply).and_return(nil)

      result = dispatched

      expect(result).to be_error
      expect(result.content).to include("ask_human").and include("no answer will ever come back")
    end

    it "writes no message record attributed to the human" do
      allow(conductor).to receive(:read_reply).and_return(nil)

      dispatched

      expect(ask_human.last_answer).to be_nil
    end

    # Open decision 6, answered where the plan asked for it: the Q event is
    # written before the park, so by the time EOF is seen a question with no
    # possible answer is already in the record. Its disposition is a MATCHING
    # record -- from nobody, chained to the Q, carrying no "answer" key -- so a
    # reader of the journal can tell it from a question a human answered
    # emptily without knowing which surface was attached.
    it "records the question's fate rather than leaving the Q with nothing beside it" do
      allow(conductor).to receive(:read_reply).and_return(nil)

      dispatched
      record = ask_human.last_unanswered

      expect(record.from).to eq(Lain::Tools::AskHuman::Unanswered::NOBODY)
      expect(record.causal_parents).to include(ask_human.last_question.digest)
      expect(record.body).not_to have_key("answer")
    end

    # The deliberate behaviour this card must NOT collapse: a human who presses
    # Enter on an empty line HAS answered -- the run is parked on this set and
    # declining to answer still has to reach the model -- and the record says a
    # human said it.
    it "keeps a typed blank line an answer, attributed to the human" do
      allow(conductor).to receive(:read_reply).and_return("")

      dispatched

      expect(ask_human.last_answer.from).to eq("human")
      expect(ask_human.last_answer.body.fetch("answer")).to eq("")
      expect(ask_human.last_unanswered).to be_nil
    end

    # Ctrl-D on an empty line at a live Reline prompt returns the
    # SAME nil a vanished stdin does, and the human is still sitting there --
    # so a refusal claiming the session is unattended is false in its commonest
    # trigger, and that false clause lands in the journal under
    # `body["unanswered"]`, which is the record this card exists to keep honest.
    # The sentence may say what happened; it may not say who left.
    it "says only that this read ended, and the human it does not blame answers the next question" do
      allow(conductor).to receive(:read_reply).and_return(nil, "postgres")

      refused = dispatched
      answered = dispatched

      expect(refused).to be_error
      expect(refused.content).not_to match(/nobody is attached|no human is attached|human went away/)
      expect(answered).to be_ok
      expect(answered.content).to eq("postgres")
    end

    # A dying PTY does not politely return nil mid-read: it
    # raises. Both raises are StandardErrors, so they climbed to
    # {AnswerLoop#exchange}, which rendered them and settled the line -- the
    # inbox row deleted while the asker stayed parked forever, which is the
    # exact end state this surface's own comments say must never happen.
    %w[EOFError Errno::EIO].each do |raised|
      it "refuses the parked set when the read raises #{raised} rather than returning nil" do
        allow(conductor).to receive(:read_reply).and_raise(Object.const_get(raised))

        result = dispatched

        expect(result).to be_error
        expect(ask_human.last_answer).to be_nil
        expect(ask_human.last_unanswered.from).to eq(Lain::Tools::AskHuman::Unanswered::NOBODY)
      end
    end

    # The other half of the dying-PTY case, and the reason the rescue names two
    # classes rather than IOError: a read that failed for a reason which is NOT
    # the end of the stream keeps the surface's own error path -- rendered where the
    # human typed, and left to {AnswerLoop#exchange}'s documented rescue -- and
    # is never turned into "nobody will ever answer this". Widening the rescue
    # to IOError would make every transient terminal fault a question the model
    # is told is dead, which is the fabrication this card exists to remove
    # pointing the other way.
    #
    # What this deliberately does NOT assert is that the first question
    # survives: `exchange` reports a raise SETTLED and `serve` retires the line
    # without re-queueing, which is a reasoned, documented trade (the
    # alternative is a hot loop rendering one error forever) and is untouched
    # by this card. The sibling example "keeps answering after the reply read
    # raises" pins the half that IS guaranteed -- the surface lives on.
    it "leaves an ordinary read failure to the surface's own error path rather than refusing" do
      allow(conductor).to receive(:read_reply).and_raise(IOError, "terminal hiccuped")

      Sync do |task|
        surfaces = replies.surfaces(task)
        run = task.async { ask_human.call({ "question" => "which db?" }, invocation) }
        begin
          pumped_until(task) { output.string.include?("terminal hiccuped") }
        ensure
          surfaces.each(&:stop)
          run.stop
        end
      end

      expect(ask_human.last_unanswered).to be_nil
      expect(ask_human.last_answer).to be_nil
    end

    # The asymmetry this card reconciles: the drain already read "" as "nothing
    # typed" where the inline prompt read it as an answer, and neither could see
    # EOF at all. EOF now means one thing at both prompts, so a stream that ends
    # while the human is inside the `/inbox` detour refuses the set it is parked
    # on instead of answering it emptily.
    it "refuses the parked set when the stream ends inside the /inbox drain" do
      allow(conductor).to receive(:read_reply).and_return("/inbox", nil)

      result = dispatched

      expect(result).to be_error
      expect(ask_human.last_answer).to be_nil
      expect(ask_human.last_unanswered.from).to eq(Lain::Tools::AskHuman::Unanswered::NOBODY)
    end
  end

  # `/inbox` at `you>` is the prompt where NOTHING is parked on
  # the read -- the whole reason it exists is that the fleet outlives an ask --
  # so "the run is parked on this set, and declining still has to reach the
  # model" is the inline prompt's reason and is false here. A read that ends
  # without an answer settles nothing at this prompt, exactly as a blank line
  # already did: the questions are still listed, still answerable at the
  # editor or at the next `/inbox`, and nothing has been told they are dead.
  #
  # The uneven half matters as much as the destroyed half: with N questions
  # listed, refusing `@inbox.oldest` gave ONE of them a decision-6 record and
  # left N-1 with nothing -- the same doctrine applied to an arbitrary one.
  describe "EOF closing the `/inbox` listing at you>" do
    it "settles nothing, and leaves every listed question answerable" do
      Sync do
        announced(ask_human, "which db?")
        announced(other_asker, "which port?")
        allow(conductor).to receive(:read_reply).and_return(nil)

        replies.drain_at_prompt
      end

      expect(ask_human.last_unanswered).to be_nil
      expect(ask_human.pending?).to be(true)
      expect(replies.pending?).to be(true)
    end

    it "lets a later real answer reach the question a stray Ctrl-D would have destroyed" do
      Sync do
        announced(ask_human, "which db?")
        allow(conductor).to receive(:read_reply).and_return(nil)
        replies.drain_at_prompt

        allow(conductor).to receive(:read_reply).and_return("postgres")
        replies.drain_at_prompt
      end

      expect(ask_human.last_answer.body.fetch("answer")).to include("postgres")
      expect(ask_human.last_unanswered).to be_nil
    end

    it "writes no refusal record for any of the listed questions" do
      other = other_asker
      Sync do
        announced(ask_human, "which db?")
        announced(other, "which port?")
        allow(conductor).to receive(:read_reply).and_return(nil)

        replies.drain_at_prompt
      end

      expect([ask_human.last_unanswered, other.last_unanswered]).to eq([nil, nil])
    end
  end

  # The editor leg, from the wire IN. Everything here starts from a command
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

    # The owed branch: the answered document arrives as `[digest, AnswerSet]`
    # -- the digest routes it, and the set renders to the String a Tool::Result
    # carries. The earlier guard asked the WRONG object ("does this asker have
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
        surfaces = replies.session_surfaces(task)

        expect(surfaces).to be_empty # only the surfaces that exist -- never a nil beside them
        surfaces.each(&:stop)
      end
    end

    # Stated where the two lifetimes are decided. An ask starts and stops
    # the TTY drain and NOTHING else: the editor's consumer belongs to the
    # conversation, because the gestures it serves arrive between asks.
    it "keeps the editor consumer out of the surfaces an ask starts and stops" do
      replies.bind_editor(editor)

      Sync do |task|
        ask = replies.surfaces(task)
        session = replies.session_surfaces(task)

        expect([ask.size, session.size]).to eq([1, 1])
        (ask + session).each(&:stop)
      end
    end

    # What QuestionView hands the rail: the parse of the document the human
    # wrote, whole-set prose in the simplest case.
    def answer_set(text)
      set = Lain::Question::Set.new(questions: [Lain::Question.new(id: "db", body: "which db?")])
      Lain::Question::AnswerSet.new(questions: set, text:)
    end
  end

  # The changeset review's inbound half, on the consumer's side of the rail.
  # Three acked verbs,
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

    # The two lifetimes again, and the example above is the vacuous version of
    # it: `with_surfaces`
    # has an ask's surfaces up, which is the state a code review is almost never
    # in. Here the ask's are started and STOPPED first -- exactly what
    # {Lain::CLI::Repl#respond}'s ensure does when a turn settles -- and the
    # gesture arrives with nothing of that ask left running.
    it "marks a hunk with no ask in flight, on the session's consumer alone" do
      Sync do |task|
        session = replies.session_surfaces(task)
        replies.surfaces(task).each(&:stop)
        begin
          editor.push(["review_mark", [4, "reviewed", 3]])
          pumped_until(task, reason: "the idle gesture reached the review") { review.gestures.any? }
        ensure
          session.each(&:stop)
        end
      end

      expect(review.gestures).to eq([[:mark, 4, "reviewed", 3]])
      # A mark speaks on landing (see "acknowledges a mark that landed..."
      # below), so `editor.refusals` is not empty here -- what this example
      # pins is that it carries the OUTCOME'S own LANDED report (never the
      # refusal sentence) and nothing about the ask that was stopped before
      # the gesture arrived.
      expect(editor.refusals).to eq([RecordingChangesetReview::LANDED])
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

    # A mark is the ONE exception to "silent when it lands": every other
    # gesture on this rail has something else that tells a human it landed (a
    # cursor moves, a row closes), and the "opens the row..." example above
    # is where that silence is pinned. A mark redraws a sidebar glyph the
    # human is not necessarily looking at, so it speaks its outcome's own
    # `#report` unconditionally -- `eq` on a one-element Array pins BOTH
    # halves of the defect this closes: the wording, and that there is
    # exactly one acknowledgement, not one per hunk the row named.
    it "acknowledges a mark that landed, unlike every other gesture on this rail" do
      editor.push(["review_mark", [4, "reviewed", 3]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to eq([RecordingChangesetReview::LANDED])
    end

    # The failure leg is the example just above, over `review_open`; this pins
    # that a mark's own failure is still exactly ONE post, not doubled by the
    # change above -- `announce: true` REPLACES the predicate, it does not add
    # to it.
    it "still reports a mark that did not land, exactly once" do
      replies.bind_changeset_review(RecordingChangesetReview.new(landed: false))
      editor.push(["review_mark", [4, "reviewed", 3]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to eq([RecordingChangesetReview::REFUSED])
    end

    # Null over a nil check, one surface further: no review open is an object
    # that answers, so no route here asks whether one was bound.
    it "refuses every gesture when no review is open" do
      replies.bind_changeset_review(nil)
      editor.push(["review_mark", [4, "reviewed", 1]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/no changeset review is open/))
    end

    # The approval gesture. The verb rides THIS rail and not the answered one,
    # and that is the
    # whole of its wiring: deciding an approval resolves a promise, a promise
    # must be resolved on the reactor, and this fiber is the reactor's. Served
    # on the RPC thread the way a question's `:w` is, it would block that thread
    # on the reactor -- the stop condition this project has hit twice.
    it "answers the parked call a row names, in the direction the human pressed" do
      approvals = RecordingApprovalList.new
      replies.bind_editor(editor, approvals:)
      editor.push(["approval", [2, "deny", 7]])

      with_surfaces { approvals.gestures.any? }

      expect(approvals.gestures).to eq([[2, "deny", 7]])
      expect(editor.refusals).to be_empty
    end

    it "tells the editor, in the editor, when the call on that row was already answered" do
      replies.bind_editor(editor, approvals: RecordingApprovalList.new(landed: false))
      editor.push(["approval", [1, "approve", 7]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/already answered/))
    end

    # Null over a nil check, one surface further again: an editor with no
    # approval list is an object that answers, and it answers about the LIST --
    # being told "no editor is attached" while looking at one is the defect the
    # separate sentences exist to avoid.
    it "refuses the gesture when no approval list is bound" do
      replies.bind_editor(editor)
      editor.push(["approval", [1, "approve", 7]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/no approval list is open/))
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

      expect(editor.refusals).to contain_exactly(a_string_matching(/could not read its outcome.*opened\?/m))
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

  # ONE BIND, BOTH RAILS. A changeset review is reached from two places --
  # the acked gestures resolve on this consumer's fiber, and the two WRITES are
  # answered by the editor on its own RPC thread, through
  # {Frontend::Neovim#bind_changeset_review}. That method had no caller in the
  # whole tree, so every note and every verdict a human wrote reached
  # {Frontend::Neovim::NoReviewWrites} and came back "no review is open in this
  # editor" while one demonstrably was.
  describe "the second rail a changeset review is answered on" do
    # The frontend, reduced to the three messages this class asks of one. A
    # recorder rather than a double, because the property is WHICH object
    # reached the far rail: two binds are two chances for the rails to hold
    # different reviews, and that is a wrong-review write rather than an error.
    def review_editor
      Object.new.tap do |editor|
        editor.define_singleton_method(:bound) { @bound }
        editor.define_singleton_method(:bind_changeset_review) { |review| @bound = review }
        editor.define_singleton_method(:review_surface) { :the_editors_surface }
        editor.define_singleton_method(:review_view) { :the_editors_view }
      end
    end

    it "hands the editor's write rail the SAME review the gesture rail holds" do
      editor = review_editor
      review = RecordingChangesetReview.new
      replies.bind_review_editor(editor)

      replies.bind_changeset_review(review)

      expect(editor.bound).to equal(review)
    end

    # Closing a review is a bind like any other ({Frontend::Neovim}'s own rule),
    # so an unbind has to reach both rails too: a write rail left holding a
    # settled review would take a second verdict against it.
    it "unbinds both rails together" do
      editor = review_editor
      replies.bind_review_editor(editor)
      replies.bind_changeset_review(RecordingChangesetReview.new)

      replies.bind_changeset_review(nil)

      expect(editor.bound).to be_nil
    end

    it "binds harmlessly when no editor is attached, which is every headless chat" do
      expect { replies.bind_changeset_review(RecordingChangesetReview.new) }.not_to raise_error
    end

    # What {Wiring} threads into the tool as thunks. nil rather than a null
    # surface, deliberately: the object that coalesces those is the tool's own
    # seams, which is the one place that decision is made.
    it "reads the editor's surface and view off whatever editor is bound" do
      expect([replies.review_surface, replies.review_view]).to eq([nil, nil])

      replies.bind_review_editor(review_editor)

      expect([replies.review_surface, replies.review_view]).to eq(%i[the_editors_surface the_editors_view])
    end
  end

  # The inbox's OWN gestures, which is where this consumer had a hole rather
  # than a defect. The editor side bound <CR> and `r` to :LainOpen and has
  # been sending `["open", [line, generation]]` ever since -- and nothing
  # popped it, so the verb fell through this loop in silence and pressing enter
  # on an inbox item did nothing whatsoever in a live session.
  #
  # Wired with the PRODUCTION objects on both sides deliberately: a real
  # {Lain::Frontend::Neovim::Buffers} over a real InboxView and a real
  # QuestionView. The second half of the same hole was that production Buffers
  # built its InboxView with NO question surface, so it resolved to `Unwired`
  # and would have refused every gesture a consumer sent it -- invisible to
  # the editor side's specs, which injected the surface themselves.
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
      rendered(asker)
    end

    # A question RAISED while the human is idle at `you>`: it reaches the inbox
    # VIEW through the record stream and nothing ever gathers it into
    # {HumanReplies::Pending}, which is the state the reply path had no answer
    # for. Deliberately not {#list}, whose drain is what gathers.
    def raised_at_the_prompt(asker, question)
      Sync { announced(asker, question) }
      rendered(asker)
    end

    # The drain thread's job in production, done inline: the arrival rendered
    # into the inbox view, answering the Q event whose digest an answer names.
    def rendered(asker)
      asker.last_question.tap do |event|
        renderings << views.updates(Lain::Telemetry::Message.from_event(event))
                           .fetch(Lain::Frontend::Neovim::InboxView::NAME)
      end
    end

    # The session surfaces ALONE -- the editor's command rail with no ask in
    # flight, which is where a `you>`-time gesture actually lands. The ask's own
    # loop would dequeue the arrival and list it, which is the state the example
    # using this exists to stay out of.
    def idle_at_the_prompt(timeout: 3, &block)
      Sync do |task|
        surfaces = replies.session_surfaces(task)
        begin
          pumped_until(task, timeout:, &block)
        ensure
          surfaces.each(&:stop)
        end
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

    # Round 11. An ANSWER names its row exactly as an OPEN does, and it is
    # resolved through the same index off the same rendering -- which is what
    # stops :LainReply guessing "the oldest item listed".
    it "answers the set the reply's row names, not whichever the inbox lists first" do
      other = other_asker
      list(ask_human, "which db?")
      second = list(other, "deploy now?")
      editor.push(["reply", ["postgres", 2, stamp]])

      with_surfaces { !other.last_answer.nil? }

      expect(other.last_answer.causal_parents).to include(second.digest)
      expect(other.last_answer.body["answer"]).to eq("postgres")
      expect(ask_human.last_answer).to be_nil
      expect(editor.refusals).to be_empty
    end

    # THE DEFECT ITSELF, on the reply half. A question raised while the human
    # sits at `you>` reaches the inbox VIEW through the record stream, and
    # nothing ever gathers it into {HumanReplies::Pending} -- so the answer's
    # old fallback was `Unlisted.digest`, i.e. nil, and the human was told the
    # row they were looking at was stale. Session surfaces ONLY, because the
    # ask's own loop would dequeue the arrival and list it, which is exactly the
    # state this example is about NOT being in.
    it "answers a question raised from the editor while nothing at all is listed" do
      raised = raised_at_the_prompt(ask_human, "which db?")
      editor.push(["reply", ["postgres", 1, stamp]])

      idle_at_the_prompt { !ask_human.last_answer.nil? }

      expect(ask_human.last_answer.causal_parents).to include(raised.digest)
      expect(ask_human.last_answer.body["answer"]).to eq("postgres")
      expect(editor.refusals).to be_empty
    end

    # From the round-11 panel. A stamp this view no longer holds is the
    # one refusal that must NOT read as staleness: the asker is still parked and
    # the row is still live, and "nothing you type here is recorded" is the
    # exact sentence this card exists to stop a human being shown. `open`
    # already says the true thing; the answer says it too.
    it "tells the human to press again when the rendering it answered is one the view no longer holds" do
      list(ask_human, "which db?")
      editor.push(["reply", ["postgres", 1, stamp + 999]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/re-rendered since \d+ .*press again on the row/))
      expect(editor.refusals.join).not_to include("stale")
      expect(ask_human.last_answer).to be_nil
      expect(ask_human).to be_pending # the row is LIVE: nothing about it is stale
    end

    # The set the row names has been answered already and its row has not
    # cleared yet -- the state a human is most likely to press into, because the
    # row stands until a committed turn cites it. Delivered a second time it was
    # dropped as AlreadyResolved and the human was told NOTHING; `open` refuses
    # the same row with a sentence, and now so does this.
    it "says the row is answered rather than swallowing a second reply to it" do
      list(ask_human, "which db?")
      editor.push(["reply", ["postgres", 1, stamp]])
      editor.push(["reply", ["mysql", 1, stamp]])

      with_surfaces { editor.refusals.any? }

      expect(editor.refusals).to contain_exactly(a_string_matching(/line 1 is answered/))
      expect(ask_human.last_answer.body["answer"]).to eq("postgres")
    end

    # No row named at all -- a :LainReply hand-typed away from lain://inbox --
    # keeps the oldest-listed reading, which is the rule the terminal drain
    # reads a typed answer by. The wire is widened, not replaced.
    it "still answers the oldest listed set when the reply names no row" do
      question = list(ask_human, "which db?")
      editor.push(["reply", ["postgres"]])

      with_surfaces { !ask_human.last_answer.nil? }

      expect(ask_human.last_answer.causal_parents).to include(question.digest)
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

    # `pin` sits in the same state as `open`: the editor sends it,
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

    # The advance belongs HERE, on the consumer, and nowhere
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

  # Retention is bounded by REGISTRATION lifetime: whoever owns an
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
