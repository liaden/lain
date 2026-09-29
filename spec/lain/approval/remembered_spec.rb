# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Approval::Remembered do
  # Every scenario builds its own throwaway root: `.lain/config.toml` is a
  # project file, and no example may go anywhere near the real one (config_spec.rb's posture).
  def write_config(root, body)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(config_path(root), body)
  end

  def config_path(root) = File.join(root, ".lain", "config.toml")

  def remembered_at(root) = described_class.from(Lain::Config.load(root:))

  def call_for(tool, input) = Lain::Approval::Rule::Call.for(tool:, input:)

  let(:read_file) { Lain::Tools::ReadFile.new }

  describe "a remembered yes" do
    it "allows a persisted call shape" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))

        expect(decision).to be_allow
        expect(decision.rule).to eq("remembered")
      end
    end

    # "Without reaching a human" is exactly "the chain produced a decision":
    # nothing is what escalates to {Approval::Queue} and the surfaces behind it.
    it "makes the chain decisive, so nothing escalates to a surface" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        chain = Lain::Approval::RuleChain.new([remembered_at(root)])

        expect(chain.decide(call_for(read_file, { "path" => "README.md" }))).to be_allow
      end
    end

    it "has no opinion about a call shape nobody remembered" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        expect(remembered_at(root).decide(call_for(read_file, { "path" => "CHANGELOG.md" }))).to be_nil
      end
    end
  end

  describe "a remembered no" do
    it "denies a persisted call shape" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.deny]]
          tool = "read_file"
          input = { path = "secrets.env" }
        TOML

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "secrets.env" }))

        expect(decision).to be_deny
        expect(decision.reason).to include("remembered")
      end
    end
  end

  describe "precedence" do
    it "denies a shape that is both allowed and denied" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }

          [[approval.deny]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        expect(remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))).to be_deny
      end
    end

    it "lets a tool-wide denial outrank a call-specific allow" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }

          [[approval.deny_tool]]
          tool = "read_file"
        TOML

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))

        expect(decision).to be_deny
        expect(decision.reason).to include("read_file")
      end
    end
  end

  describe "an absent table" do
    it "remembers nothing and raises nothing" do
      Dir.mktmpdir do |root|
        write_config(root, "[epics]\nhome = \"repo\"\n")

        remembered = remembered_at(root)

        expect(remembered.decide(call_for(read_file, { "path" => "README.md" }))).to be_nil
        expect(remembered).to be_empty
      end
    end

    it "remembers nothing when there is no config file at all" do
      Dir.mktmpdir do |root|
        expect(remembered_at(root)).to be_empty
      end
    end
  end

  describe "a malformed table" do
    it "raises a named error carrying the path" do
      Dir.mktmpdir do |root|
        write_config(root, "approval = \"yes please\"\n")

        expect { remembered_at(root) }.to raise_error(Lain::Config::Refusal) do |error|
          expect(error.path).to eq(config_path(root))
        end
      end
    end
  end

  describe "the value itself" do
    it "has no write side" do
      expect(described_class.const_defined?(:Persister)).to be(false)
    end

    it "is Ractor-shareable, so a remembered set can ride into a worker" do
      Dir.mktmpdir do |root|
        write_config(root, <<~TOML)
          [[approval.allow]]
          tool = "read_file"
          input = { path = "README.md" }
        TOML

        expect(remembered_at(root)).to be_deeply_frozen
      end
    end

    it "names itself the way every rule does" do
      expect(described_class.new.name).to eq("remembered")
    end
  end
end
