# frozen_string_literal: true

# The framing three subsystems had each written out for themselves: git's
# `<tag> <size>\0` header over the RAW bytes, blake3 over the whole of it. What
# these examples pin is the tag's job -- it is the only thing separating one
# content-addressing keyspace from another, so bytes that are the same in every
# other respect must not address alike across two of them.
RSpec.describe Lain::ContentAddressed::Blob do
  it "content-addresses its bytes: same bytes, same digest; different bytes, different digest" do
    expect(described_class.new(bytes: "hello", tag: "t").digest)
      .to eq(described_class.new(bytes: "hello", tag: "t").digest)
    expect(described_class.new(bytes: "hello", tag: "t").digest)
      .not_to eq(described_class.new(bytes: "other", tag: "t").digest)
    expect(described_class.new(bytes: "hello", tag: "t").digest).to start_with("blake3:")
  end

  # The whole reason the tag is a required argument rather than a default.
  it "domain-separates by tag, so identical bytes address differently under two of them" do
    expect(described_class.new(bytes: "hello", tag: "blob").digest)
      .not_to eq(described_class.new(bytes: "hello", tag: "attachment-v1").digest)
  end

  it "is binary-safe: non-UTF-8 bytes address without raising, and come back unchanged" do
    blob = described_class.new(bytes: (+"\xff\x00\xfe").force_encoding(Encoding::BINARY), tag: "t")

    expect(blob.digest).to start_with("blake3:")
    expect(blob.bytes.bytes).to eq([0xff, 0x00, 0xfe])
    expect(blob.bytes.encoding).to eq(Encoding::BINARY)
  end

  # Whatever encoding a caller read under, the same bytes address the same way.
  it "addresses UTF-8 and BINARY readings of one byte string alike" do
    expect(described_class.new(bytes: "héllo", tag: "t").digest)
      .to eq(described_class.new(bytes: "héllo".b, tag: "t").digest)
  end

  it "is a frozen value: equal by digest, deduplicating in a Store" do
    store = Lain::Store.new
    first = described_class.new(bytes: "same", tag: "t")

    expect(first).to be_deeply_frozen
    expect(first).to eq(described_class.new(bytes: "same", tag: "t"))
    store.put(first)
    expect { store.put(described_class.new(bytes: "same", tag: "t")) }.not_to change(store, :size)
  end

  # A NUL in the tag would end the header early, so two different (tag, bytes)
  # pairs could frame to one byte string -- the collision the header exists to
  # make impossible. An empty tag separates nothing.
  it "refuses a tag that cannot frame, naming it" do
    expect { described_class.new(bytes: "hello", tag: "a\0b") }
      .to raise_error(ArgumentError, /tag.*#{Regexp.escape("a\0b".inspect)}/m)
    expect { described_class.new(bytes: "hello", tag: "") }.to raise_error(ArgumentError, /tag/)
  end
end
