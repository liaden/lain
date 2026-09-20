# frozen_string_literal: true

require "async"

RSpec.describe Lain::Frontend::InputRail do
  # What the rail tells the human, recorded rather than drawn.
  let(:screen) do
    Class.new do
      def initialize = @said = []
      attr_reader :said

      def render_held(text) = @said << [:held, text]

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

  # A producer that answers each published prompt as a human at it would.
  def answered_when_published(task, generation: nil)
    task.async do
      pumped_until(task, reason: "a prompt published") { rail.published.generation.positive? }
      prompt = rail.published
      rail << line(yield(prompt), generation || prompt.generation)
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
end
