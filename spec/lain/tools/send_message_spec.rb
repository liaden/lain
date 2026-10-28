# frozen_string_literal: true

RSpec.describe Lain::Tools::SendMessage do
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:actor_class) do
    Struct.new(:address, :told) do
      def tell(text) = (self.told = text)
    end
  end
  let(:actors) { [actor_class.new("addr-a"), actor_class.new("addr-b")] }
  let(:tool) { described_class.new(live: -> { actors }) }

  def run(**input) = tool.call(input.transform_keys(&:to_s), invocation)

  it "tells the live actor at the address and says delivered" do
    result = run(address: "addr-a", text: "also update the docs")

    expect(result).not_to be_error
    expect(result.content).to include("delivered")
    expect(actors.map(&:told)).to eq(["also update the docs", nil])
  end

  it "refuses an address no live actor holds, naming it and the live ones" do
    result = run(address: "addr-z", text: "hello")

    expect(result).to be_error
    expect(result.content).to include("addr-z", "addr-a", "addr-b")
  end

  it "cuts the address it echoes back to 80 characters" do
    result = run(address: "A" * 100_000, text: "hello")

    expect(result).to be_error
    expect(result.content.size).to be < 400
  end

  it "lists at most 10 live addresses and counts the rest" do
    many = Array.new(13) { |n| actor_class.new("addr-#{n}") }
    result = described_class.new(live: -> { many }).call({ "address" => "x", "text" => "t" }, invocation)

    expect(result.content).to include("addr-9", "and 3 more")
    expect(result.content).not_to include("addr-10")
  end

  it "answers a tell the actor refuses as an error result" do
    actors.first.define_singleton_method(:tell) { |_text| raise Lain::Error, "actor addr-a is dead" }

    result = run(address: "addr-a", text: "hello")

    expect(result).to be_error
    expect(result.content).to include("is dead")
  end

  it "declares its input fields and runs one at a time" do
    expect(tool.input_schema["required"]).to contain_exactly("address", "text")
    expect(tool.name).to eq("send_message")
    expect(tool.parallel_safe?).to be(false)
  end
end
