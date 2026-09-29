# frozen_string_literal: true

RSpec.describe Lain::Memory::Author do
  it "has a chat author with no spawn" do
    expect(described_class.chat).to have_attributes(kind: "chat", spawn: nil)
  end

  it "has a clerk author citing a spawn" do
    expect(described_class.clerk(spawn: "sha256:abc")).to have_attributes(kind: "clerk", spawn: "sha256:abc")
  end

  it "serialises without a spawn key for the chat" do
    expect(described_class.chat.to_h).to eq("kind" => "chat")
  end

  it "reads an absent record as the chat" do
    expect(described_class.from(nil)).to eq(described_class.chat)
  end

  it "round-trips a clerk record" do
    author = described_class.clerk(spawn: "sha256:abc")
    expect(described_class.from(author.to_h)).to eq(author)
  end

  it "is shareable" do
    expect(Ractor.shareable?(described_class.clerk(spawn: "sha256:abc"))).to be(true)
  end

  it "refuses a spawn on a chat author" do
    expect { described_class.new(kind: "chat", spawn: "sha256:forged") }.to raise_error(ArgumentError, /chat/)
  end

  it "refuses a record that is not a hash" do
    expect { described_class.from("clerk") }.to raise_error(ArgumentError, /hash/)
  end
end
