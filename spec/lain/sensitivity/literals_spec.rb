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

  describe "a value passed under a name that hints at a connection string" do
    it "lists a short random token" do
      env = { "REDIS_URL" => "redis://cache.local:6379/0?sig=Qm9vT2s3x9ZpL1aB" }

      expect(literals(env, pass: %w[REDIS_URL])).to eq(["Qm9vT2s3x9ZpL1aB"])
    end

    it "lists a token with its padding" do
      env = { "SERVICE_URI" => "https://svc.local/x?sig=Qm9vT2s3x9ZpL1aB==" }

      expect(literals(env, pass: %w[SERVICE_URI])).to eq(["Qm9vT2s3x9ZpL1aB=="])
    end

    it "lists nothing from a uuid" do
      env = { "SERVICE_URL" => "https://svc.local/items?id=7d9f2c1e-3b4a-4c5d-8e6f-0a1b2c3d4e5f" }

      expect(literals(env, pass: %w[SERVICE_URL])).to be_empty
    end

    it "lists nothing from a long number" do
      env = { "DATABASE_URL" => "postgres://db.local/app?ts=12345678901234567" }

      expect(literals(env, pass: %w[DATABASE_URL])).to be_empty
    end

    it "lists a padded hex token, measured without its padding" do
      env = { "SERVICE_URL" => "https://x.local/?k=3f5a9c2e1d7b4086==" }

      expect(literals(env, pass: %w[SERVICE_URL])).to eq(["3f5a9c2e1d7b4086=="])
    end

    it "lists a token that follows the scheme's slashes" do
      env = { "SENTRY_DSN" => "https://Qm9vT2s3x9ZpL1aB@o1.ingest.sentry.io/1" }

      expect(literals(env, pass: %w[SENTRY_DSN])).to eq(["Qm9vT2s3x9ZpL1aB"])
    end

    it "lists a token from a value holding a byte that is not UTF-8" do
      env = { "DATABASE_URL" => "postgres://db.local/app?sig=Qm9vT2s3x9ZpL1aB&x=\xff" }

      expect(literals(env, pass: %w[DATABASE_URL])).to eq(["Qm9vT2s3x9ZpL1aB"])
    end

    %w[DB_CONNECTION PRIMARY_DATABASE redis_url DB_CONN].each do |name|
      it "takes #{name} as a hinted name" do
        expect(literals({ name => "Qm9vT2s3x9ZpL1aB" }, pass: [name])).to eq(["Qm9vT2s3x9ZpL1aB"])
      end
    end

    %w[MY_URL_PREFIX CONNECTOR_NAME].each do |name|
      it "does not take #{name} as a hinted name" do
        expect(literals({ name => "Qm9vT2s3x9ZpL1aB" }, pass: [name])).to be_empty
      end
    end

    it "keeps the relaxed bar off a plain name" do
      expect(literals({ "BUILD_TAG" => "Qm9vT2s3x9ZpL1aB" }, pass: %w[BUILD_TAG])).to be_empty
    end

    it "keeps the relaxed bar off a hinted name that is not passed" do
      expect(literals({ "REDIS_URL" => "redis://cache.local:6379/0?sig=Qm9vT2s3x9ZpL1aB" })).to be_empty
    end

    it "keeps the spike corpus's measured score" do
      corpus = YAML.load_file(File.expand_path("../../fixtures/sensitivity/hinted_corpus.yml", __dir__))
      listed = corpus.group_by { _1.fetch("secret") }.transform_values do |rows|
        rows.reject { literals({ "DATABASE_URL" => Array(_1.fetch("value")).join }, pass: %w[DATABASE_URL]).empty? }
      end

      expect([corpus.size, listed.fetch(true).size, listed.fetch(false).map { _1.fetch("label") }])
        .to eq([65, 28, ["git sha", "sha256 digest"]])
    end
  end
end
