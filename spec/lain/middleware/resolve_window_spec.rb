# frozen_string_literal: true

# The per-turn trigger that lets a run's window book stop being a guess.
# {Lain::CLI::Backend#context_window} is memoized so three readers cannot divide
# by three numbers, and that memo is what made a `--num-ctx` guess permanent; the
# book's answer can now be re-resolved, and this is the one place that happens.
#
# What is here is the middleware's own contract -- WHEN it fires, and that it
# fires exactly once and outside the work. WHETHER a re-resolution changes the
# answer belongs to {Lain::CLI::Backend::WindowBook::Live}, and the wiring that
# points this at the run's own book to `spec/lain/cli/wiring/agent_build_spec.rb`.
RSpec.describe Lain::Middleware::ResolveWindow do
  # Records the order, because "before the turn" is the whole claim: a refresh
  # that landed after the downstream had already read a window would satisfy a
  # count and prove nothing.
  let(:trail) { [] }
  let(:book) { Class.new { def initialize(trail) = @trail = trail }.new(trail) }

  before do
    book.define_singleton_method(:reresolve) { @trail << :reresolved }
  end

  def run(env = { iteration: 0 })
    described_class.new(book:).call(env) do |inner|
      trail << :turn
      inner.merge(ran: true)
    end
  end

  it "re-resolves the book before the turn runs" do
    run

    expect(trail).to eq(%i[reresolved turn])
  end

  it "re-resolves once per turn, not once per member of the env" do
    run

    expect(trail.count(:reresolved)).to eq(1)
  end

  # A transformer of the environment it is not: the window book is reached
  # through the object this was constructed with, so nothing about the refresh
  # belongs in the turn's env.
  it "hands the downstream the env it was given, and answers what came back" do
    expect(run({ iteration: 3 })).to eq({ iteration: 3, ran: true })
  end

  # It is the OUTERMOST member of the turn stack, so a raise from the turn
  # passes through it: swallowing one here would turn a failed turn into a
  # silent one over a status number.
  it "lets a failing turn raise through it" do
    expect { described_class.new(book:).call({}) { raise "turn failed" } }.to raise_error("turn failed")
    expect(trail).to eq([:reresolved])
  end

  it "composes as a middleware, since the turn stack is where it is used" do
    stack = Lain::Middleware::Stack.new([described_class.new(book:)])

    stack.call({}) { |env| env }

    expect(trail).to eq([:reresolved])
  end
end
