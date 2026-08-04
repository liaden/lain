# frozen_string_literal: true

RSpec.describe Lain::Inspectable do
  # The reason the method is shared rather than copied: four of the eight classes
  # that had written it by hand named their own class in the string, so a subclass
  # inspected as its parent.
  it "names the receiver's own class, not the one that included it" do
    parent = Class.new do
      include Lain::Inspectable

      def to_s = "payload"
    end
    stub_const("InspectableParent", parent)
    stub_const("InspectableChild", Class.new(parent))

    expect(InspectableParent.new.inspect).to eq("#<InspectableParent payload>")
    expect(InspectableChild.new.inspect).to eq("#<InspectableChild payload>")
  end

  it "leaves to_s alone, so the two never collapse into one method" do
    subject = Class.new do
      include Lain::Inspectable

      def to_s = "payload"
    end.new

    expect(subject.to_s).to eq("payload")
    expect(subject.method(:to_s)).not_to eq(subject.method(:inspect))
  end
end
