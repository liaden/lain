# frozen_string_literal: true

# What every Context combinator owes beyond its own behaviour: it composes through `>>`, it is a
# pure function of its messages, and it declares the capabilities it needs. `>>` itself is pinned
# as a monoid in spec/lain/context/combinator_spec.rb, so composing with Identity is the only
# composition worth repeating per subject.
#
# The host supplies, in the block passed to `it_behaves_like`:
#
#   let(:combinator)        the subject
#   let(:sample_messages)   a message list it acts on
#   let(:required)          the capabilities it declares (defaults to none)
RSpec.shared_examples "a Context combinator" do
  let(:required) { [] }

  it "composes with Identity through >>, leaving its answer as it was" do
    expect((combinator >> Lain::Context::Identity).call(sample_messages)).to eq(combinator.call(sample_messages))
  end

  it "is pure: identical input yields identical output and the input is left unmutated" do
    before = Lain::Canonical.dump(sample_messages)

    expect(combinator.call(sample_messages)).to eq(combinator.call(sample_messages))
    expect(Lain::Canonical.dump(sample_messages)).to eq(before)
  end

  it "declares the capabilities it requires from the provider" do
    expect(combinator.requires).to eq(required)
  end
end
