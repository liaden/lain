# frozen_string_literal: true

# The {Lain::Inspectable} contract, asked once per including class instead of
# restated in eight spec files. `to_s` is the human projection and stays each
# subject's own business; this pins only the class tag and the non-aliasing.
RSpec.shared_examples "a class-tagged inspect" do
  it "wraps to_s in a tag naming the real class" do
    expect(subject.inspect).to eq("#<#{subject.class} #{subject}>")
  end

  it "does not alias to_s and inspect" do
    expect(subject.method(:to_s)).not_to eq(subject.method(:inspect))
  end
end
