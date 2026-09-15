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
    end.new
  end

  let(:rail) { described_class.new(screen:) }

  def line(text, generation) = described_class::Line.new(text:, generation:)

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

  describe "a signal" do
    it "reaches the routed sink at once, whether or not a prompt is open" do
      received = []
      rail.route(Struct.new(:received) { def signal(name) = received << name }.new(received))

      rail << described_class::Signal.new(name: :cancel)

      expect(received).to eq([:cancel])
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
