# frozen_string_literal: true

RSpec.describe Lain::Forge::Gh::ReviewRequest do
  let(:nodes) { JSON.parse(File.read("spec/fixtures/gh/review_requests.json")).dig("data", "search", "nodes") }
  let(:requests) do
    nodes.filter_map do |node|
      described_class.from_node(node, viewer: "me", teams: Set["acme/platform"])
    end
  end

  it "names a direct request, the time it was asked of me, and my last review" do
    expect(requests.first).to have_attributes(
      repo: "acme/api", number: 11, title: "Direct ask", url: "https://github.com/acme/api/pull/11",
      head_sha: "aaa111", author: "alice", paths: %w[lib/a.rb spec/a_spec.rb],
      requested_at: Time.utc(2026, 11, 11, 10, 30), via: :direct, team: nil, my_last_review: "old000"
    )
  end

  it "names the team slug of a team request, with no review of mine" do
    expect(requests[1]).to have_attributes(via: :team, team: "acme/platform", my_last_review: nil,
                                           requested_at: Time.utc(2026, 11, 12, 8))
  end

  it "marks a code-owner request and treats a review with no commit as none" do
    expect(requests[2]).to have_attributes(via: :code_owner, team: nil, my_last_review: nil)
  end

  it "keeps the commit of my review after a force-push replaced it as head" do
    expect(requests.last).to have_attributes(number: 15, head_sha: "eee555", my_last_review: "gone999")
  end

  it "drops a draft" do
    expect(requests.map(&:number)).to eq([11, 12, 13, 15])
  end

  it "times a team request by my organization's event, not a same-named team's elsewhere" do
    expect(requests[1].requested_at).to eq(Time.utc(2026, 11, 12, 8))
  end

  it "takes the newer of two requests of me, and my review whoever reviewed first" do
    expect(requests.first).to have_attributes(requested_at: Time.utc(2026, 11, 11, 10, 30), my_last_review: "old000")
  end

  describe "a request that names teams" do
    def node_asking(*teams)
      { "number" => 1, "isDraft" => false, "repository" => { "nameWithOwner" => "o/r" },
        "reviewRequests" => { "nodes" => teams.map do |org, slug|
          { "requestedReviewer" => { "__typename" => "Team", "slug" => slug, "organization" => { "login" => org } } }
        end } }
    end

    it "names my team when another team is listed before it" do
      node = node_asking(%w[acme other], %w[acme platform])

      expect(described_class.from_node(node, viewer: "me", teams: Set["acme/platform"]))
        .to have_attributes(via: :team, team: "acme/platform")
    end

    it "tells two organizations' same-named teams apart" do
      node = node_asking(%w[globex platform], %w[acme platform])

      expect(described_class.from_node(node, viewer: "me", teams: Set["acme/platform"]).team).to eq("acme/platform")
      expect(described_class.from_node(node_asking(%w[globex platform]), viewer: "me", teams: Set["acme/platform"]))
        .to be_nil
    end

    it "drops a request that names no team of mine" do
      expect(described_class.from_node(node_asking(%w[acme other]), viewer: "me", teams: Set.new)).to be_nil
    end

    it "never lets a missing viewer match a team node" do
      expect(described_class.from_node(node_asking(%w[acme platform]), viewer: nil, teams: Set.new)).to be_nil
    end
  end

  describe "#paths_truncated" do
    it "is false when every changed path came back" do
      expect(requests.first.paths_truncated).to be(false)
    end

    it "is true when the file count passes the paths returned" do
      node = nodes.first.merge("files" => { "totalCount" => 150, "nodes" => Array.new(100) { { "path" => "f" } } })

      expect(described_class.from_node(node, viewer: "me", teams: Set.new).paths_truncated).to be(true)
    end
  end

  describe ".from_match" do
    let(:unasked) { nodes.first.merge("reviewRequests" => { "nodes" => [] }) }
    let(:match) { described_class.from_match(unasked, viewer: "me") }

    it "names a PR that asks nothing of me, with no team or request time and my review kept" do
      expect(match).to have_attributes(number: 11, via: :match, team: nil, requested_at: nil,
                                       my_last_review: "old000", paths: %w[lib/a.rb spec/a_spec.rb])
    end

    it "drops a draft" do
      expect(described_class.from_match(nodes.fetch(3), viewer: "me")).to be_nil
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(match)).to be(true)
    end
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(requests.first)).to be(true)
  end
end
