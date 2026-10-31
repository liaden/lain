# frozen_string_literal: true

RSpec.describe Lain::Grader::TestHarness::Adapter do
  describe ".for" do
    it "builds the rspec adapter by name, with no Gemfile to detect it from" do
      Dir.mktmpdir do |dir|
        expect(described_class.for("rspec").call(dir)).to be_a(described_class::Rspec)
      end
    end

    it "builds the cargo adapter by name, with no Cargo.toml to detect it from" do
      Dir.mktmpdir do |dir|
        expect(described_class.for("cargo").call(dir)).to be_a(described_class::Cargo)
      end
    end

    it "still detects rspec in a directory that also holds a Cargo.toml" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        FileUtils.touch([File.join(dir, "Gemfile"), File.join(dir, "Cargo.toml")])

        expect([described_class.detect(dir), described_class.framework(dir)])
          .to match([an_instance_of(described_class::Rspec), "rspec"])
      end
    end

    it "does not detect a Cargo.toml directory on its own" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Cargo.toml"))

        expect { described_class.detect(dir) }.to raise_error(Lain::Error, /no test framework detected/)
      end
    end

    it "raises naming a preset the probes recognize but have no adapter for" do
      expect { described_class.for("pytest") }.to raise_error(Lain::Error, /pytest.*not implemented/)
    end

    it "raises naming a preset no probe knows" do
      expect { described_class.for("minitest") }.to raise_error(Lain::Error, /test framework minitest/)
    end
  end

  describe "#stdout?" do
    it "is false for the file-reading adapters" do
      command = described_class::Command.new(out_argv: ->(out) { [out] }, passed: /P/, failed: /F/)

      expect([described_class::Rspec.new.stdout?, command.stdout?]).to eq([false, false])
    end
  end

  describe "what an adapter says about an unwritten subject" do
    let(:command) { described_class::Command.new(out_argv: ->(out) { [out] }, passed: /P/, failed: /F/) }
    let(:rspec) { described_class::Rspec.new }

    def awaiting?(adapter, errors, root: "/nowhere")
      adapter.awaiting_subject?(errors, subject: "app/models/greeting.rb", target: "spec/x_spec.rb", root:)
    end

    it "has rspec accept a missing constant named for the subject while the subject is absent" do
      expect(awaiting?(rspec, ["Failure/Error: uninitialized constant Billing::Greeting"])).to be(true)
    end

    it "has rspec refuse a missing constant the subject does not define" do
      expect(awaiting?(rspec, ["Failure/Error: uninitialized constant Farewell"])).to be(false)
    end

    it "has rspec refuse a load error that names no missing constant" do
      expect(awaiting?(rspec, ["Failure/Error: SyntaxError: unexpected end-of-input"])).to be(false)
    end

    it "has rspec refuse once the subject file exists" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/greeting.rb"), "")

        expect(awaiting?(rspec, ["uninitialized constant Greeting"], root: dir)).to be(false)
      end
    end

    it "has a command adapter never accept an error as an unwritten subject" do
      expect(awaiting?(command, ["uninitialized constant Greeting"])).to be(false)
    end

    it "names rspec's lockfile and no build dir, and a command adapter neither" do
      expect([rspec.lockfile, rspec.build_dir, command.lockfile,
              command.build_dir]).to eq(["Gemfile.lock", nil, nil, nil])
    end
  end

  # rspec's `messages` carries its notes beside its load errors, so only the
  # summary's count says how many errors there were.
  describe "Rspec#parse" do
    def parsed(count, messages)
      document = JSON.generate("examples" => [], "messages" => messages,
                               "summary" => { "errors_outside_of_examples_count" => count })
      described_class::Rspec.new.parse(document, 1)
    end

    let(:load_error) do
      "An error occurred while loading ./spec/x_spec.rb.\nFailure/Error: X.go\n\nNameError:\n  uninitialized constant X"
    end

    it "counts a load error once, not the note that no examples were found beside it" do
      expect(parsed(1, [load_error, "No examples found."]).fetch(:errors)).to eq([load_error])
    end

    it "keeps every load error the summary counts" do
      expect(parsed(2, [load_error, load_error, "No examples found."]).fetch(:errors).size).to eq(2)
    end

    it "quotes an after(:suite) error, not the note on the filter in force that comes before it" do
      hook_error = "\nAn error occurred in an `after(:suite)` hook.\nFailure/Error: raise 'broke'\n\nRuntimeError:"

      expect(parsed(1, ["Run options: exclude {slow: true}", hook_error]).fetch(:errors)).to eq([hook_error])
    end

    it "counts an error whose message rspec coloured" do
      coloured = "\e[31mAn error occurred while loading ./spec/x_spec.rb.\e[0m\n\e[31mFailure/Error: X.go\e[0m"

      expect(parsed(1, [coloured, "No examples found."]).fetch(:errors)).to eq([coloured])
    end

    it "labels each counted error rspec gave no message for, beside those it did describe" do
      expect(parsed(2, [load_error, "No examples found."]).fetch(:errors))
        .to eq([load_error, "error outside of examples #2"])
    end

    it "labels each counted error when rspec gave no message for it" do
      expect(parsed(1, []).fetch(:errors)).to eq(["error outside of examples #1"])
    end
  end
end
