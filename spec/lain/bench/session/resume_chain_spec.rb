# frozen_string_literal: true

require "json"

# T3: the chain-seam integrity property is fold MEMBERSHIP, not head equality.
# `resumed_from.head` may be ANY digest verified while rebuilding the prior
# file -- a fork from an ancestor head chains to a digest the prior file
# recorded but did not end on. Membership means "a verified turn RECORDED IN
# the prior file, at any fold position", NOT "ancestor of the file's final
# rebuilt head": a parent that later rewinds below a fork point must not
# render children forked above it unloadable. `Timeline#checkout` verifies
# nothing by itself -- the verification is the fold-membership check, which
# re-committed every recorded turn to its content address.
RSpec.describe Lain::Bench::Session::ResumeChain do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:loader) { Lain::Bench::Session::Loader }

  def text(body) = [{ "type" => "text", "text" => body }]

  # The same JSON round-trip a real file gives a Loader (loader_spec's idiom).
  def roundtrip(records) = records.map { |record| JSON.parse(JSON.generate(record)) }

  def open_header(resumed_from: nil)
    header = Lain::SessionRecord.header(context:, toolset:, workspace: Lain::Workspace.empty, head: nil)
    resumed_from.nil? ? header : header.merge("resumed_from" => resumed_from)
  end

  def turn_records(timeline) = timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) }

  describe "an ancestor-head chain (a fork below the prior file's final head)" do
    let(:prior) { Lain::Timeline.empty(store: Lain::Store.new) }
    let(:fork_point) do
      prior.commit(role: :user, content: text("first")).commit(role: :assistant, content: text("ack"))
    end
    let(:parent_head) { fork_point.commit(role: :user, content: text("second")) }
    let(:a_records) { roundtrip([open_header] + turn_records(parent_head)) }
    let(:resolver) { ->(basename) { basename == "a.ndjson" ? a_records : raise("unexpected #{basename}") } }

    def forked_header(head) = open_header(resumed_from: { "file" => "a.ndjson", "head" => head })

    it "loads a child chained to a mid-file digest: the prior chain checks out AT the fork point" do
      child = fork_point.commit(role: :assistant, content: text("forked continuation"))
      b_records = roundtrip([forked_header(fork_point.head_digest), Lain::SessionRecord.turn(child.head)])

      loaded = loader.new(b_records, resolve: resolver).recording

      expect(loaded.timeline.to_a.map(&:digest)).to eq(child.to_a.map(&:digest))
      expect(loaded.timeline.head_digest).to eq(child.head_digest)
    end

    it "keeps the parent's post-fork tail OUT of the child's chain" do
      child = fork_point.commit(role: :assistant, content: text("forked continuation"))
      b_records = roundtrip([forked_header(fork_point.head_digest), Lain::SessionRecord.turn(child.head)])

      loaded = loader.new(b_records, resolve: resolver).recording

      expect(loaded.timeline.to_a.map(&:digest)).not_to include(parent_head.head_digest)
    end

    it "still loads the ordinary head-equality chain (the common, unforked case)" do
      child = parent_head.commit(role: :assistant, content: text("plain resume"))
      b_records = roundtrip([forked_header(parent_head.head_digest), Lain::SessionRecord.turn(child.head)])

      loaded = loader.new(b_records, resolve: resolver).recording

      expect(loaded.timeline.to_a.map(&:digest)).to eq(child.to_a.map(&:digest))
    end

    it "still refuses a digest the prior file never recorded, naming it and the rebuilt head" do
      wrong = "blake3:#{"0" * 64}"
      child = fork_point.commit(role: :assistant, content: text("forked continuation"))
      b_records = roundtrip([forked_header(wrong), Lain::SessionRecord.turn(child.head)])

      expect { loader.new(b_records, resolve: resolver).recording }
        .to raise_error(Lain::Bench::Session::Corrupt) do |error|
          expect(error.message).to include(wrong, parent_head.head_digest)
        end
    end

    it "refuses a tampered turn UNDER the fork point -- membership never skips content verification" do
      child = fork_point.commit(role: :assistant, content: text("forked continuation"))
      tampered = a_records.map(&:dup)
      target = tampered.find { |record| record["type"] == "turn" }
      target["content"] = text("forged")
      tampered_resolver = ->(_basename) { tampered }
      b_records = roundtrip([forked_header(fork_point.head_digest), Lain::SessionRecord.turn(child.head)])

      expect { loader.new(b_records, resolve: tampered_resolver).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /content address/)
    end
  end

  # The membership set is the digests verified during the FOLD, at any fold
  # position -- pinned at the seam with a stubbed prior loader whose final
  # head does NOT descend from the fork point (the shape a post-/rewind
  # parent file will produce), so this property cannot silently regress into
  # "ancestor of the rebuilt head".
  describe "membership is the fold check, not ancestry of the final head" do
    let(:store) { Lain::Store.new }
    let(:trunk) { Lain::Timeline.empty(store:).commit(role: :user, content: text("one")) }
    let(:abandoned) { trunk.commit(role: :assistant, content: text("above the rewind")) }
    let(:rewound) { trunk.commit(role: :assistant, content: text("the other branch")) }

    def chain_for(prior_loader)
      factory = double("loader factory", new: prior_loader)
      described_class.new(resumed_from: { "file" => "a.ndjson", "head" => abandoned.head_digest },
                          context_factory: nil, resolve: ->(_basename) { [] }, loader_factory: factory)
    end

    it "checks out a recorded fold position even when the final head abandoned it" do
      prior_loader = instance_double(Lain::Bench::Session::Loader, timeline: rewound)
      allow(prior_loader).to receive(:on_chain?) { |digest| digest == abandoned.head_digest }

      expect(chain_for(prior_loader).prior_timeline.head_digest).to eq(abandoned.head_digest)
    end

    it "refuses a digest outside the fold, naming both it and the rebuilt head" do
      prior_loader = instance_double(Lain::Bench::Session::Loader, timeline: rewound)
      allow(prior_loader).to receive(:on_chain?).and_return(false)

      expect { chain_for(prior_loader).prior_timeline }
        .to raise_error(Lain::Bench::Session::Corrupt) do |error|
          expect(error.message).to include(abandoned.head_digest, rewound.head_digest)
        end
    end
  end
end
