# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

RSpec.describe Lain::Frontend::Intake do
  # What the rail tells the human, recorded rather than drawn.
  let(:screen) do
    Class.new do
      def initialize = @said = []
      attr_reader :said

      def render_held(text) = @said << [:held, text]

      def render_note(text) = @said << [:note, text]

      def render_human_note(text) = @said << [:human_note, text]

      def close_prompt(text) = text.respond_to?(:closed) && text.closed { |note| @said << [:closed, note] }

      def queue_prompt(text) = @said << [:queued, text.to_s]

      def drop_prompt(text) = @said << [:dropped, text.to_s]
    end.new
  end

  let(:rail) { described_class.new(screen:) }

  def line(text, generation) = described_class::Line.new(text:, generation:)

  # The routed sink's whole duck: where a signal lands, and whether a stop put
  # there would reach an ask at all ({Lain::CLI::Signals}).
  def sink_over(received, ask_in_flight:)
    Struct.new(:received, :flight) do
      def signal(name) = received << name
      def ask_in_flight? = flight
    end.new(received, ask_in_flight)
  end

  describe "#lifts?" do
    def lifts?(text, ask_in_flight:)
      rail.route(sink_over([], ask_in_flight:))
      rail.lifts?(line(text, 0))
    end

    it "is true of a /stop while an ask is in flight" do
      expect(lifts?("/stop", ask_in_flight: true)).to be(true)
    end

    it "is false of a /stop with no ask to stop, of any other line, and of a value that is not a line" do
      expect([lifts?("/stop", ask_in_flight: false), lifts?("hello", ask_in_flight: true),
              rail.lifts?(described_class::Eof.new)]).to eq([false, false, false])
    end

    it "is false at you>, where a /stop is an ordinary line" do
      rail.route(sink_over([], ask_in_flight: true))

      lifted = Sync do |task|
        reading = task.async { rail.read(:you, "you> ") }
        pumped_until(task, reason: "you> published") { rail.published.kind == :you }
        rail.lifts?(line("/stop", 0)).tap { reading.stop }
      end

      expect(lifted).to be(false)
    end
  end

  # A producer that answers each published prompt as a human at it would.
  def answered_when_published(task, generation: nil)
    task.async do
      pumped_until(task, reason: "a prompt published") { rail.published.generation.positive? }
      prompt = rail.published
      rail << line(yield(prompt), generation || prompt.generation)
    end
  end

  describe "its name" do
    # Case-blind and with an optional underscore, so the one pattern finds the
    # constant, its file and a symbol spelled after either.
    let(:former) { /input_?rail/i }

    it "is the constant its path names, and nothing in lib/ still answers to the former one" do
      lib = Lain::LOADER.dirs.first
      named = Lain::LOADER.all_expected_cpaths.fetch(File.join(lib, "lain/frontend/intake.rb"))
      stale = Dir[File.join(lib, "**/*.{rb,lua}")].select { |path| File.read(path).match?(former) }

      expect([named, described_class.name]).to eq(%w[Lain::Frontend::Intake Lain::Frontend::Intake])
      expect(stale.map { |path| path.delete_prefix("#{lib}/") }).to be_empty
      expect(Lain::Frontend.constants.grep(former)).to be_empty
    end
  end

  describe "its values" do
    it "are deeply frozen, so they can cross a thread or a socket unchanged" do
      values = [described_class::Prompt.new(kind: :approval, text: +"[y/N] ", header: +"", generation: 1),
                line(+"y", 1), described_class::Signal.new(name: :cancel), described_class::Eof.new]

      expect(values).to all(satisfy { |value| Ractor.shareable?(value) })
    end

    it "carries an asked prompt as its plain words, not the object that asked" do
      asked = Class.new(String) { def closed = nil }.new("[y/N] ")

      prompt = described_class::Prompt.new(kind: :approval, text: asked, generation: 1)

      expect([prompt.text.class, prompt.header]).to eq([String, ""])
    end

    it "refuses a prompt kind and a signal name nobody reads" do
      expect { described_class::Prompt.new(kind: :shout, text: "x", generation: 1) }
        .to raise_error(ArgumentError, /shout/)
      expect { described_class::Signal.new(name: :explode) }.to raise_error(ArgumentError, /explode/)
    end

    it "carries a countdown's keys frozen, each naming a signal a producer may send" do
      prompt = described_class::Prompt.new(kind: :countdown, text: "closing in 30s", generation: 1,
                                           keys: { c: "cancel" })

      expect([prompt.keys, Ractor.shareable?(prompt)]).to eq([{ "c" => :cancel }, true])
    end

    it "calls a prompt an answer only when a run waits on what is typed at it" do
      kinds = described_class::KINDS.select do |kind|
        described_class::Prompt.new(kind:, text: "x", generation: 1).answer?
      end

      expect(kinds).to eq(%i[human approval])
    end
  end

  describe "#read" do
    it "publishes the prompt and answers with the line typed at it" do
      answer = Sync do |task|
        answered_when_published(task) { "postgres" }
        rail.read(:human, "human> ")
      end

      expect(answer).to eq("postgres")
      expect(rail.published.generation).to eq(0)
    end

    it "gives every publication a fresh generation" do
      generations = []

      Sync do |task|
        2.times do
          answered_when_published(task) { |prompt| (generations << prompt.generation).last.to_s }
          rail.read(:you, "you> ")
        end
      end

      expect(generations).to eq([1, 2])
    end

    it "answers nil when the stream ends under the prompt" do
      answer = Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation.positive? }
          rail << described_class::Eof.new
        end
        rail.read(:human, "human> ")
      end

      expect(answer).to be_nil
    end
  end

  # The one rule that replaces the typeahead guards: a line begun before the
  # prompt it arrives at was drawn cannot be an answer to that prompt.
  describe "a line whose generation predates the open prompt" do
    it "is held, never an answer, and the prompt opens again empty" do
      published = []
      answer = Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation == 1 }
          published << rail.published.generation
          rail << line("yes please", 0)
          pumped_until(task) { rail.published.generation == 2 }
          published << rail.published.generation
          rail << line("n", 2)
        end
        rail.read(:approval, "[y/N] ")
      end

      expect(answer).to eq("n")
      expect(published).to eq([1, 2])
      expect(screen.said).to eq([[:held, "yes please"]])
      expect(rail.take_held).to eq("yes please")
    end

    it "is taken by a prompt that answers nothing, where typing ahead is what the human meant" do
      answer = Sync do |task|
        answered_when_published(task, generation: 0) { "/approve" }
        rail.read(:command, "command> ")
      end

      expect(answer).to eq("/approve")
      expect(screen.said).to be_empty
    end

    it "becomes the next you> line once the prompts ahead of it close, with nothing drawn" do
      rail.hold("typed ahead")

      expect(rail.read(:you, "you> ")).to eq("typed ahead")
      expect(rail.published.generation).to eq(0)
    end
  end

  # A line typed at a prompt that has since gone -- its call decided elsewhere
  # as Enter was pressed -- answers nothing that is open now, so it is held and
  # said to be; the prompt drawn now keeps its drawing.
  describe "a line whose generation names a prompt withdrawn since" do
    it "is held at a prompt that answers nothing, which keeps waiting on its own drawing" do
      published = []
      answer = Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation == 1 }
          rail << line("y", 1)
        end
        rail.read(:approval, "[y/N] ")
        task.async do
          pumped_until(task) { rail.published.generation == 2 }
          rail << line("n", 1)
          published << rail.published.generation
          rail << line("next", 2)
        end
        rail.read(:you, "you> ")
      end

      expect([answer, published, rail.take_held]).to eq(["next", [2], "n"])
      expect(screen.said).to eq([[:held, "n"]])
    end
  end

  describe "what is published once a prompt is withdrawn" do
    let(:decided_elsewhere) do
      Class.new(String) { def decision = yield("decided by editor: denied") }.new("[y/N] ")
    end

    def closed_after_withdrawal(text)
      Sync do |task|
        reading = task.async { rail.read(:approval, text) }
        pumped_until(task, reason: "a prompt published") { rail.published.kind == :approval }
        reading.stop
        rail.published
      end
    end

    it "holds the sentence of a prompt another surface decided, as a frozen value" do
      withdrawn = closed_after_withdrawal(decided_elsewhere)

      expect([withdrawn.kind, withdrawn.closed, Ractor.shareable?(withdrawn)])
        .to eq([nil, "decided by editor: denied", true])
    end

    it "holds nothing for a prompt nobody else decided, and before any prompt" do
      expect([closed_after_withdrawal("[y/N] ").closed, rail.published.closed]).to eq(["", ""])
    end
  end

  describe "an attached producer" do
    it "is told at once when a prompt is published and when it is withdrawn" do
      producer = Object.new
      told = rail.attach(producer)

      Sync do |task|
        reading = task.async { rail.read(:human, "human> ") }
        told.pop
        published = rail.published
        reading.stop
        told.pop

        expect([published.generation, rail.published.generation]).to eq([1, 0])
      end
    end
  end

  describe "a line typed at a prompt that says nothing of what it takes" do
    it "is the answer, `/command` or not, for the reader to classify itself" do
      answer = Sync do |task|
        answered_when_published(task) { "/inbox" }
        rail.read(:human, "human> ")
      end

      expect([answer, rail.take_held]).to eq(["/inbox", nil])
    end
  end

  describe "a line the prompt says it does not take" do
    it "is held, and the prompt asks again" do
      asked = Class.new(String) { def takes?(line) = !line.start_with?("/") }.new("[y/N] ")
      answer = Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation == 1 }
          rail << line("/goal off", 1)
          pumped_until(task) { rail.published.generation == 2 }
          rail << line("n", 2)
        end
        rail.read(:approval, asked)
      end

      expect([answer, rail.take_held]).to eq(["n", "/goal off"])
    end
  end

  describe "a line an approval prompt refuses, in a chat that takes notes" do
    it "is held and never posted as a note" do
      taking = Struct.new(:taken) { def take?(line) = taken << line }.new([])
      noting = described_class.new(screen:, notes: taking)
      asked = Class.new(String) { def takes?(line) = line == "n" }.new("[y/N] ")
      Sync do |task|
        task.async do
          pumped_until(task) { noting.published.generation == 1 }
          noting << line("prefer Syncthing", 1)
          pumped_until(task) { noting.published.generation == 2 }
          noting << line("n", 2)
        end
        noting.read(:approval, asked)
      end

      expect([taking.taken, screen.said.map(&:first)]).to eq([[], [:held]])
    end
  end

  describe "a prompt that explains why it refused a line" do
    it "has the explanation said right after the held line" do
      asked = Class.new(String) do
        def takes?(line) = line == "n"
        def refused = yield "only n answers"
      end.new("[y/N] ")
      Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation == 1 }
          rail << line("chatter", 1)
          pumped_until(task) { rail.published.generation == 2 }
          rail << line("n", 2)
        end
        rail.read(:approval, asked)
      end

      expect(screen.said).to eq([[:held, "chatter"], [:note, "only n answers"]])
    end
  end

  describe "a prompt that answers `drawn`" do
    let(:asked) do
      Class.new(String) do
        def initialize(text)
          super
          @drawn = 0
        end

        def drawn = @drawn += 1
        def drawn_times = @drawn
      end
    end

    it "is told once its prompt is published, not while it waits behind another" do
      waiting = asked.new("[y/N] ")
      told_while_waiting = nil

      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        pumped_until(task) { rail.published.kind == :human }
        reading = task.async { rail.read(:approval, waiting) }
        settle_for(task, 0.02)
        told_while_waiting = waiting.drawn_times
        reading.stop
        question.stop
      end

      expect(told_while_waiting).to eq(0)
    end

    it "is told when it becomes the head and is drawn" do
      prompt = asked.new("[y/N] ")

      Sync do |task|
        answered_when_published(task) { "y" }
        rail.read(:approval, prompt)
      end

      expect(prompt.drawn_times).to eq(1)
    end

    it "is drawn with the time it reached the head, not the time it began to wait" do
      now = Time.new(2026, 10, 8, 13, 14, 1)
      pending = Lain::Approval::Parked::Queue::Pending.new(
        effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: {}),
        identity: Lain::Requester.main, clock: -> { 0 }
      )
      waiting = Lain::Frontend::ApprovalPolicy::Asked.new("[y/N] ", pending, wall_clock: -> { now })
      drawn = nil

      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        pumped_until(task) { rail.published.kind == :human }
        reading = task.async { rail.read(:approval, waiting) }
        settle_for(task, 0.02)
        now += 300
        question.stop
        pumped_until(task) { rail.published.kind == :approval }
        drawn = rail.published.text
        reading.stop
      end

      expect(drawn).to eq("13:19:01 [y/N] ")
    end

    it "starts the call's clock through the real approval prompt" do
      pending = Lain::Approval::Parked::Queue::Pending.new(
        effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: {}),
        identity: Lain::Requester.main, clock: -> { 0 }
      )
      prompt = Lain::Frontend::ApprovalPolicy::Asked.new("[y/N] ", pending)

      Sync do |task|
        answered_when_published(task) { "y" }
        rail.read(:approval, prompt)
      end

      expect(pending.drawn_at).to eq(0)
    end
  end

  describe "several readers" do
    it "publishes their prompts one at a time, in the order they asked" do
      kinds = []

      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        task.async do
          2.times do |answered|
            pumped_until(task) { rail.published.generation == answered + 1 }
            kinds << rail.published.kind
            rail << line("answer", rail.published.generation)
          end
        end
        [question, approval].each(&:wait)
      end

      expect(kinds).to eq(%i[human approval])
    end

    it "never publishes the prompt of a reader stopped while it waited its turn" do
      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        waiting = task.async { rail.read(:approval, "[y/N] ") }
        pumped_until(task) { rail.published.generation == 1 }
        waiting.stop
        rail << line("mysql", 1)
        question.wait
      end

      expect(rail.published.generation).to eq(0)
    end

    # A prompt that cannot draw at once is said to be waiting, once, so the
    # human learns of it while another prompt holds the terminal.
    it "tells the screen a reader is waiting its turn, and nothing of the reader at the head" do
      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        pumped_until(task) { rail.published.generation == 1 }
        rail << line("mysql", 1)
        pumped_until(task) { rail.published.generation == 2 }
        rail << line("n", 2)
        [question, approval].each(&:wait)
      end

      expect(screen.said).to eq([[:queued, "[y/N] "]])
    end

    # Its line cannot be ended -- it never had one -- so the screen is told it
    # left, and a prompt with something to say says it whole.
    it "tells the screen a waiting reader left without its prompt ever being published" do
      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        waiting = task.async { rail.read(:approval, "[y/N] ") }
        pumped_until(task) { rail.published.generation == 1 }
        waiting.stop
        rail << line("mysql", 1)
        question.wait
      end

      expect(screen.said).to eq([[:queued, "[y/N] "], [:dropped, "[y/N] "]])
    end

    # Two readers asking the same question -- `/approve` and the watcher, about
    # one call -- are one arrival for the human.
    it "announces a prompt identical to one already in line only once" do
      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        pumped_until(task) { rail.published.kind == :human }
        waiting = Array.new(2) { task.async { rail.read(:approval, "[y/N] ") } }
        settle_for(task, 0.02)
        waiting.each(&:stop)
        question.stop
      end

      expect(screen.said.count([:queued, "[y/N] "])).to eq(1)
    end

    # Three calls parked at once: the head draws, and each of the others is
    # announced by name, however alike the calls read. Reads the Intake directly,
    # not through ApprovalPolicy#read_until_decided, which only wraps this call.
    it "announces every other call parked behind the one drawn" do
      notes = []
      summons = Class.new do
        define_method(:queue_prompt) { |text| text.queued { |note| notes << note } }
        def close_prompt(_text) = nil
        def drop_prompt(_text) = nil
      end.new
      summoning = described_class.new(screen: summons)
      prompts = %w[tu_1 tu_2 tu_3].map do |id|
        pending = Lain::Approval::Parked::Queue::Pending.new(
          effect: Lain::Effect::ToolCall.new(tool_use_id: id, name: "read_file", input: { "path" => id }),
          identity: Lain::Requester.main, clock: -> { 0 }
        )
        Lain::Frontend::ApprovalPolicy::Asked.new("[y/N] ", pending)
      end

      Sync do |task|
        readers = prompts.map { |prompt| task.async { summoning.read(:approval, prompt) } }
        pumped_until(task) { notes.size == 2 }
        readers.each(&:stop)
      end

      expect(notes).to match([include("tu_2"), include("tu_3")])
    end

    it "tells the screen nothing was dropped for a reader whose prompt was published" do
      Sync do |task|
        answered_when_published(task) { "n" }
        rail.read(:approval, "[y/N] ")
      end

      expect(screen.said).to be_empty
    end
  end

  # A plain chat at rest sits at `you>`, and an answer a run waits on would
  # otherwise wait behind it until the human pressed Enter. So an answer's
  # prompt takes the terminal from a `you>` nothing has been typed at, and
  # `you>` comes back once the answers ahead of it close. A `you>` the human
  # has started typing at keeps the terminal, and the answer waits its turn.
  describe "an answer arriving at an idle you>" do
    # The producer's word on whether anything has been typed at a prompt.
    def producer(untouched:)
      Struct.new(:untouched) do
        def sweep = nil
        def untouched?(_prompt) = untouched
      end.new(untouched)
    end

    it "preempts a you> nothing was typed at, draws at once, and republishes you> when it closes" do
      rail.attach(producer(untouched: true))
      kinds = answers = nil

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        pumped_until(task) { rail.published.kind == :approval }
        kinds = [rail.published.kind]
        rail << line("n", rail.published.generation)
        pumped_until(task) { rail.published.kind == :you }
        kinds << rail.published.kind
        rail << line("hello", rail.published.generation)
        answers = [approval.wait, you.wait]
      end

      expect(kinds).to eq(%i[approval you])
      expect(answers).to eq(%w[n hello])
      expect(screen.said).to be_empty
    end

    # A producer says a `you>` is untouched only once its line editor has opened
    # the read. An answer that arrived before that -- the moment `you>` came
    # back -- waits, and is let in when the producer says the read opened.
    it "preempts when the you> it waits behind opens with nothing typed" do
      editor = producer(untouched: false)
      rail.attach(editor)
      kinds = []

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        settle_for(task, 0.05)
        kinds << rail.published.kind
        editor.untouched = true
        rail.opened(rail.published)
        pumped_until(task) { rail.published.kind == :approval }
        kinds << rail.published.kind
        rail << line("n", rail.published.generation)
        approval.wait
        you.stop
      end

      expect(kinds).to eq(%i[you approval])
    end

    it "does not preempt on an opened you> with no answer waiting behind it" do
      rail.attach(producer(untouched: true))

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        drawn = rail.published
        rail.opened(drawn)
        settle_for(task, 0.05)
        expect(rail.open?(drawn)).to be(true)
        you.stop
      end
    end

    # What was held while `you>` stood aside is the line it answers with when
    # its turn comes back, ahead of anything typed at it afterwards.
    it "answers the returning you> with a line held while it stood aside" do
      rail.attach(producer(untouched: true))

      answer = Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        commandless = Class.new(String) { def takes?(line) = !line.start_with?("/") }.new("[y/N] ")
        approval = task.async { rail.read(:approval, commandless) }
        pumped_until(task) { rail.published.kind == :approval }
        asked = rail.published.generation
        rail << line("/goal off", asked)
        pumped_until(task) { rail.published.generation > asked }
        rail << line("n", rail.published.generation)
        approval.wait
        you.wait
      end

      expect(answer).to eq("/goal off")
    end

    # A preempting reader stopped before it drew -- its call decided elsewhere
    # -- still says how, having no line of its own to end.
    it "tells the screen a preempting reader left without drawing" do
      rail.attach(producer(untouched: true))

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        approval.stop
        settle_for(task, 0.05)
        you.stop
      end

      expect(screen.said).to include([:dropped, "[y/N] "])
    end

    it "waits behind a you> the human has typed at, and says so" do
      rail.attach(producer(untouched: false))
      kinds = []

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        settle_for(task, 0.05)
        kinds << rail.published.kind
        rail << line("half a sentence", rail.published.generation)
        you.wait
        pumped_until(task) { rail.published.kind == :approval }
        kinds << rail.published.kind
        rail << line("n", rail.published.generation)
        approval.wait
      end

      expect(kinds).to eq(%i[you approval])
      expect(screen.said).to eq([[:queued, "[y/N] "]])
    end

    it "waits when no producer can say nothing was typed" do
      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        settle_for(task, 0.05)
        expect(rail.published.kind).to eq(:you)
        rail << line("hi", rail.published.generation)
        you.wait
        pumped_until(task) { rail.published.kind == :approval }
        rail << line("n", rail.published.generation)
        approval.wait
      end
    end

    it "goes ahead of a you> already waiting behind another answer" do
      rail.attach(producer(untouched: true))
      kinds = []

      Sync do |task|
        question = task.async { rail.read(:human, "human> ") }
        pumped_until(task) { rail.published.kind == :human }
        you = task.async { rail.read(:you, "you> ") }
        approval = task.async { rail.read(:approval, "[y/N] ") }
        3.times do |answered|
          pumped_until(task) { rail.published.generation > answered }
          kinds << rail.published.kind
          rail << line("x", rail.published.generation)
        end
        [question, approval, you].each(&:wait)
      end

      expect(kinds).to eq(%i[human approval you])
    end

    it "keeps the line typed at the republished you> as that you>'s own" do
      rail.attach(producer(untouched: true))

      answer = Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        first_you = rail.published.generation
        task.async { rail.read(:approval, "[y/N] ") }
        pumped_until(task) { rail.published.kind == :approval }
        rail << line("n", rail.published.generation)
        pumped_until(task) { rail.published.kind == :you && rail.published.generation > first_you }
        rail << line("typed after", rail.published.generation)
        you.wait
      end

      expect(answer).to eq("typed after")
    end
  end

  describe "a reader stopped under its published prompt" do
    # A `[y/N]` whose call another surface decided, which is when it has
    # something to say as its line ends.
    let(:decided) do
      Class.new(String) do
        attr_accessor :elsewhere

        def closed = elsewhere && yield("-- decided by timeout: denied")
      end.new("[y/N] ")
    end

    it "withdraws the prompt and ends its line before the stop has finished unwinding" do
      Sync do |task|
        reading = task.async { rail.read(:approval, decided) }
        pumped_until(task) { rail.published.generation == 1 }
        drawn = rail.published
        decided.elsewhere = true
        reading.stop

        expect([rail.open?(drawn), screen.said]).to eq([false, [[:closed, "-- decided by timeout: denied"]]])
      end
    end

    it "ends no line for a prompt answered at it" do
      Sync do |task|
        answered_when_published(task) { "n" }
        rail.read(:approval, decided)
      end

      expect(screen.said).to be_empty
    end
  end

  describe "a countdown" do
    it "publishes the keys it accepts, so a producer that is not at the terminal can offer them" do
      keys = Sync do |task|
        reading = task.async { rail.read(:countdown, "closing in 30s", keys: { "c" => :cancel }) }
        published = rail.published.keys
        reading.stop
        published
      end

      expect(keys).to eq({ "c" => :cancel })
    end
  end

  describe "a signal" do
    it "reaches the routed sink at once, whether or not a prompt is open" do
      received = []
      rail.route(sink_over(received, ask_in_flight: false))

      rail << described_class::Signal.new(name: :cancel)

      expect(received).to eq([:cancel])
    end
  end

  describe "the approval key" do
    it "reaches the rail's cycle at once, with nothing published" do
      pressed = []
      cycling = described_class.new(screen:, on_cycle: -> { pressed << :cycled })

      cycling.cycle

      expect([pressed, cycling.published.kind]).to eq([%i[cycled], nil])
    end

    it "reaches it under an open prompt and leaves that prompt open for its answer" do
      pressed = []
      cycling = described_class.new(screen:, on_cycle: -> { pressed << :cycled })

      answer = Sync do |task|
        task.async do
          pumped_until(task) { cycling.published.kind == :approval }
          cycling.cycle
          cycling << line("y", cycling.published.generation)
        end
        cycling.read(:approval, "[y/N] ")
      end

      expect([pressed, answer]).to eq([%i[cycled], "y"])
    end

    it "says a cycle that failed rather than raising it into the producer that carried the key" do
      cycling = described_class.new(screen:, on_cycle: -> { raise Lain::Error, "journal closed" })

      expect([cycling.cycle, screen.said]).to eq([nil, [[:note, "approval did not change: journal closed"]]])
    end

    it "does nothing on a rail built with nowhere to send it" do
      expect(rail.cycle).to be_nil
    end
  end

  # `/stop` is the one line that is not a line. While an ask is in flight the
  # prompt in front of the human belongs to whatever that ask parked on, so a
  # producer has no other way to reach the run; at `you>` there is no ask, and
  # the command registered under that name says so. And where NO ask is in
  # flight -- a slash command driving its own work -- nothing is lifted at all,
  # because a line lifted into a sink with no run behind it just vanishes.
  describe "/stop typed at a prompt an ask parked on" do
    let(:received) { [] }

    def in_flight(ask_in_flight) = rail.route(sink_over(received, ask_in_flight:))

    it "leaves the rail as a stop signal rather than as the prompt's answer" do
      in_flight(true)

      answer = Sync do |task|
        reading = task.async { rail.read(:approval, "[y/N] run bash? ") }
        pumped_until(task, reason: "the prompt published") { rail.published.kind == :approval }
        rail << line("/stop", rail.published.generation)
        pumped_until(task, reason: "the signal routed") { received.any? }
        reading.stop
        reading.stopped? ? :still_asking : reading.wait
      end

      expect([received, answer]).to eq([[:stop], :still_asking])
    end

    it "is an ordinary line at you>, where there is never an ask to stop" do
      in_flight(true)

      answer = Sync do |task|
        answered_when_published(task) { "/stop" }
        rail.read(:you, "you> ")
      end

      expect([answer, received]).to eq(["/stop", []])
    end

    it "is held, not signalled, when a producer keeps it for the next you>" do
      in_flight(true)
      rail.hold("/stop")

      expect([rail.take_held, received]).to eq(["/stop", []])
    end

    # A slash command drives its own work outside every supervision, so the
    # rail's sink is the Null one. Lifting there would drop the line into
    # nothing: not the answer, not held, nothing said.
    it "stays a line with no ask in flight, so the prompt that cannot take it holds it" do
      in_flight(false)
      refusing = Class.new(String) { def takes?(text) = %w[y n].include?(text) }.new("[y/N] ")

      answer = Sync do |task|
        reading = task.async { rail.read(:approval, refusing) }
        pumped_until(task, reason: "the prompt published") { rail.published.kind == :approval }
        rail << line("/stop", rail.published.generation)
        pumped_until(task, reason: "the line held") { !screen.said.empty? }
        reading.stop
        reading.stopped? ? :still_asking : reading.wait
      end

      expect([received, rail.take_held, answer]).to eq([[], "/stop", :still_asking])
      expect(screen.said).to include([:held, "/stop"])
    end

    it "answers a prompt that takes anything when no ask is in flight" do
      in_flight(false)

      answer = Sync do |task|
        answered_when_published(task) { "/stop" }
        rail.read(:human, "human> ")
      end

      expect([answer, received]).to eq(["/stop", []])
    end
  end

  # Nothing published means no reader is waiting, so a line delivered then
  # would sit in the queue unseen until some later prompt: it is held instead,
  # where the chat looks for lines typed while it worked.
  describe "a line delivered while no prompt is published" do
    it "is held and said, and is the next you> line" do
      rail << line("hello", 0)

      expect([screen.said, Sync { rail.read(:you, "you> ") }]).to eq([[[:held, "hello"]], "hello"])
    end

    it "is taken by the chat as a held line" do
      rail << line("/goal off", 0)

      expect(rail.take_held).to eq("/goal off")
    end

    it "keeps its place in the history it reaches you> with" do
      history = Class.new do
        def remember(line) = (@lines ||= []) << line
        attr_reader :lines
      end.new
      recording = described_class.new(screen:, history:)
      recording << line("hello", 0)
      Sync { recording.read(:you, "you> ") }

      expect(history.lines).to eq(["hello"])
    end

    it "waits for you> when typed ahead of a command> the chat then reads" do
      rail << line("/approve", 0)

      answer = Sync do |task|
        answered_when_published(task) { "/next" }
        [rail.read(:command, "command> "), rail.take_held]
      end

      expect(answer).to eq(["/next", "/approve"])
    end

    it "is still a stop signal for /stop while an ask is in flight" do
      received = []
      rail.route(sink_over(received, ask_in_flight: true))
      rail << line("/stop", 0)

      expect([received, rail.take_held]).to eq([[:stop], nil])
    end

    context "with an ask in flight and notes to the agent" do
      let(:store) { Lain::Dag::Factory.store }
      let(:mailbox) do
        Lain::Context::Mailbox::Live.new(recipient: Lain::EventLog::ChainWriter.method(:correlation_of),
                                         observer: ->(_) {})
      end
      let(:received) { [] }
      let(:noting) do
        notes = Lain::CLI::HumanNotes.new(mailbox:, in_flight: -> { true })
        described_class.new(screen:, notes:).route(sink_over(received, ask_in_flight: true))
      end
      let(:timeline) do
        Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      end

      def noted = mailbox.capture(timeline).pending.map { |note| note.body.fetch("text") }

      it "posts prose as a note, says so, and holds nothing" do
        noting << line("prefer Syncthing", 0)

        expect([screen.said, noting.take_held, noted]).to eq([[[:human_note, "prefer Syncthing"]], nil,
                                                              ["prefer Syncthing"]])
      end

      it "still holds a slash command as the next prompt" do
        noting << line("/model", 0)

        expect([screen.said, noting.take_held, noted]).to eq([[[:held, "/model"]], "/model", []])
      end

      it "still stops on /stop, and posts no note" do
        noting << line("/stop", 0)

        expect([received, noting.take_held, noted]).to eq([[:stop], nil, []])
      end

      it "leaves a line typed at a parked human> prompt to be its answer" do
        answer = Sync do |task|
          reading = task.async { noting.read(:human, "human> ") }
          pumped_until(task, reason: "human> published") { noting.published.kind == :human }
          noting << line("Syncthing", noting.published.generation)
          reading.wait
        end

        expect([answer, noted]).to eq(["Syncthing", []])
      end
    end
  end

  describe "a line typed with nothing published and a command probe" do
    let(:probe_class) do
      Struct.new(:names, :reason, :ran) do
        def disposition(text)
          return Lain::Frontend::Intake::Disposition.new(:hold, text) unless names.include?(text)

          Lain::Frontend::Intake::Disposition.new(reason ? :refuse : :control, reason || text)
        end

        def run_now(text) = ran << text
      end
    end
    let(:refusal) { "no pending approvals" }
    let(:probe) { probe_class.new(["/approve"], refusal, []) }
    let(:rail) { described_class.new(screen:, commands: probe) }

    it "refuses a control command with nothing to act on, 13 times, and holds none" do
      13.times { rail << line("/approve", 0) }

      expect([screen.said.count { _1 == [:note, refusal] }, rail.held_lines]).to eq([13, []])
    end

    context "when there is something to answer" do
      let(:refusal) { nil }

      it "runs the command now and holds nothing" do
        rail << line("/approve", 0)

        expect([probe.ran, rail.held_lines, screen.said]).to eq([["/approve"], [], []])
      end
    end

    it "holds prose and any command that is not a control command" do
      rail << line("fix the bug", 0)
      rail << line("/model", 0)

      expect([rail.held_lines, probe.ran]).to eq([["fix the bug", "/model"], []])
    end

    it "acts on a control command a producer holds itself, instead of keeping it" do
      rail.hold("/approve")
      rail.hold("later")

      expect([screen.said, rail.held_lines]).to eq([[[:note, refusal], [:held, "later"]], ["later"]])
    end

    context "when something is waiting to be answered" do
      let(:refusal) { nil }

      it "runs a control command typed at an approval prompt that does not take it, and holds nothing" do
        asked = Class.new(String) { def takes?(line) = %w[y n].include?(line) }.new("[y/N] ")
        answer = Sync do |task|
          task.async do
            pumped_until(task) { rail.published.generation == 1 }
            rail << line("/approve", 1)
            pumped_until(task) { rail.published.generation == 2 }
            rail << line("n", 2)
          end
          rail.read(:approval, asked)
        end

        expect([answer, probe.ran, rail.held_lines]).to eq(["n", ["/approve"], []])
      end

      it "does not say what answers the prompt after a control command typed at it has run" do
        asked = Class.new(String) do
          def takes?(line) = %w[y n].include?(line)
          def refused = yield("y, n or hold answers the approval")
        end.new("[y/N] ")
        Sync do |task|
          task.async do
            pumped_until(task) { rail.published.generation == 1 }
            rail << line("/approve", 1)
            pumped_until(task) { rail.published.generation == 2 }
            rail << line("later", 2)
            pumped_until(task) { rail.published.generation == 3 }
            rail << line("n", 3)
          end
          rail.read(:approval, asked)
        end

        expect(screen.said).to eq([[:held, "later"], [:note, "y, n or hold answers the approval"]])
      end
    end

    it "takes a note before it asks the probe" do
      notes = instance_double(Lain::CLI::HumanNotes, take?: true)
      noting = described_class.new(screen:, notes:, commands: probe)
      noting << line("/approve", 0)

      expect([screen.said, probe.ran]).to eq([[[:human_note, "/approve"]], []])
    end
  end

  # Scenario: /held clear works while a slash command runs, and /inbox opens during a run.
  describe "a control command typed while a slash command runs, through the chat's own registry" do
    let(:replies) { instance_double(Lain::CLI::HumanReplies, drain_at_prompt: nil) }
    let(:human) { Struct.new(:unused) { def history_for(_tty) = Lain::Frontend::Intake::Unrecorded }.new }
    let(:bound) { [nil] }
    let(:chat) do
      Lain::CLI::Wiring::IntakeBuild.rail(tty: screen, human:, notes: Lain::CLI::HumanNotes::Null, on_cycle: -> {},
                                          surface: -> { Struct.new(:commands).new(bound.first) })
    end

    before do
      registry = Lain::CLI::Command::Registry.new([Lain::CLI::Command::Held.new(rail: chat), Lain::CLI::Command::Inbox.new])
      bound[0] = registry.bind(build_command_env(replies:))
    end

    it "drops a held line at once on /held clear" do
      Sync do
        chat << line("y", 0)
        chat << line("/held clear", 0)
      end

      expect([chat.held_lines, screen.said.last]).to eq([[], [:note, "dropped 1 held line"]])
    end

    it "opens the inbox now, not after the run" do
      Sync { chat << line("/inbox", 0) }

      expect(replies).to have_received(:drain_at_prompt)
      expect(chat.held_lines).to eq([])
    end
  end

  describe "#held_lines and #clear_held" do
    it "lists what is held without taking it, and clears all of it" do
      rail << line("one", 0)
      rail << line("two", 0)
      listed = rail.held_lines
      rail.clear_held

      expect([listed, rail.held_lines, rail.take_held]).to eq([%w[one two], [], nil])
    end
  end

  # History is what `you>` was answered with -- the line a recall at that
  # prompt would put back. An answer is not one, and a line read anywhere else
  # is held and reaches `you>` in its own time, so it is kept once, there.
  describe "the history it keeps" do
    let(:history) { Struct.new(:kept) { def remember(line) = kept << line }.new([]) }
    let(:rail) { described_class.new(screen:, history:) }

    def untouched_producer
      Struct.new(:untouched) do
        def sweep = nil
        def untouched?(_prompt) = true
      end.new(true)
    end

    it "keeps the line that answered you>, and nothing before it answered" do
      kept_before = nil
      Sync do |task|
        answered_when_published(task) { (kept_before = history.kept.dup) && "hello there" }
        rail.read(:you, "you> ")
      end

      expect([kept_before, history.kept]).to eq([[], ["hello there"]])
    end

    it "keeps no answer a run waited on" do
      Sync do |task|
        %i[approval human].each do |kind|
          answered_when_published(task) { "y" }
          rail.read(kind, "[y/N] ")
        end
      end

      expect(history.kept).to be_empty
    end

    it "keeps nothing read at command> or a countdown, whose lines reach you> held if they reach it at all" do
      Sync do |task|
        answered_when_published(task) { "/approve" }
        rail.read(:command, "command> ")
        answered_when_published(task) { "go on" }
        rail.read(:countdown, "closing in 30s")
      end

      expect(history.kept).to be_empty
    end

    it "keeps a line held at an answer's prompt once, when you> takes it" do
      Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation == 1 }
          rail << line("yes please", 0)
          pumped_until(task) { rail.published.generation == 2 }
          rail << line("n", 2)
        end
        rail.read(:approval, "[y/N] ")
      end
      kept_while_held = history.kept.dup

      expect([kept_while_held, rail.read(:you, "you> "), history.kept]).to eq([[], "yes please", ["yes please"]])
    end

    it "keeps a held line taken for you> between reads, once" do
      rail.hold("typed ahead")

      expect([rail.take_held, rail.take_held, history.kept]).to eq(["typed ahead", nil, ["typed ahead"]])
    end

    it "keeps the line a you> that stood aside comes back to exactly once" do
      rail.attach(untouched_producer)

      Sync do |task|
        you = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        commandless = Class.new(String) { def takes?(line) = !line.start_with?("/") }.new("[y/N] ")
        approval = task.async { rail.read(:approval, commandless) }
        pumped_until(task) { rail.published.kind == :approval }
        asked = rail.published.generation
        rail << line("/goal off", asked)
        pumped_until(task) { rail.published.generation > asked }
        rail << line("n", rail.published.generation)
        approval.wait
        you.wait
      end

      expect(history.kept).to eq(["/goal off"])
    end

    it "keeps nothing when the stream ends under you>" do
      Sync do |task|
        task.async do
          pumped_until(task) { rail.published.generation.positive? }
          rail << described_class::Eof.new
        end
        rail.read(:you, "you> ")
      end

      expect(history.kept).to be_empty
    end
  end

  describe "#gather" do
    it "asks every attached producer for what was typed while no prompt was drawn" do
      producer = Struct.new(:rail) { def sweep = rail.hold("/goal off") }.new(rail)
      rail.attach(producer)

      rail.gather

      expect(rail.take_held).to eq("/goal off")
      expect(screen.said).to eq([[:held, "/goal off"]])
    end

    it "asks nothing of a producer detached again" do
      producer = Struct.new(:rail) { def sweep = rail.hold("late") }.new(rail)
      rail.attach(producer)
      rail.detach(producer)

      rail.gather

      expect(rail.take_held).to be_nil
    end
  end

  describe "#interrupt" do
    def producer(typed:)
      Struct.new(:typed, :discards) do
        def sweep = nil
        def untouched?(_prompt) = !typed
        def typed?(_prompt) = typed
        def discard_draft = self.discards += 1
      end.new(typed, 0)
    end

    def arrived(name, generation) = Lain::CLI::Conductor::IdleSignals::Arrived.new(name:, generation:)

    # Reads at `kind` under a producer, and yields the generation drawn.
    def reading_at(kind, typed:)
      rail.attach(producer(typed:))
      Sync do |task|
        reading = task.async { rail.read(kind, "#{kind}> ") }
        pumped_until(task) { rail.published.kind == kind }
        yield(task, rail.published.generation).tap { reading.stop }
      end
    end

    # What the interrupt answered, and what is published once it has settled.
    def interrupted_at(kind, typed:)
      reading_at(kind, typed:) do |task, first|
        verdict = rail.interrupt(yield(first))
        settle_for(task, 0.05)
        [verdict, rail.published.kind, rail.published.generation > first]
      end
    end

    def sigint_at(kind, typed:, name: :sigint, behind: 0)
      interrupted_at(kind, typed:) { |generation| arrived(name, generation - behind) }
    end

    it "names the kinds that are line prompts" do
      expect(described_class::LINE_KINDS).to eq(%i[you command])
    end

    [[true, 1, "tells its producer to discard its draft over a typed line"],
     [false, 0, "leaves its producer alone over an empty line"]].each do |typed, discards, title|
      it title do
        held = producer(typed:)
        rail.attach(held)
        Sync do |task|
          reading = task.async { rail.read(:you, "you> ") }
          pumped_until(task) { rail.published.kind == :you }
          rail.interrupt(arrived(:sigint, rail.published.generation))
          reading.stop
        end

        expect(held.discards).to eq(discards)
      end
    end

    %i[you command].each do |kind|
      it "clears a line typed at #{kind}> and draws the prompt again" do
        expect(sigint_at(kind, typed: true)).to eq([:cleared, kind, true])
      end
    end

    it "passes a Ctrl-C over nothing typed, leaving the prompt as it is" do
      expect(sigint_at(:you, typed: false)).to eq([:passed, :you, false])
    end

    it "passes a signal that is not a Ctrl-C" do
      expect(sigint_at(:you, typed: true, name: :sigterm)).to eq([:passed, :you, false])
    end

    it "passes a Ctrl-C that arrived at a prompt no longer drawn" do
      expect(sigint_at(:you, typed: true, behind: 1)).to eq([:passed, :you, false])
    end

    it "passes a Ctrl-C at a prompt that is not a line prompt" do
      expect(sigint_at(:approval, typed: true)).to eq([:passed, :approval, false])
    end

    it "passes when no producer is attached" do
      verdict = nil
      Sync do |task|
        reading = task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }
        verdict = rail.interrupt(arrived(:sigint, rail.published.generation))
        reading.stop
      end

      expect(verdict).to eq(:passed)
    end
  end

  # A reader given a block settles it before leaving the line, so whatever the
  # block queues is there for the prompt waiting behind it.
  describe "#read with a block" do
    it "keeps a preempted you> unpublished until the block returns" do
      rail.attach(Struct.new(:untouched) do
        def sweep = nil
        def untouched?(_prompt) = true
      end.new(true))
      gate = Thread::Queue.new
      you = Thread.new { rail.read(:you, "you> ") }
      wait_until { rail.published.kind == :you }
      asked = Thread.new { rail.read(:human, "q? ") { |answer| gate.pop && answer } }
      wait_until { rail.published.kind == :human }
      rail << line("a", rail.published.generation)
      sleep 0.1
      unpublished_meanwhile = rail.published.kind
      gate << true

      expect([unpublished_meanwhile, asked.value, wait_until { rail.published.kind }]).to eq([nil, "a", :you])
    ensure
      [you, asked].compact.each(&:kill)
    end
  end

  # A queued review is asked as a run asks the human, on a thread of its own.
  describe "#offer" do
    let(:url) { "https://github.com/fuze/api/pull/12" }
    let(:asking) { "lain queue: /review #{url}  (Enter opens, x drops)" }
    # Built before any reader thread asks for it: a lazy let is memoized under a lock the main thread holds.
    let!(:request) do
      Lain::Review::Queue::Request.load({ "kind" => "pr", "url" => url },
                                        checkouts: Lain::Review::Queue::Checkouts.new(roots: []))
    end
    let(:producer) do
      Struct.new(:untouched, :discarded, :kept) do
        def sweep = nil
        def untouched?(_prompt) = untouched
        def typed?(_prompt) = !untouched
        def discard_draft = self.discarded = true
        def keep(text) = kept << text
      end.new(true, false, [])
    end
    let(:threads) { [] }

    before { rail.attach(producer) }
    after { threads.each(&:kill).each(&:join) }

    def typed(text) = line(text, rail.published.generation)

    def reading(&) = Thread.new(&).tap { |thread| threads << thread }

    def drawn(kind) = wait_until(reason: "#{kind} published") { rail.published.kind == kind && rail.published }

    def changing(*lines)
      Struct.new(:lines) do
        def review_line = lines.next
        def to_h = { "lines" => "changing" }
      end.new(lines.each)
    end

    context "with a chat at rest" do
      let!(:you) { reading { rail.read(:you, "you> ") }.tap { drawn(:you) } }

      it "asks before it runs" do
        offered = reading { rail.offer(request) }

        expect([drawn(:human).text, offered.join(0.2)]).to eq([asking, nil])
      end

      it "sends the rebuilt line on as if typed when Enter is pressed, says it was taken, and nothing of holding it" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("")

        expect([offered.value, you.value, screen.said]).to eq([:taken, "/review #{url}", []])
      end

      it "drops the offer when x is entered, says so, and the chat goes back to you>" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("x")
        drawn(:you)
        rail << typed("hello")

        expect([offered.value, you.value, rail.held_lines]).to eq([:dropped, "hello", []])
      end

      it "drops the offer at Ctrl-D, as x does" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << described_class::Eof.new

        expect([offered.value, drawn(:you).kind, you.alive?]).to eq([:dropped, :you, true])
      end

      it "answers nothing for an offer ended before the human answered, and sends nothing on" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail.end_offer

        expect([offered.value, drawn(:you).kind, you.alive?]).to eq([nil, :you, true])
      end

      it "still says dropped for an x that arrived just before the offer was ended" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("x")
        rail.end_offer

        expect(offered.value).to eq(:dropped)
      end

      it "still says taken for an Enter that arrived just before the offer was ended" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("")
        rail.end_offer

        expect([offered.value, you.value]).to eq([:taken, "/review #{url}"])
      end

      it "draws nothing for an offer made once offers have ended" do
        rail.end_offer

        expect([rail.offer(request), rail.published.kind, screen.said]).to eq([nil, :you, []])
      end

      it "asks again at anything else, and says what answers it" do
        offered = reading { rail.offer(request) }
        first = drawn(:human)
        rail << typed("maybe")
        again = wait_until { rail.published.generation > first.generation && rail.published }

        expect([again.kind, again.text, offered.alive?]).to eq([:human, asking, true])
        expect(screen.said).to eq([[:note, "lain queue: Enter opens /review #{url}, x drops it; " \
                                           "what you typed waits at you>"]])
      end

      it "puts what was typed at it back at you> as a draft when it is dropped, never sending it" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("maybe")
        wait_until { rail.published.kind == :human && rail.published.generation > 2 }
        rail << typed("x")
        offered.join(5)
        drawn(:you)

        expect([producer.kept, rail.held_lines, you.alive?]).to eq([["maybe"], [], true])
      end

      it "puts what was typed at it back as a draft when it opens, and sends only the review" do
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("maybe")
        wait_until { rail.published.kind == :human && rail.published.generation > 2 }
        rail << typed("")

        expect([offered.value, you.value, producer.kept, rail.held_lines])
          .to eq([:taken, "/review #{url}", ["maybe"], []])
      end

      it "puts the draft back before the you> behind the offer can return" do
        let_go = Thread::Queue.new
        producer.define_singleton_method(:keep) { |text| let_go.pop && (kept << text) }
        offered = reading { rail.offer(request) }
        drawn(:human)
        rail << typed("maybe")
        wait_until { rail.published.kind == :human && rail.published.generation > 2 }
        rail << typed("")
        sleep 0.1

        expect(rail.published.kind).to be_nil
        let_go << true
        expect([offered.value, you.value]).to eq([:taken, "/review #{url}"])
      end

      it "shows and sends exactly 1 line for a request that rebuilds a new one each time" do
        offered = reading { rail.offer(changing("/review a", "/review b")) }
        shown = drawn(:human).text
        rail << typed("")

        expect([shown, offered.value, you.value])
          .to eq(["lain queue: /review a  (Enter opens, x drops)", :taken, "/review a"])
      end

      it "shows a non-ASCII branch as the bytes it sends", :seam do
        Dir.mktmpdir("lain-offer") do |repo|
          root = File.realpath(repo)
          FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)
          branch = Lain::Review::Queue::Request.load(
            { "kind" => "branch", "branch" => "fé", "repo_root" => root },
            checkouts: Lain::Review::Queue::Checkouts.new(roots: [])
          )
          offered = reading { rail.offer(branch) }
          shown = drawn(:human).text
          rail << typed("")

          expect([shown, offered.value, you.value])
            .to eq(["lain queue: /review refs/heads/f\\é  (Enter opens, x drops)", :taken, "/review refs/heads/f\\é"])
        end
      end
    end

    context "when the chat ends offers" do
      def held_open(line)
        building = Thread::Queue.new
        release = Thread::Queue.new
        request = Object.new
        request.define_singleton_method(:to_h) { { "line" => line } }
        request.define_singleton_method(:review_line) { (building << true) && release.pop && line }
        [request, building, release]
      end

      it "neither builds nor yields an offer made after offers ended" do
        rail.end_offer
        request = Object.new.tap { |asked| def asked.review_line = raise("built after offers ended") }
        def request.to_h = { "line" => "never" }
        outcomes = []

        expect([rail.offer(request) { outcomes << _1 }, outcomes, rail.published.kind]).to eq([nil, [], nil])
      end

      it "never draws an offer whose line was still being built when offers ended" do
        request, building, release = held_open("/review b")
        offered = reading { rail.offer(request) }
        building.pop
        rail.end_offer
        release << true

        expect([offered.join(3)&.value, rail.published.kind]).to eq([nil, nil])
      end

      it "leaves the next prompt its own answer when offers end as a taken offer leaves the line" do
        ending = rail
        producer.define_singleton_method(:keep) { |_text| ending.end_offer }
        offered = reading { rail.offer(request) }
        first = drawn(:human)
        rail << typed("draft words")
        wait_until { rail.published.kind == :human && rail.published.generation > first.generation }
        rail << typed("")
        taken = offered.value
        approval = reading { rail.read(:approval, "[y/N] ") }
        drawn(:approval)
        rail << typed("y")

        expect([taken, approval.join(3)&.value]).to eq([:taken, "y"])
      end
    end

    context "with 1 offer already waiting" do
      let!(:pending) { reading { rail.offer(request) }.tap { drawn(:human) } }

      it "drops a second one with 1 note, leaving the first drawn" do
        first = rail.published
        second = rail.offer(changing("/review b"))

        expect([second, screen.said, rail.published])
          .to eq([nil, [[:note, "lain queue: a review is already offered, so this one was dropped"]], first])
      end

      it "drops the same request again with 1 note" do
        expect([rail.offer(request), screen.said])
          .to eq([nil, [[:note, "lain queue: that review is already offered"]]])
      end

      it "takes the next one once the first is answered" do
        rail << typed("x")
        pending.join(5)
        offered = reading { rail.offer(changing("/review b")) }

        expect(drawn(:human).text).to eq("lain queue: /review b  (Enter opens, x drops)")
        offered.kill
      end
    end

    # The sender is told what became of its offer as soon as the chat decides,
    # while the offer itself still waits on the human.
    context "when the caller asks what became of the offer" do
      let(:outcomes) { Thread::Queue.new }

      def offering(request) = reading { rail.offer(request) { |outcome| outcomes << outcome } }

      it "says held before the offer waits on the human" do
        offered = offering(request)

        expect([outcomes.pop(timeout: 5), drawn(:human).text, offered.alive?]).to eq([:held, asking, true])
      end

      it "says held for an offer waiting behind a prompt already in front of the human" do
        producer.untouched = false
        reading { rail.read(:approval, "[y/N] ") }
        drawn(:approval)
        offering(request)

        expect([outcomes.pop(timeout: 5), rail.published.kind]).to eq(%i[held approval])
      end

      it "says crowded for a second offer, and repeat for the same one again" do
        offering(request)
        drawn(:human)
        rail.offer(changing("/review b")) { |outcome| outcomes << outcome }
        rail.offer(request) { |outcome| outcomes << outcome }

        expect(Array.new(3) { outcomes.pop(timeout: 5) }).to eq(%i[held crowded repeat])
      end

      it "says nothing for a request whose line cannot be rebuilt, which raises, and takes the next offer" do
        refusing = Object.new.tap do |request|
          def request.to_h = { "kind" => "dirty" }
          def request.review_line = raise(Lain::Review::Queue::Request::Refused.new("repo_root", "has no changes"))
        end

        expect { rail.offer(refusing) { |outcome| outcomes << outcome } }
          .to raise_error(Lain::Review::Queue::Request::Refused, /repo_root/)
        offering(request)
        expect([outcomes.pop(timeout: 5), outcomes.size]).to eq([:held, 0])
      end
    end

    %i[approval human].each do |kind|
      context "with #{kind == :human ? "a question" : "an approval"} waiting" do
        it "leaves the waiting prompt untouched and its typed text kept, and waits behind it, saying so" do
          producer.untouched = false
          asked = reading { rail.read(kind, "[y/N] ") }
          waiting = drawn(kind)
          offered = reading { rail.offer(request) }
          expect(offered.join(0.2)).to be_nil

          expect([rail.published, producer.discarded, screen.said]).to eq([waiting, false, [[:queued, asking]]])
          rail << typed("y")
          expect([asked.value, drawn(:human).text]).to eq(["y", asking])
        end

        it "answers nothing for an offer ended while it waits behind, leaving the waiting prompt drawn" do
          producer.untouched = false
          asked = reading { rail.read(kind, "[y/N] ") }
          waiting = drawn(kind)
          offered = reading { rail.offer(request) }
          wait_until(reason: "the offer queued") { screen.said.include?([:queued, asking]) }
          rail.end_offer

          expect([offered.value, rail.published, asked.alive?]).to eq([nil, waiting, true])
        end
      end
    end
  end

  describe "Parts" do
    subject(:parts) do
      Lain::Frontend::Intake::Parts.new(lead: "agent asks:", call: "bash(ls)", reasons: [reason], tail: "[y/N] ")
    end

    let(:reason) { Lain::Approval::Parked::Queue::Reason.own("the judge deferred this") }

    it "is the frame's own field, with string keys" do
      expect(parts.frame).to eq({ "parts" => { "lead" => "agent asks:", "call" => "bash(ls)",
                                               "reasons" => [reason.to_s], "tail" => "[y/N] " } })
    end

    it "holds each reason as a frozen string, so a real Reason does not break sharing" do
      expect([parts.reasons.map(&:class), Ractor.shareable?(parts)]).to eq([[String], true])
    end
  end

  describe "NoParts" do
    it "puts nothing on the wire and is shareable" do
      expect([Lain::Frontend::Intake::NoParts.frame, Ractor.shareable?(Lain::Frontend::Intake::NoParts)])
        .to eq([{}, true])
    end

    it "is what a prompt has when its text brought none" do
      Sync do |task|
        task.async { rail.read(:you, "you> ") }
        pumped_until(task) { rail.published.kind == :you }

        expect(rail.published.parts).to be(Lain::Frontend::Intake::NoParts)
        task.stop
      end
    end
  end
end
