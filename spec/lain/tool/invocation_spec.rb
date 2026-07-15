# frozen_string_literal: true

RSpec.describe Lain::Tool::Invocation do
  it "defaults tool_use_id and context to nil, and channel to a Null Object" do
    invocation = described_class.new

    expect(invocation.tool_use_id).to be_nil
    expect(invocation.context).to be_nil
    expect(invocation.channel).to be_a(Lain::Channel::Null)
  end

  it "a default-channel invocation can be pushed to without an if-channel guard" do
    invocation = described_class.new
    expect { invocation.channel.push(:anything) }.not_to raise_error
  end

  it "carries whatever tool_use_id, context, and channel it is given" do
    channel = Object.new
    invocation = described_class.new(tool_use_id: "tu_1", context: :ctx, channel:)

    expect(invocation).to have_attributes(tool_use_id: "tu_1", context: :ctx, channel:)
  end

  it "is a frozen value object" do
    expect(described_class.new).to be_deeply_frozen
  end
end
