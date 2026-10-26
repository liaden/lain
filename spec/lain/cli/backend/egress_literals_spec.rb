# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::EgressLiterals do
  subject(:holder) { described_class.new }

  # A secrets source refusing `values`, read live, as the board's is.
  def source_of(*values)
    Class.new do
      define_method(:values) { values }
      define_method(:egress) { Lain::Sensitivity::Secrets::Egress.new(refused: values, flagged: []) }
    end.new
  end

  it "refuses to answer before it is bound" do
    expect { holder.egress }.to raise_error(Lain::Provider::HTTP::EgressGuard::NotBound)
  end

  it "reads its source on every ask once bound" do
    source = source_of("first-value-x")
    holder.bind(source)
    source.values << "second-value-y"

    expect(holder.egress.refused).to eq(%w[first-value-x second-value-y])
  end

  it "binds once" do
    source = source_of("first-value-x")
    holder.bind(source)

    expect(holder.bind(source)).to be(holder)
    expect { holder.bind(source_of) }.to raise_error(Lain::CLI::Backend::Rebound)
  end

  describe "#bind_board" do
    it "reads the board's own child environment and history" do
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: %w[history-value-42],
                                                            refusable: %w[history-value-42])
      history = Class.new { define_method(:split) { split } }.new
      env = Lain::Exec::ChildEnv.new(env: { "DB_PASSWORD" => "board-env-secret-77" })
      inputs = Struct.new(:child_env, :history).new(env, history)

      expect(holder.bind_board(inputs).egress.refused).to include("board-env-secret-77", "history-value-42")
    end
  end

  describe "#bind_env" do
    it "reads the child environment with no history walk" do
      env = Lain::Exec::ChildEnv.new(env: { "API_TOKEN" => "env-only-secret-value" })

      expect(holder.bind_env(env).egress.refused).to include("env-only-secret-value")
    end

    it "binds again to the same environment, so two callers on one command agree" do
      holder.bind_env

      expect { holder.bind_env }.not_to raise_error
    end
  end

  describe "#entries" do
    it "appends the egress guard after the configured entries, over this holder" do
      configured = Class.new
      call = Struct.new(:verb, :args, :kwargs, :block, :line, keyword_init: true)
                   .new(verb: :http, args: [configured], kwargs: {}, block: nil, line: 1)
      holder = described_class.new(Lain::Config::Middleware.from([call], path: "/p"))

      entries = holder.entries([])

      expect(entries.map(&:first)).to eq([configured, Lain::Provider::HTTP::EgressGuard])
      expect(entries.last.last.fetch(:literals)).to be(holder)
    end
  end
end
