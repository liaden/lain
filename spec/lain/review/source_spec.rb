# frozen_string_literal: true

RSpec.describe Lain::Review::Source::Diffed do
  RSpec::Matchers.define_negated_matcher :not_include, :include

  let(:repo_root) { "/repo" }
  let(:secret_file) { "API_KEY=sk-live-0000000000000000\nplain line\n" }

  let(:host_class) do
    Class.new do
      include Lain::Review::Source::Diffed

      def initialize(repo_root, held)
        @repo_root = repo_root
        @held = held
      end

      def file_at(_revision, path) = @held[path]
    end
  end

  let(:source) { host_class.new(repo_root, "app.env" => secret_file.b) }

  describe "#line_at" do
    it "masks an unreleased region on the line it answers" do
      expect(source.line_at("head", "app.env", 1)).to include("<redacted:1>").and(not_include("sk-live-"))
    end

    it "answers a line holding no region as it is" do
      expect(source.line_at("head", "app.env", 2)).to eq("plain line")
    end

    it "answers the released text once the run's ledger holds the release" do
      ledger = Lain::Sensitivity::Ledger.new
      ledger.release("/repo/app.env", Lain::Sensitivity::Regions.detect(secret_file.b))
      source.projection = Lain::Survey::Projection.new(ledger:)

      expect(source.line_at("head", "app.env", 1)).to eq("API_KEY=sk-live-0000000000000000")
    end

    it "answers nil for a path or a line the revision does not hold" do
      expect([source.line_at("head", "absent.rb", 1), source.line_at("head", "app.env", 9)]).to eq([nil, nil])
    end
  end
end
