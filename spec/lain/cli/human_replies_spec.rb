# frozen_string_literal: true

require "async"

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
  let(:conductor) { double("conductor") }
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
end
