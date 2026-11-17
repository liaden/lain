# frozen_string_literal: true

require "async"

RSpec.describe Lain::CLI::Wiring::Askers do
  let(:store) { Lain::Dag::Factory.store }
  let(:timeline) do
    Lain::Dag::Factory.timeline(store:)
                      .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:askers) do
    described_class.new(human: Lain::CLI::Human.new(kind: :terminal),
                        observer: Lain::EventLog::ChainWriter::Null.new)
  end

  # A forgotten Human must be loud: defaulted, a headless run would announce
  # questions to a queue nobody drains.
  it "refuses to build without the Human who answers" do
    expect { described_class.new(observer: Lain::EventLog::ChainWriter::Null.new) }
      .to raise_error(ArgumentError, /human/)
  end

  # Only a human away from the terminal tells "can be asked" from "is at the
  # terminal", and the asker follows the first.
  it "enrols a real asker for a human who answers away from the terminal" do
    remote = described_class.new(observer: Lain::EventLog::ChainWriter::Null.new,
                                 human: Lain::CLI::Human.new(kind: :remote))

    expect(remote.enrol(timeline).asker.class).to be(Lain::Tools::AskHuman)
  end

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

  it "enrols a child's asker under its spawn, so its question's wait names it" do
    journal = []
    askers = described_class.new(human: Lain::CLI::Human.new(kind: :terminal),
                                 observer: Lain::EventLog::ChainWriter::Null.new, journal:)
    invocation = Lain::Tool::Invocation.new(context: Lain::Session::Null.instance)
    asker = askers.enrol(timeline, agent: "reviewer", spawn: "blake3:child").asker

    Sync do |task|
      run = task.async { asker.call({ "question" => "which file?" }, invocation) }
      task.yield
      asker.reply("a.rb", asker.last_question.digest)
      run.wait
    end

    expect(journal.grep(Lain::Telemetry::AwaitingHuman)).to contain_exactly(have_attributes(spawn: "blake3:child"))
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
      askers = described_class.new(human: Lain::CLI::Human.new(kind: :terminal),
                                   observer: Lain::EventLog::ChainWriter::Null.new, journal:,
                                   epic_slug: -> { slug })
      slug = "nyotes"

      expect(answer_through(askers)).to contain_exactly(have_attributes(epic_slug: "nyotes", requester: "reviewer"))
    end

    it "names no epic for a run without one" do
      askers = described_class.new(human: Lain::CLI::Human.new(kind: :terminal),
                                   observer: Lain::EventLog::ChainWriter::Null.new, journal:)

      expect(answer_through(askers)).to contain_exactly(have_attributes(epic_slug: nil))
    end
  end
end
