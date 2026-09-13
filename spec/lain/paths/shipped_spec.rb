# frozen_string_literal: true

RSpec.describe Lain::Paths::Shipped do
  # Every path here is a fact about the checkout THIS suite is running from --
  # no fixture, no injection, mirroring how {Lain::Paths::Shipped::GEM_ROOT}
  # itself is derived (walk up from `__dir__`, not from an env var).
  def gem_root = File.expand_path("../../..", __dir__)

  describe "every shipped asset resolves from one root" do
    it "computes GEM_ROOT as the repo/gem root" do
      expect(described_class::GEM_ROOT).to eq(gem_root)
    end

    it "puts every named path under GEM_ROOT" do
      named = [
        described_class::CARGO_WORKSPACE_TARGET,
        described_class::NVIM_PLUGIN_ROOT,
        described_class::PROMPT_TEMPLATES_DIR,
        described_class::DEFAULT_PROMPT_CONFIG,
        described_class::NEOVIM_RUNTIME_HEAD,
        described_class::NEOVIM_RUNTIME_MODULES_DIR,
        described_class::SKILL_SHIPPED_DIR,
        described_class::BENCH_CORPUS_PATH,
        described_class::BENCH_EMBEDDINGS_PATH,
        described_class.query_path(:ruby, :symbols)
      ]

      expect(named).to all(start_with("#{gem_root}/"))
    end

    it "resolves each named asset to a path that actually exists in this checkout" do
      shipped = [
        described_class::NVIM_PLUGIN_ROOT,
        described_class::PROMPT_TEMPLATES_DIR,
        described_class::DEFAULT_PROMPT_CONFIG,
        described_class::NEOVIM_RUNTIME_HEAD,
        described_class::NEOVIM_RUNTIME_MODULES_DIR,
        described_class::SKILL_SHIPPED_DIR,
        described_class::BENCH_CORPUS_PATH,
        described_class::BENCH_EMBEDDINGS_PATH,
        described_class.query_path(:ruby, :symbols)
      ]

      missing = shipped.reject { |path| File.exist?(path) }

      expect(missing).to be_empty
    end

    # The one path here that is NOT a shipped file: a build output, present
    # only after `rake core:build`. Distinguishing it from the rest is the
    # point of the previous example, not an oversight in this one.
    it "computes the daemon's build target beside the gem root, whether or not a build has run" do
      expect(described_class::CARGO_WORKSPACE_TARGET).to eq(File.join(gem_root, "target"))
    end
  end

  describe "a structural query file is found for a supported language" do
    it "resolves the path for a known language/query pair" do
      path = described_class.query_path(:ruby, :symbols)

      expect(File).to exist(path)
    end

    it "still returns a path for a language with no authored query, so the caller decides what to do about it" do
      path = described_class.query_path(:python, :symbols)

      expect(path).to start_with(gem_root)
      expect(File).not_to exist(path)
    end
  end

  describe "the daemon binary path honours a configured target directory" do
    it "resolves inside CARGO_TARGET_DIR when the environment names one" do
      configured = "/tmp/lain-shipped-spec-configured-target"

      expect(Lain::Core::Child.binary(env: { "CARGO_TARGET_DIR" => configured }))
        .to eq(File.join(configured, "debug", "lain-core"))
    end

    it "falls back to Shipped::CARGO_WORKSPACE_TARGET when nothing names one" do
      expect(Lain::Core::Child.binary(env: {}))
        .to eq(File.join(described_class::CARGO_WORKSPACE_TARGET, "debug", "lain-core"))
    end
  end
end
