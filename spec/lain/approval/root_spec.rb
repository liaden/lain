# frozen_string_literal: true

# The lexical containment question two readers share -- this classifier about
# a tool argument, and the approving shell rule about every word it would let
# through. Pinned at its own address, since either reader can change.
RSpec.describe Lain::Approval::Root do
  let(:root) { described_class.new("/project") }

  it "contains the root itself and what lies beneath it, and nothing beside it" do
    expect(root.contains?("/project")).to be(true)
    expect(root.contains?("lib/x.rb")).to be(true)
    expect(root.contains?("a/../b")).to be(true)
    expect(root.contains?("/projector/x")).to be(false)
    expect(root.contains?("../outside")).to be(false)
  end

  it "resolves a relative path against the base it is given, not the root" do
    expect(root.contains?("../README.md", from: "/project/lib")).to be(true)
    expect(root.contains?("README.md", from: "/elsewhere")).to be(false)
  end

  # A relative base would resolve against `Dir.pwd`, and a leading `~`
  # against getpwnam; both are refused rather than consulted.
  it "refuses a base it cannot place, and a home-relative path, without resolving either" do
    expect(root.contains?("x", from: "project")).to be(false)
    expect(root.contains?("x", from: nil)).to be(false)
    expect(root.contains?("~/x")).to be(false)
    expect(root.contains?("~project/x", from: "/")).to be(false)
  end

  it "is total over input it cannot read" do
    expect(root.contains?("a\0b")).to be(false)
    expect(root.contains?(42)).to be(false)
    expect(root.contains?((+"\xFF\xFE").force_encoding("UTF-16LE"))).to be(false)
  end

  it "offers a Null root that contains nothing at all" do
    expect(described_class::NOWHERE.contains?("/project", from: "/project")).to be(false)
    expect(Ractor.shareable?(root)).to be(true)
  end
end
