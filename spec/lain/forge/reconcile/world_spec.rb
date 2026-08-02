# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lain::Forge::Reconcile::World do
  let(:heads) { instance_double(Lain::Forge::Promotion::Remote) }
  let(:github) { instance_double(Lain::Forge::Gh) }
  let(:world) { described_class.new(heads:, github:) }

  it "answers both ref questions from one remote snapshot" do
    allow(heads).to receive(:heads).and_return("refs/heads/epic/demo/a1" => "abc123")

    expect(world.ref_exists?("refs/heads/epic/demo/a1")).to be(true)
    expect(world.sha_of("refs/heads/epic/demo/a1")).to eq("abc123")
    expect(heads).to have_received(:heads).once
  end

  it "finds a pull request by its head branch" do
    response = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => [{ "number" => 17 }] })
    allow(github).to receive(:pr_list).with(head: "epic/demo/a1")
                                      .and_return(response)

    expect(world.pr_for(head: "epic/demo/a1")).to eq("number" => 17)
  end

  it "returns nil when GitHub reports no pull request for the head" do
    allow(github).to receive(:pr_list).with(head: "epic/demo/a1")
                                      .and_return(Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => [] }))

    expect(world.pr_for(head: "epic/demo/a1")).to be_nil
  end

  it "refuses an ambiguous pull-request observation" do
    allow(github).to receive(:pr_list).with(head: "epic/demo/a1")
                                      .and_return(Lain::Forge::Gh::Answer.new(ok: true,
                                                                              detail: { "value" => [
                                                                                { "number" => 17 }, { "number" => 18 }
                                                                              ] }))

    expect { world.pr_for(head: "epic/demo/a1") }.to raise_error(Lain::Forge::Unobservable, /2 matches/)
  end

  it "turns an unreadable GitHub observation into an unaddressable reconcile result" do
    allow(github).to receive(:pr_view).with(ref: 17, fields: ["state"])
                                      .and_return(Lain::Forge::Gh::Answer.new(ok: false,
                                                                              detail: { "reason" => "refused" }))

    expect { world.pr_state(17) }.to raise_error(Lain::Forge::Unobservable, /pull request 17/)
  end

  it "turns a non-object pull-request response into an unaddressable reconcile result" do
    allow(github).to receive(:pr_view).with(ref: 17, fields: ["state"])
                                      .and_return(Lain::Forge::Gh::Answer.new(ok: true,
                                                                              detail: { "value" => ["OPEN"] }))

    expect { world.pr_state(17) }.to raise_error(Lain::Forge::Unobservable, /non-object/)
  end
end
