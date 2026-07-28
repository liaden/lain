# frozen_string_literal: true

require "tmpdir"
require "json"

# The atomic-replace half of StatusFeed, extracted when the derivations grew
# past the class's line budget (CLAUDE.md: a tripped Metrics cop names a
# missing object). Deriving is an EVENT concern; landing bytes on disk without
# ever letting a reader see a half-written struct is a FILE concern, and it is
# the half with the failure mode a review probe had to go hunting for.
RSpec.describe Lain::StatusFeed::Publication do
  around do |example|
    Dir.mktmpdir("publication-spec") { |dir| @dir = dir and example.run }
  end

  def path = File.join(@dir, "state.json")

  def published = JSON.parse(File.read(path))

  it "writes the struct the block composed, not the token it compared" do
    publication = described_class.new(path)

    publication.call({ "fleet" => [] }) { |token| token.merge("elapsed" => 7) }

    expect(published).to eq({ "fleet" => [], "elapsed" => 7 })
  end

  it "answers whether bytes actually landed" do
    publication = described_class.new(path)

    expect(publication.call("token") { |t| { "t" => t } }).to be true
    expect(publication.call("token") { |t| { "t" => t } }).to be false
  end

  # The whole point of taking a token rather than the struct: StatusFeed's
  # measures are read from a running clock, so composing them into the
  # comparison would make "did anything change" answer yes once a second.
  it "never calls the block for an unchanged token, so a caller pays nothing to skip" do
    publication = described_class.new(path)
    composed = 0
    compose = ->(token) { composed += 1 and token }

    3.times { publication.call("same") { |token| compose.call(token) } }

    expect(composed).to eq(1)
  end

  it "creates the destination directory on demand" do
    nested = File.join(@dir, ".lain", "state.json")

    described_class.new(nested).call("t") { { "ok" => true } }

    expect(JSON.parse(File.read(nested))).to eq({ "ok" => true })
  end

  it "leaves no tmp file behind after a successful publish" do
    described_class.new(path).call("t") { { "ok" => true } }

    expect(Dir.children(@dir)).to eq(["state.json"])
  end

  # A failed write must leave the LAST GOOD state in place rather than a
  # truncated one -- that is what the tmp-then-rename buys -- and it must
  # raise, because a feed that cannot write should not pretend it did.
  it "leaves the previous good bytes intact when the write fails mid-flight" do
    publication = described_class.new(path)
    publication.call("first") { { "n" => 1 } }
    good = File.read(path)

    allow(File).to receive(:write).and_raise(Errno::ENOSPC)

    expect { publication.call("second") { { "n" => 2 } } }.to raise_error(Errno::ENOSPC)
    expect(File.read(path)).to eq(good)
  end

  # ...and the token must NOT be remembered, or the retry after the disk
  # cleared would be skipped as a duplicate and the state would stay stale for
  # the rest of the run.
  it "does not remember a token whose write failed, so the next attempt still publishes" do
    publication = described_class.new(path)
    allow(File).to receive(:write).and_raise(Errno::ENOSPC)
    expect { publication.call("t") { { "n" => 1 } } }.to raise_error(Errno::ENOSPC)

    allow(File).to receive(:write).and_call_original

    expect(publication.call("t") { { "n" => 1 } }).to be true
    expect(published).to eq({ "n" => 1 })
  end
end
