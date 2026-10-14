# frozen_string_literal: true

RSpec.describe Lain::Tools::Subagent::WrapUp do
  let(:posts) { [] }
  let(:mailbox) do
    seen = posts
    Class.new do
      define_method(:post) { |from:, text:| seen << { from:, text: } }
    end.new
  end

  def run(wrap_up, iterations)
    Array.new(iterations) { |i| wrap_up.call({ iteration: i }) { |env| env.merge(settled: false) } }
  end

  it "posts once, from lain, when 5 iterations remain" do
    run(described_class.new(mailbox:, ceiling: 8), 8)

    expect(posts.size).to eq(1)
    expect(posts.first).to include(from: "lain")
    expect(posts.first.fetch(:text)).to include("5 of 8")
  end

  it "posts on the 4th request of a ceiling of 8, before the step runs" do
    wrap_up = described_class.new(mailbox:, ceiling: 8)
    run(wrap_up, 3)
    expect(posts).to be_empty

    during = nil
    wrap_up.call({ iteration: 3 }) { |env| env.tap { during = posts.size } }
    expect(during).to eq(1)
  end

  it "posts on the first request when the ceiling is 5 or less" do
    run(described_class.new(mailbox:, ceiling: 3), 1)

    expect(posts.first.fetch(:text)).to include("3 of 3")
  end

  it "says what a stopped child hands back" do
    run(described_class.new(mailbox:, ceiling: 8), 4)

    expect(posts.first.fetch(:text)).to match(/files it read.*last text block/m)
  end

  it "hands the env through downstream untouched" do
    env = described_class.new(mailbox:, ceiling: 8).call({ iteration: 0 }) { |inner| inner.merge(settled: true) }

    expect(env).to include(iteration: 0, settled: true)
  end
end
