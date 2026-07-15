# frozen_string_literal: true

RSpec.describe Lain::ContentAddressed do
  # A minimal includer: the digest IS the content. Normalization and digest
  # derivation stay each real class's own job; the mixin only owns equality.
  toy = Class.new do
    include Lain::ContentAddressed

    attr_reader :digest

    def initialize(digest)
      @digest = digest
      freeze
    end
  end

  impostor = Class.new do
    include Lain::ContentAddressed

    attr_reader :digest

    def initialize(digest)
      @digest = digest
      freeze
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: -> { [toy.new("blake3:abc"), toy.new("blake3:abc")] },
                     unequal: -> { toy.new("blake3:def") },
                     non_member: -> { "blake3:abc" }
  end

  # `is_a?(self.class)` is the guard: a digest collision across types must not
  # collapse two different kinds of value into one.
  it "does not equate instances of different classes sharing a digest" do
    expect(toy.new("blake3:abc")).not_to eq(impostor.new("blake3:abc"))
  end

  # The pinned rejection of Joel's `rescue NoMethodError` edit: a NoMethodError
  # raised INSIDE a collaborator's own `#digest` is a bug, and equality must let
  # it out loudly rather than translate it into a silent `false`. Same class as
  # the receiver so the `is_a?` guard passes and `#digest` is actually reached.
  it "raises rather than swallowing a NoMethodError from a broken #digest" do
    broken = Class.new do
      include Lain::ContentAddressed

      # A genuine bug inside #digest: a NoMethodError on a real collaborator.
      def digest = "blake3:abc".nonexistent_helper
    end
    a = broken.new
    b = broken.new
    expect { a == b }.to raise_error(NoMethodError)
  end

  it "adds no state, so a frozen includer stays Ractor-shareable" do
    expect(toy.new("blake3:abc")).to be_ractor_shareable
  end
end
