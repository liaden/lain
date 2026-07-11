# frozen_string_literal: true

require "lain/content_addressed"

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

  it "adds no state, so a frozen includer stays Ractor-shareable" do
    expect(Ractor.shareable?(toy.new("blake3:abc"))).to be(true)
  end
end
