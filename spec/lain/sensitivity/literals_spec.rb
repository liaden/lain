# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Literals do
  def literals(env, lent: {}, pass: [])
    described_class.new(child_env: Lain::Exec::ChildEnv.new(pass:, env:), lent:).to_a
  end

  let(:dsn) { "postgres://app:hunter2xyz@db.local/app" }

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

  describe "a passed value" do
    it "lists only the region the detector finds in it, so a DSN gives its password" do
      expect(literals({ "DATABASE_URL" => dsn }, pass: %w[DATABASE_URL])).to eq(["hunter2xyz"])
    end

    it "lists a region in a value lent under a passed name" do
      expect(literals({}, lent: { "DATABASE_URL" => dsn }, pass: %w[DATABASE_URL])).to eq(["hunter2xyz"])
    end

    it "lists nothing from a value with nothing detectable" do
      expect(literals({ "RAILS_ENV" => "development" }, pass: %w[RAILS_ENV])).to be_empty
    end

    it "leaves out a region under the floor" do
      expect(literals({ "DATABASE_URL" => "postgres://app:hunter2@db.local/app" }, pass: %w[DATABASE_URL]))
        .to be_empty
    end

    it "lists nothing from a DSN whose name is not passed" do
      expect(literals({ "DATABASE_URL" => dsn })).to be_empty
    end
  end
end
