# frozen_string_literal: true

# Five `StandardError` classes escaped `exe/lain`'s `rescue Lain::Error` sites and now
# descend from it; no single one of the five is this spec's subject, hence
# spec/*_discipline_spec.rb rather than a mirrored lib/ path. `Declarative::DeclarationError`
# is a sixth candidate that stays outside on purpose -- see the ruling in `declarative.rb`.
RSpec.describe "Lain::Error taxonomy" do
  # `const_get`, not `::`, because `Unjudged` is `private_constant`.
  def rooted
    [
      Lain::Middleware::GuardTestLayout.const_get(:Unjudged),
      Lain::Shell::Pipeline::Timeout,
      Lain::Tools::WebFetch::ByteCap::Reached,
      Lain::Tools::WebFetch::ByteCap::Refused,
      Lain::Frontend::LineEditor::KeyTaken
    ]
  end

  it "roots every renderer-reachable error under the project's error root" do
    expect(rooted).to all(be < Lain::Error)
    expect(Lain::Error.subclasses).to include(*rooted)
  end

  it "keeps the declaration-time programmer error outside the render boundary" do
    expect(Lain::Declarative::DeclarationError.ancestors).not_to include(Lain::Error)
  end

  it "carries no shadow at the two sites the root qualification was dropped from" do
    # `WorkerId::Refused` and `Types::CoercionError` dropped their `::Lain::Error` qualifier;
    # that's safe only if no module in their lexical scope defines its own `Error`.
    [Lain::Isolation::WorkerId, Lain::Isolation, Lain::Declarative::Types, Lain::Declarative].each do |namespace|
      expect(namespace.const_defined?(:Error, false)).to be(false)
    end

    expect(Lain::Isolation::WorkerId::Refused.superclass).to eq(Lain::Error)
    expect(Lain::Declarative::Types::CoercionError.superclass).to eq(Lain::Error)
  end
end
