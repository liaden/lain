# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe ParsedSource do
  # A fresh set of maps, so an example's clear and tally cannot drop the memo a
  # real file in this run is still reading.
  before do
    %i[PARSED SCANS GROUPS_LEFT].each { |name| stub_const("ParsedSource::#{name}", Concurrent::Map.new) }
  end

  def group_in(file) = Struct.new(:metadata).new({ absolute_file_path: file })

  it "answers a repeated source without parsing it again" do
    allow(Ripper).to receive(:sexp).and_call_original

    2.times { described_class.sexp("x = 1") }

    expect(Ripper).to have_received(:sexp).once
  end

  it "parses again after a clear" do
    allow(Ripper).to receive(:sexp).and_call_original

    described_class.sexp("x = 1")
    described_class.clear
    described_class.sexp("x = 1")

    expect(Ripper).to have_received(:sexp).twice
  end

  it "hands every caller a tree no caller can edit" do
    expect(described_class.sexp("def a(b = 1) = b")).to be_deeply_frozen
  end

  it "answers nil for source that does not parse" do
    expect(described_class.sexp("def (")).to be_nil
  end

  it "freezes a kept scan result all the way down" do
    expect(described_class.once(:parsed_source_spec) { { "a" => ["b"] } }).to be_deeply_frozen
  end

  it "computes a kept scan once" do
    calls = 0
    2.times { described_class.once(:parsed_source_count) { calls += 1 } }

    expect(calls).to eq(1)
  end

  describe "when a group finishes" do
    let(:this_file) { File.expand_path(__FILE__) }

    it "keeps the memo until the last group of a file that used it is done" do
      first = group_in(this_file)
      last = group_in(this_file)
      described_class.expect_groups([first, last])
      allow(Ripper).to receive(:sexp).and_call_original
      described_class.sexp("x = 1")

      described_class.group_finished(first)
      described_class.sexp("x = 1")
      described_class.group_finished(last)
      described_class.sexp("x = 1")

      expect(Ripper).to have_received(:sexp).twice
    end

    it "drops the memo when the files that used it are done, though another file has not started" do
      user = group_in(this_file)
      described_class.expect_groups([user, group_in("/fixture/not_started_spec.rb")])
      allow(Ripper).to receive(:sexp).and_call_original
      described_class.sexp("x = 1")

      described_class.group_finished(user)
      described_class.sexp("x = 1")

      expect(Ripper).to have_received(:sexp).twice
    end

    it "keeps the memo while another file that used it still has groups left" do
      other = group_in("/fixture/other_user_spec.rb")
      described_class.expect_groups([group_in(this_file), other])
      allow(Ripper).to receive(:sexp).and_call_original
      described_class.sexp("x = 1")
      allow(RSpec).to receive(:current_example)
        .and_return(instance_double(RSpec::Core::Example, example_group: other))
      described_class.sexp("x = 1")

      described_class.group_finished(group_in(this_file))
      described_class.sexp("x = 1")

      expect(Ripper).to have_received(:sexp).once
    end
  end

  describe "wired into a real rspec run", :seam do
    fixture = <<~RUBY
      require "ripper"
      calls = 0
      Ripper.singleton_class.prepend(Module.new { define_method(:sexp) { |*args, **kw| calls += 1; super(*args, **kw) } })

      RSpec.describe("first") do
        it("parses") { ParsedSource.sexp("x = 1") }
        describe("nested") { it("is not a file's last group") { expect(true).to be(true) } }
      end
      RSpec.describe("second") { it("reuses the parse") { ParsedSource.sexp("x = 1") } }
      RSpec.describe("third", :dropped) { it("never runs under the filter") { ParsedSource.sexp("x = 1") } }

      RSpec.configure do |config|
        config.after(:suite) do
          ParsedSource.sexp("x = 1")
          puts "PARSES=\#{calls}"
        end
      end
    RUBY

    define_method(:run_fixture) do |*args|
      Dir.mktmpdir("parsed_source_wiring") do |dir|
        path = File.join(dir, "memo_spec.rb")
        File.write(path, fixture)
        support = File.expand_path("support/parsed_source.rb", __dir__)
        out, = Open3.capture2e("bundle", "exec", "rspec", "--options", File::NULL, "--require", support,
                               "--order", "defined", *args, path, chdir: File.expand_path("..", __dir__))
        out[/PARSES=(\d+)/, 1].to_i
      end
    end

    it "parses once for the file, then again only after its last group cleared the memo" do
      expect(run_fixture).to eq(2)
    end

    it "still clears when a group is filtered out of the run" do
      expect(run_fixture("--tag", "~dropped")).to eq(2)
    end
  end
end
