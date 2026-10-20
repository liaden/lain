# frozen_string_literal: true

RSpec.describe Lain::Memory::Item do
  def item(id: "dosage", description: "Adult amoxicillin dosing", body: "500mg every 8 hours")
    described_class.new(id:, description:, body:)
  end

  describe "construction" do
    # The Manifest renders one line per item; any vertical whitespace in an id
    # or description would let one item masquerade as two. The invariant is
    # structural, not advisory, so every Unicode line break is rejected, not
    # just "\n".
    ["\n", "\r", "\r\n", "\v", "\u2028", "\u2029"].each do |separator|
      it "rejects a description containing #{separator.inspect}" do
        expect { item(description: "line one#{separator}line two") }
          .to raise_error(ArgumentError, /one line/)
      end

      it "rejects an id containing #{separator.inspect}" do
        expect { item(id: "dos#{separator}age") }
          .to raise_error(ArgumentError, /one line/)
      end
    end

    # An unaddressable item is a defect...
    it "rejects a blank id" do
      expect { item(id: "") }.to raise_error(ArgumentError, /blank/)
      expect { item(id: "   ") }.to raise_error(ArgumentError, /blank/)
    end

    # ...and blank includes Unicode blanks: String#strip is ASCII-only, so an
    # NBSP-only id would sail through a strip.empty? check and render a
    # manifest line nothing can visibly address.
    it "rejects an id of Unicode blanks the ASCII strip cannot see" do
      expect { item(id: "\u00A0") }.to raise_error(ArgumentError, /blank/)
      expect { item(id: " \u00A0 ") }.to raise_error(ArgumentError, /blank/)
    end

    it "keeps BLANK unreachable as a class constant" do
      expect { Lain::Memory::Item::BLANK }.to raise_error(NameError)
    end

    # ...but a pointless manifest line is not a correctness failure.
    it "allows an empty description" do
      expect(item(description: "").description).to eq("")
    end

    it "stores fields in normalized wire form" do
      expect(described_class.new(id: :dosage, description: "d", body: "b").id).to eq("dosage")
    end

    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      expect(item).to be_deeply_frozen
    end
  end

  describe "#payload" do
    it "is the exact structure that was hashed" do
      expect(item.payload).to eq(
        "id" => "dosage",
        "description" => "Adult amoxicillin dosing",
        "body" => "500mg every 8 hours"
      )
    end
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(item.digest).to start_with("blake3:")
    end

    it "is identical for identical content" do
      expect(item).to have_same_digest_as(item)
    end

    it "changes with id" do
      expect(item(id: "other")).not_to have_same_digest_as(item)
    end

    it "changes with description" do
      expect(item(description: "Pediatric dosing")).not_to have_same_digest_as(item)
    end

    it "changes with body" do
      expect(item(body: "250mg every 8 hours")).not_to have_same_digest_as(item)
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: -> { [item, item] },
                     unequal: -> { item(body: "250mg every 8 hours") },
                     non_member: -> { item.digest }
  end

  describe ".from_canon" do
    it "rebuilds the item its canonical tree addresses" do
      expect(described_class.from_canon(item.canonical)).to eq(item)
    end

    it "keeps a clerk's authorship, which is inside the address" do
      clerk = described_class.new(id: "a", description: "d", body: "b",
                                  author: Lain::Memory::Author.clerk(spawn: "blake3:s"))

      expect(described_class.from_canon(clerk.canonical)).to have_attributes(digest: clerk.digest,
                                                                             author: clerk.author)
    end

    it "hands an item back as it is" do
      one = item

      expect(described_class.from_canon(one)).to equal(one)
    end
  end

  describe "in a content-addressed store" do
    let(:store) { Lain::Dag::Factory.store }

    include_examples "a content-addressed store", store: -> { store }, member: -> { item }
  end
end
