# frozen_string_literal: true

require "async"

# The asker a run wires when nobody is at the terminal. It went unspecced for a
# long time, and closing that gap matters: the EOF door and this one are the
# same fact reached two ways -- no human will answer -- so the two refusals have
# to keep saying the same thing, and only a spec on each can notice when one of
# them stops.
#
# What is pinned here is the DOCTRINE, not the sentence: that the call comes
# back rather than parking, that it comes back as an error in the tool's own
# name with an instruction the model can act on, and that nothing at all is
# written -- no Q, nothing outstanding, not one event in the Store.
RSpec.describe Lain::Tools::AskHuman::Unattended do
  let(:store) { Lain::Dag::Factory.store }
  let(:parent) do
    Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:tool) { described_class.new(parent:) }

  it "refuses the call rather than parking on an answer that cannot come" do
    Sync do |task|
      result = task.with_timeout(1) { tool.call({ "question" => "which db?" }, invocation) }

      expect(result).to be_error
      expect(result.content).to eq(described_class::REFUSAL)
    end
  end

  # The two halves a refusal needs to be actionable: WHOSE capability failed
  # (the tool's own name, so the model does not read the gap as an absent
  # tool) and what to do instead. A refusal that only says "no" invites the
  # same call again.
  it "names the tool and says what to do instead" do
    expect(described_class::REFUSAL).to include("ask_human")
      .and include("no answer will ever come back")
      .and include("Decide with what you have, or stop")
  end

  it "writes nothing at all -- no question, nothing outstanding, no event" do
    parent # force the chain into the Store before counting
    before = store.size

    Sync { tool.call({ "question" => "which db?" }, invocation) }

    expect(tool.pending?).to be(false)
    expect(tool.last_question).to be_nil
    expect(store.size).to eq(before)
  end

  describe "#ask, the door a gate knocks on" do
    it "answers at once with a deny in REFUSAL's words, and writes nothing" do
      parent
      before = store.size
      asked = tool.ask("approve the plan?")

      expect(asked.await.verdict).to be_denied
      expect(asked.await.verdict.note).to eq(described_class::REFUSAL)
      expect(asked.await.surface).to eq(described_class::SURFACE)
      expect([tool.pending?, store.size]).to eq([false, before])
    end

    it "keeps NO_MAILBOX's words for a spawn with no mailbox" do
      mailless = described_class.new(parent:, text: described_class::NO_MAILBOX)

      expect(mailless.ask("approve?").await.verdict.note).to eq(described_class::NO_MAILBOX)
    end

    it "never tells the desk" do
      told = []
      noisy = described_class.new(parent:, notify: ->(question) { told << question })
      noisy.ask("approve?")

      expect(told).to be_empty
    end
  end
end
