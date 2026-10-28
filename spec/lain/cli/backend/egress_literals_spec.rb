# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::EgressLiterals do
  subject(:holder) { described_class.new }

  let(:ledger) { Lain::Sensitivity::Ledger.new }

  # A secrets source refusing `values`, read live, as the board's is.
  def source_of(*values)
    Class.new do
      define_method(:values) { values }
      define_method(:egress) { |**| Lain::Sensitivity::Secrets::Egress.new(refused: values, flagged: []) }
    end.new
  end

  it "refuses to answer before it is bound" do
    expect { holder.egress }.to raise_error(Lain::Provider::HTTP::EgressGuard::NotBound)
  end

  it "reads its source on every ask once bound" do
    source = source_of("first-value-x")
    holder.bind(source, ledger:)
    source.values << "second-value-y"

    expect(holder.egress.refused).to eq(%w[first-value-x second-value-y])
  end

  it "binds once" do
    source = source_of("first-value-x")
    holder.bind(source, ledger:)

    expect(holder.bind(source, ledger:)).to be(holder)
    expect { holder.bind(source_of, ledger:) }.to raise_error(Lain::CLI::Backend::Rebound)
  end

  it "counts the ledger as part of the source, by identity, and says so" do
    source = source_of("first-value-x")
    holder.bind(source, ledger:)

    expect { holder.bind(source, ledger: Lain::Sensitivity::Ledger.new) }
      .to raise_error(Lain::CLI::Backend::Rebound, /another source and ledger/)
  end

  it "refuses a nil ledger" do
    expect { holder.bind(source_of, ledger: nil) }.to raise_error(ArgumentError, /ledger/)
  end

  describe "binding a board's secrets source" do
    it "reads the board's own child environment and history" do
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: %w[history-value-42],
                                                            refusable: %w[history-value-42])
      history = Class.new { define_method(:split) { split } }.new
      env = Lain::Exec::ChildEnv.new(env: { "DB_PASSWORD" => "board-env-secret-77" })
      secrets = Lain::Sensitivity::Secrets::Source.new(child_env: env, history:)

      expect(holder.bind(secrets, ledger:).egress.refused).to include("board-env-secret-77", "history-value-42")
    end
  end

  describe "a release in the bound ledger" do
    let(:first) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
    let(:second) { "qW3eR7tY1uI5oP9aS2dF6gH0jK4lZ8xC3vB7nM1qW5eR9tY2" }
    let(:sensitivity) do
      classifier = Lain::Sensitivity.new(home: "/home/probe", cwd: "/repo", root: "/repo")
      Lain::Sensitivity::Policy.new(sensitivity: classifier, home: "/home/probe", root: "/repo")
    end
    let(:secrets) do
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: [first, second], refusable: [first, second])
      history = Class.new { define_method(:split) { split } }.new
      Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env: {}), history:)
    end
    let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=#{first}\nSESSION_SECRET=#{second}\n") }

    def refused(*values) = values.map { holder.egress.refused.include?(_1) }

    it "moves a human's release at a secret path from refused to flagged, read on the next ask" do
      holder.bind(secrets, ledger:, sensitivity:)
      ledger.release("/repo/.env", regions.take(1), authority: :human)

      expect(refused(first, second)).to eq([false, true])
      expect(holder.egress.flagged).to include(first)
    end

    it "still refuses a value a surface released automatically" do
      holder.bind(secrets, ledger:, sensitivity:)
      ledger.release("/repo/.env", regions, authority: :automatic)

      expect(refused(first, second)).to eq([true, true])
    end

    it "still refuses a value a human released at an ordinary path, as a copy of the file" do
      holder.bind(secrets, ledger:, sensitivity:)
      ledger.release("/repo/leak.txt", regions, authority: :human)

      expect(refused(first, second)).to eq([true, true])
    end

    it "lifts nothing under the default policy, which marks no path secret" do
      holder.bind(secrets, ledger:)
      ledger.release("/repo/.env", regions, authority: :human)

      expect(refused(first, second)).to eq([true, true])
    end

    # The environment's own secret follows the same rule as the history's.
    it "lifts a secret-named environment value only on a release at a secret path" do
      env = Lain::Exec::ChildEnv.new(env: { "DB_PASSWORD" => first })
      holder.bind(Lain::Sensitivity::Secrets::Source.new(child_env: env, history: Lain::Sensitivity::HistoryLiterals::Null),
                  ledger:, sensitivity:)

      ledger.release("/repo/leak.txt", regions.take(1), authority: :human)
      copied = refused(first)
      ledger.release("/repo/.env", regions.take(1), authority: :human)

      expect([copied, refused(first)]).to eq([[true], [false]])
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
