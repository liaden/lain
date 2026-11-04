# frozen_string_literal: true

require "async"

RSpec.describe Lain::CLI::Wiring::Askers do
  let(:store) { Lain::Dag::Factory.store }
  let(:timeline) do
    Lain::Dag::Factory.timeline(store:)
                      .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:askers) { described_class.new(observer: Lain::EventLog::ChainWriter::Null.new) }

  # {Tools::AskHuman}'s `parent:` is the idiom {Lain.live} generalizes: the
  # toolset is built before the Agent whose Timeline it asks against exists,
  # so the wiring hands a thunk and the read happens at the instant a question
  # is actually asked, not at enrolment.
  it "reads a callable timeline source lazily, at ask time rather than at enrol time" do
    called = false
    source = lambda do
      called = true
      timeline
    end

    asker = askers.enrol(source).asker
    expect(called).to be(false)

    Sync { asker.ask("which file?") }

    expect(called).to be(true)
  end

  describe "recording an answered question" do
    let(:journal) { [] }
    let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

    def answer_through(askers)
      asker = askers.enrol(timeline, agent: "reviewer").asker
      Sync do |task|
        run = task.async { asker.call({ "question" => "owner blessings?" }, invocation) }
        task.yield
        asker.reply("yes, both", asker.last_question.digest)
        run.wait
      end
      journal.grep(Lain::Telemetry::QuestionAnswered)
    end

    it "names the epic the run has mounted, read when the answer lands" do
      slug = nil
      askers = described_class.new(observer: Lain::EventLog::ChainWriter::Null.new, journal:,
                                   epic_slug: -> { slug })
      slug = "nyotes"

      expect(answer_through(askers)).to contain_exactly(have_attributes(epic_slug: "nyotes", requester: "reviewer"))
    end

    it "names no epic for a run without one" do
      askers = described_class.new(observer: Lain::EventLog::ChainWriter::Null.new, journal:)

      expect(answer_through(askers)).to contain_exactly(have_attributes(epic_slug: nil))
    end
  end
end
