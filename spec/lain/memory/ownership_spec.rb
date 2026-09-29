# frozen_string_literal: true

RSpec.describe Lain::Memory::Ownership do
  let(:chat) { Lain::Memory::Author.chat }
  let(:clerk) { Lain::Memory::Author.clerk(spawn: "sha256:abc") }

  def item(author) = Lain::Memory::Item.new(id: "suite", description: "d", body: "b", author:)

  it "refuses a clerk over a chat-held id" do
    expect { described_class.permit!(item(clerk), item(chat)) }.to raise_error(described_class::Refused, /new id/)
  end

  it "permits a first write, a clerk over a clerk, and the chat over anyone" do
    expect(described_class.permit!(item(clerk), nil)).to be_nil
    expect(described_class.permit!(item(clerk), item(clerk))).to be_nil
    expect(described_class.permit!(item(chat), item(clerk))).to be_nil
    expect(described_class.permit!(item(chat), item(chat))).to be_nil
  end
end
