# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Literals do
  def literals(env, lent: {}) = described_class.new(child_env: Lain::Exec::ChildEnv.new(env:), lent:).to_a

  it "lists a secret-named value" do
    expect(literals({ "API_TOKEN" => "t" * 20 })).to eq(["t" * 20])
  end

  it "leaves out a short value and a plain-named one" do
    env = { "SESSION_KEY" => "a" * 7, "DEPLOY_REGION" => "eu-west-1-zone" }

    expect(literals(env)).to be_empty
  end

  it "lists a value the worker lends" do
    expect(literals({}, lent: { "API_TOKEN" => "t" * 20 })).to eq(["t" * 20])
  end

  it "lists a value once when the process and the worker hold it" do
    expect(literals({ "API_TOKEN" => "t" * 20 }, lent: { "DB_PASSWORD" => "t" * 20 })).to eq(["t" * 20])
  end

  it "returns a frozen list" do
    expect(literals({ "API_TOKEN" => "t" * 20 })).to be_frozen
  end
end
