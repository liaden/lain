# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Approval::Remembered do
  def remembered_at(root) = described_class.from(Lain::Config.load(root:))

  def call_for(tool, input) = Lain::Approval::Rule::Call.for(tool:, input:)

  let(:read_file) { Lain::Tools::ReadFile.new }
  let(:bash) { Lain::Tools::Bash.new }

  # A remembered yes is a whole call shape, matched by value: a prefix match
  # would let `git status; rm -rf /` ride an allowance for `git status`.
  describe "an exact match, and nothing wider" do
    def allowing(root, command)
      write_config(root, %(approval do\n  allow "bash", command: #{command.inspect}\nend\n))
      remembered_at(root)
    end

    def allowed?(remembered, tool, input) = remembered.decide(call_for(tool, input))&.allow? || false

    it "does not allow a command the entry is merely a prefix of" do
      Dir.mktmpdir do |root|
        remembered = allowing(root, "git status")

        expect(allowed?(remembered, bash, { "command" => "git status" })).to be(true)
        expect(allowed?(remembered, bash, { "command" => "git status; rm -rf /" })).to be(false)
        expect(allowed?(remembered, bash, { "command" => "git -c core.fsmonitor=id status" })).to be(false)
      end
    end

    it "does not allow the same command carrying a field the entry never named" do
      Dir.mktmpdir do |root|
        remembered = allowing(root, "rm -rf /tmp/scratch")

        expect(allowed?(remembered, bash, { "command" => "rm -rf /tmp/scratch" })).to be(true)
        expect(allowed?(remembered, bash, { "command" => "rm -rf /tmp/scratch", "timeout" => 5 })).to be(false)
      end
    end

    it "does not carry to another tool" do
      Dir.mktmpdir do |root|
        remembered = allowing(root, "rm -rf /tmp/scratch")

        expect(remembered.decide(call_for(read_file, { "path" => "README.md" }))).to be_nil
      end
    end
  end

  describe "a remembered yes" do
    it "allows a persisted call shape" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
          end
        RUBY

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))

        expect(decision).to be_allow
        expect(decision.rule).to eq("remembered")
        expect(decision.reason).to include("`allow` in its `approval` block")
      end
    end

    # "Without reaching a human" is exactly "the chain produced a decision":
    # nothing is what escalates to {Approval::Queue} and the surfaces behind it.
    it "makes the chain decisive, so nothing escalates to a surface" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
          end
        RUBY

        chain = Lain::Approval::RuleChain.new([remembered_at(root)])

        expect(chain.decide(call_for(read_file, { "path" => "README.md" }))).to be_allow
      end
    end

    it "has no opinion about a call shape nobody remembered" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
          end
        RUBY

        expect(remembered_at(root).decide(call_for(read_file, { "path" => "CHANGELOG.md" }))).to be_nil
      end
    end
  end

  describe "a remembered no" do
    it "denies a persisted call shape" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            deny "read_file", path: "secrets.env"
          end
        RUBY

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "secrets.env" }))

        expect(decision).to be_deny
        expect(decision.reason).to include("remembered", "`deny` in its `approval` block")
      end
    end
  end

  describe "precedence" do
    it "denies a shape that is both allowed and denied" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
            deny "read_file", path: "README.md"
          end
        RUBY

        expect(remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))).to be_deny
      end
    end

    it "lets a tool-wide denial outrank a call-specific allow" do
      Dir.mktmpdir do |root|
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
            deny_tool "read_file"
          end
        RUBY

        decision = remembered_at(root).decide(call_for(read_file, { "path" => "README.md" }))

        expect(decision).to be_deny
        expect(decision.reason).to include("read_file", "`deny_tool` in its `approval` block")
      end
    end
  end

  describe "an absent table" do
    it "remembers nothing and raises nothing" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\n")

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
    it "raises a named error carrying the path and line" do
      Dir.mktmpdir do |root|
        write_config(root, "approval do\n  allow \"read_file\", \"README.md\"\nend\n")

        expect { remembered_at(root) }.to raise_error(Lain::Config::Refusal) do |error|
          expect(error.path).to eq("#{config_path(root)}:2")
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
        write_config(root, <<~RUBY)
          approval do
            allow "read_file", path: "README.md"
          end
        RUBY

        expect(remembered_at(root)).to be_deeply_frozen
      end
    end

    it "names itself the way every rule does" do
      expect(described_class.new.name).to eq("remembered")
    end
  end
end
