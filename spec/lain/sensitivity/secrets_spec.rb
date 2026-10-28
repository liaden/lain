# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets do
  let(:token) { "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5" }

  def session_lending(env) = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))

  it "lists a value the call's context lends" do
    secrets = described_class.for(child_env: Lain::Exec::ChildEnv.new(env: {}),
                                  context: session_lending("LENT_TOKEN" => "hunterhunterhunter"))

    expect(secrets).to include("hunterhunterhunter")
  end

  it "lists a passed launch value the context never lent" do
    child_env = Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })

    expect(described_class.for(child_env:, context: session_lending({}))).to include(token)
  end

  it "reads a missing context as the null session" do
    child_env = Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })

    expect(described_class.for(child_env:, context: nil)).to include(token)
  end

  it "lists the values history holds at sensitive paths beside the environment's" do
    history = instance_double(Lain::Sensitivity::HistoryLiterals, to_a: ["48291377-history"])
    child_env = Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })

    expect(described_class.for(child_env:, context: nil, history:)).to include(token, "48291377-history")
  end

  describe "Egress.of" do
    let(:first) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
    let(:second) { "qW3eR7tY1uI5oP9aS2dF6gH0jK4lZ8xC3vB7nM1qW5eR9tY2" }
    let(:child_env) { Lain::Exec::ChildEnv.new(env: {}) }
    let(:history) do
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: [first, second], refusable: [first, second])
      Class.new { define_method(:split) { split } }.new
    end

    def address(value) = Lain::Sensitivity::Regions::Region.address(value.b)

    # Membership, never equality: the split also reads the process's own lent environment.
    def placed(egress, *values) = values.map { [egress.refused.include?(_1), egress.flagged.include?(_1)] }

    it "refuses every refusable value when nothing is released" do
      egress = Lain::Sensitivity::Secrets::Egress.of(child_env:, history:)

      expect(placed(egress, first, second)).to eq([[true, false], [true, false]])
    end

    it "flags a value whose region digest is released, and still refuses the other" do
      egress = Lain::Sensitivity::Secrets::Egress.of(child_env:, history:, released: Set[address(first)])

      expect(placed(egress, first, second)).to eq([[false, true], [true, false]])
    end

    it "flags a value whose every region is released, as a URL holding the key" do
      url = "postgres://app:#{first}@db.internal:5432/app"
      inside = Lain::Sensitivity::Regions.detect(url).to_set(&:digest)
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: [url], refusable: [url])
      history = Class.new { define_method(:split) { split } }.new

      egress = Lain::Sensitivity::Secrets::Egress.of(child_env:, history:, released: inside)

      expect(inside).not_to be_empty
      expect(placed(egress, url)).to eq([[false, true]])
    end

    it "still refuses a value the detector finds no region in, whatever else is released" do
      named = Lain::Exec::ChildEnv.new(env: { "DB_PASSWORD" => "staging-password-words" })

      egress = Lain::Sensitivity::Secrets::Egress.of(child_env: named, history: Lain::Sensitivity::HistoryLiterals::Null,
                                                     released: Set[address(first)])

      expect(Lain::Sensitivity::Regions.detect("staging-password-words")).to be_empty
      expect(placed(egress, "staging-password-words")).to eq([[true, false]])
    end

    it "still refuses a value holding a region nobody released" do
      both = "#{first} #{second}"
      split = Lain::Sensitivity::HistoryLiterals::Split.new(known: [both], refusable: [both])
      history = Class.new { define_method(:split) { split } }.new

      egress = Lain::Sensitivity::Secrets::Egress.of(child_env:, history:, released: Set[address(first)])

      expect(placed(egress, both)).to eq([[true, false]])
    end
  end
end
