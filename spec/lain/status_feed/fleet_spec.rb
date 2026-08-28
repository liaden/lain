# frozen_string_literal: true

# The fleet as {Lain::StatusFeed} publishes it: the digest of every DISTINCT
# `:spawn` the tee has carried. Keyed by digest, so a journal replay
# redelivering one real spawn never grows a phantom second entry -- and keyed
# by CONTENT address, so two separately constructed Event objects naming the
# same spawn are one member, which is the whole point of content addressing.
#
# Which events reach this object is the feed's routing, not this object's, and
# it stays pinned next door in spec/lain/status_feed_spec.rb's "fleet" block.
RSpec.describe Lain::StatusFeed::Fleet do
  def spawn_event(id)
    Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)
  end

  describe "#digests" do
    it "is empty before anything has launched -- a fresh fleet claims nothing" do
      expect(described_class.new.digests).to eq([])
    end

    # The extraction is a real object rather than a moved instance variable,
    # and this example is what says so: no StatusFeed is constructed anywhere
    # in it, so the answer can only come from the fleet itself.
    it "answers what it holds with no StatusFeed involved" do
      fleet = described_class.new
      launch = spawn_event("a")

      fleet.launched(launch)

      expect(fleet.digests).to eq([launch.digest])
    end
  end

  describe "#launched" do
    it "names each distinct spawn, in the order they arrived" do
      fleet = described_class.new
      first = spawn_event("a")
      second = spawn_event("b")

      fleet.launched(first)
      fleet.launched(second)

      expect(fleet.digests).to eq([first.digest, second.digest])
    end

    it "dedups a redelivered spawn by digest -- a journal replay grows no phantom entry" do
      fleet = described_class.new

      fleet.launched(spawn_event("a"))
      fleet.launched(spawn_event("a")) # a fresh Event object, same content address

      expect(fleet.digests).to eq([spawn_event("a").digest])
    end
  end
end
