# frozen_string_literal: true

RSpec.describe Lain::CLI::Wiring::EditorSeams do
  let(:store) { Object.new }
  let(:agent) { instance_double(Lain::Agent, timeline: instance_double(Lain::Ext::Timeline, store:)) }
  let(:feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:mount) { instance_double(Lain::CLI::EpicMount, homes: :homes) }
  let(:forks) { -> { {} } }
  let(:seams) do
    described_class.new(nvim: :nvim, agent:, session: :session, epic: :epic, mount:, feed:, forks:)
  end

  it "names what the editor is built from, under the keywords Repl#run takes" do
    expect(seams.to_h).to eq(nvim: :nvim, store:, session: :session, epic: :epic, epic_docs: :homes, forks:)
  end

  it "binds the run's store to the HUD feed, which is why it is read from the agent here" do
    seams.to_h

    expect(feed).to have_received(:bind_store).with(store)
  end
end
