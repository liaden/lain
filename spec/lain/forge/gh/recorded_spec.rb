# frozen_string_literal: true

# Forge::Gh::Recorded is the replay half of the pair: the same four verbs,
# answered out of journaled `forge_outcome` records instead of out of a
# subprocess. It is Effect::Handler::Recorded's doctrine applied to the forge
# tier -- a call it has no recording for is DECLINED, never invented, so a replay
# miss falls through to whatever is behind it or refuses loudly.
#
# The recording driving the parity group is a real one: the live executor is run
# under Forge::Journaled and its journal lines are what get replayed.
RSpec.describe Lain::Forge::Gh::Recorded do
  let(:live) { Lain::Forge::Gh.new(shell_out_factory: GhParity.factory) }
  let(:entries) { GhParity.recorded_journal(Lain::Forge::Gh.new(shell_out_factory: GhParity.factory)) }

  it_behaves_like "a gh executor" do
    # `inner: live` is what carries the OBSERVATION verbs: pr_view and
    # merge_state ask a question rather than cause an effect, so no forge_outcome
    # keys them and there is nothing here to replay.
    let(:executor) { described_class.from_journal(entries, inner: live) }
  end

  describe "replaying" do
    subject(:recorded) { described_class.from_journal(entries, inner: live) }

    it "answers a recorded pr_create with exactly the outcome that was journaled" do
      answer = recorded.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                  title: GhParity::TITLE, body: GhParity::BODY)

      expect(answer).to be_ok
      expect(answer.value).to eq(GhParity::NUMBER)
      expect(answer.detail).to include("epic_slug" => GhParity::EPIC_SLUG, "issue_id" => GhParity::ISSUE_ID)
    end

    # The address is the params, not the whole call: a replay with a different
    # title is the SAME attempt at the same pull request.
    it "keys on the address only, so a differently-worded retry still replays" do
      answer = recorded.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                  title: "a better title", body: "a better body")

      expect(answer.value).to eq(GhParity::NUMBER)
    end

    it "replays a journaled refusal as a refusal, not as a fresh attempt" do
      answer = recorded.pr_create(base: GhParity::BASE, head: GhParity::REFUSED_HEAD,
                                  title: GhParity::TITLE, body: GhParity::BODY)

      expect(answer).not_to be_ok
      expect(answer.detail["stderr"]).to include("No commits between")
    end

    it "knows what it holds a recording for" do
      expect(recorded.recorded?(action: Lain::Forge::PR_MERGE, params: { "number" => GhParity::NUMBER })).to be(true)
      expect(recorded.recorded?(action: Lain::Forge::PR_MERGE, params: { "number" => 9 })).to be(false)
    end
  end

  describe "declining a miss" do
    it "falls through to the inner executor rather than inventing a success" do
      recorded = described_class.new(outcomes: {}, inner: live)

      answer = recorded.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                  title: GhParity::TITLE, body: GhParity::BODY)

      expect(answer.value).to eq(GhParity::NUMBER)
    end

    it "refuses loudly when nothing is behind the recording" do
      recorded = described_class.new(outcomes: {})

      expect { recorded.pr_merge(number: 9) }
        .to raise_error(described_class::Declined, /pr_merge/)
    end

    it "refuses an observation it can never key on, when nothing is behind it" do
      expect { described_class.new(outcomes: {}).merge_state(number: 9) }
        .to raise_error(described_class::Declined, /merge_state/)
    end
  end

  describe "building from a journal" do
    it "skips lines that are not forge outcomes" do
      lines = ["not json at all\n", %({"type":"doc_written","kind":"epic"}\n), *entries]

      expect(described_class.from_journal(lines, inner: live).recorded?(action: Lain::Forge::PR_MERGE,
                                                                        params: { "number" => GhParity::NUMBER }))
        .to be(true)
    end

    # Two attempts at one address share an intent_id (Forge::Intent's address
    # rule), so a replay keyed on it can hold only one. The LAST outcome is the
    # one that settled the address, and it is the one a resume must see.
    it "lets the last outcome for an address win" do
      first = Lain::Forge::Outcome.new(intent_id: id_for_merge, ok: false, detail: { "value" => nil })
      last = Lain::Forge::Outcome.new(intent_id: id_for_merge, ok: true, detail: { "value" => 99 })
      recorded = described_class.from_journal([first.to_journal, last.to_journal])

      expect(recorded.pr_merge(number: GhParity::NUMBER).value).to eq(99)
    end

    it "refuses an outcomes hash carrying something that is not an Outcome" do
      expect { described_class.new(outcomes: { "blake3:abc" => "an ok, honest" }) }
        .to raise_error(ArgumentError, /Outcome/)
    end

    def id_for_merge
      Lain::Forge::Intent.id_for(action: Lain::Forge::PR_MERGE, params: { "number" => GhParity::NUMBER })
    end
  end
end
