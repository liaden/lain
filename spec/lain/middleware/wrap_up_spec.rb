# frozen_string_literal: true

RSpec.describe Lain::Middleware::WrapUp do
  let(:posts) { [] }
  let(:mailbox) do
    seen = posts
    Class.new do
      define_method(:post) { |from:, text:| seen << { from:, text: } }
    end.new
  end
  let(:child_note) do
    lambda do |left:, ceiling:|
      "#{left} of #{ceiling} iterations remain. Files it read, last text block, under 16384 bytes."
    end
  end

  def run(wrap_up, iterations)
    Array.new(iterations) { |i| wrap_up.call({ iteration: i }) { |env| env.merge(settled: false) } }
  end

  def wrap_up(ceiling, **) = described_class.new(mailbox:, ceiling: -> { ceiling }, **)

  it "posts once, from lain, a fifth of the ceiling before it" do
    run(wrap_up(25), 25)

    expect(posts.size).to eq(1)
    expect(posts.first).to include(from: "lain")
    expect(posts.first.fetch(:text)).to include("5 of 25 iterations remain")
  end

  it "posts when the 20th iteration of 25 starts, before the step runs" do
    warning = wrap_up(25)
    run(warning, 20)
    expect(posts).to be_empty

    during = nil
    warning.call({ iteration: 20 }) { |env| env.tap { during = posts.size } }
    expect(during).to eq(1)
  end

  it "keeps 3 iterations of notice however small the ceiling" do
    run(wrap_up(8), 5)
    expect(posts).to be_empty

    run(wrap_up(8), 6)
    expect(posts.first.fetch(:text)).to include("3 of 8")
  end

  it "posts on the first request when the ceiling is 3 or less" do
    run(wrap_up(3), 1)

    expect(posts.first.fetch(:text)).to include("3 of 3")
  end

  it "reads the ceiling on every call, so a ceiling raised or lowered mid-ask moves the warning" do
    ceiling = 60
    warning = described_class.new(mailbox:, ceiling: -> { ceiling })
    run(warning, 20)
    expect(posts).to be_empty

    ceiling = 25
    warning.call({ iteration: 20 }) { |env| env }
    expect(posts.size).to eq(1)
  end

  it "warns again on each ask through one instance, because an ask restarts the count at 0" do
    warning = wrap_up(25)
    run(warning, 25)
    run(warning, 25)

    expect(posts.size).to eq(2)
  end

  it "stays quiet when the agent has no iteration ceiling" do
    warning = described_class.new(mailbox:, ceiling: -> {})
    run(warning, 100)

    expect(posts).to be_empty
  end

  it "tells the parent to finish the step and report" do
    run(wrap_up(25), 21)

    expect(posts.first.fetch(:text)).to match(/finish.*report/i)
  end

  it "uses the wording it is given" do
    run(wrap_up(8, note: child_note), 6)

    expect(posts.first.fetch(:text)).to match(/files it read.*last text block.*under 16384 bytes/mi)
  end

  it "hands the env through downstream untouched" do
    env = wrap_up(8).call({ iteration: 0 }) { |inner| inner.merge(settled: true) }

    expect(env).to include(iteration: 0, settled: true)
  end
end
