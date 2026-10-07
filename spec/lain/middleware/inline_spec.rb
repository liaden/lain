# frozen_string_literal: true

RSpec.describe Lain::Middleware::Inline do
  def stack_of(block) = Lain::Middleware::Stack.new([described_class.new(block)])

  it "wraps the rest of the stack" do
    stack = stack_of(proc { |env, &downstream| downstream.call(env.merge(tagged: true)) })

    expect(stack.call({}) { |env| env }[:tagged]).to be(true)
  end

  it "short-circuits when the block does not call downstream" do
    stack = stack_of(proc { |env, &_downstream| env.merge(response: "x") })

    expect(stack.call({}) { |_env| raise "app ran" }[:response]).to eq("x")
  end

  it "settles" do
    stack = stack_of(proc { |env, &downstream| downstream.call(env) })

    expect(Lain::Middleware.settles!(stack)).to be(stack)
  end
end
