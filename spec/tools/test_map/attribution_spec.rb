# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "TestMap::Attribution" do
  a_path = "spec/fixtures/test_map/a_example.rb"
  b_path = "spec/fixtures/test_map/b_example.rb"

  class << self
    # Process-wide, and safe without a lock for the reason the whole suite is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    def probes = @probes ||= {} # rubocop:disable ThreadSafety/ClassInstanceVariable

    # @param record [Boolean] whether the child rspec records a test map
    # @param files [Array<String>] the fixture examples to run, repo-relative, loaded and run in this order
    # @return [Array<Array(String, Object)>] each fixture moment's label and what it saw, in order
    def probe(record:, files:)
      probes[[record, files]] ||= Dir.mktmpdir("attribution") do |dir|
        out = File.join(dir, "probes.ndjson")
        env = { "ATTRIBUTION_PROBE_OUT" => out, "LAIN_TEST_MAP_DIR" => (File.join(dir, "map") if record) }
        support = File.expand_path("../../fixtures/test_map/support", __dir__)
        log, status = Open3.capture2e(env, RbConfig.ruby, "-S", "bundle", "exec", "rspec", "-O", File::NULL,
                                      "--require", "#{support}/early_suite_hooks.rb", "--require", "spec_helper",
                                      "--require", "#{support}/boundary_probe.rb", "--order", "defined",
                                      "--format", "progress", *files, chdir: File.expand_path("../../..", __dir__))
        raise "fixture run failed:\n#{log}" unless status.success?

        File.readlines(out).map { |line| JSON.parse(line).values_at("label", "value") }
      end
    end
  end

  let(:recorded_rows) { self.class.probe(record: true, files: [a_path, b_path]) }
  let(:plain_rows) { self.class.probe(record: false, files: [a_path, b_path]) }
  let(:recorded) { recorded_rows.to_h.except("boundary") }
  let(:plain) { plain_rows.to_h.except("boundary") }
  let(:boundaries) { recorded_rows.filter_map { |label, value| value if label == "boundary" } }

  it "attributes an example inside a shared example to the spec file that includes it" do
    expect(recorded["shared a"]).to eq(a_path)
  end

  it "attributes work done while a file loads to that file, not the next" do
    expect(recorded.values_at("load a", "load b")).to eq([a_path, b_path])
  end

  it "attributes work in before(:context) to its spec file" do
    expect(recorded["context a"]).to eq(a_path)
  end

  it "names a file by the same repo-relative string at load time and at run time" do
    expect(recorded.values_at("load a", "example a", "load b", "example b")).to eq([a_path, a_path, b_path, b_path])
  end

  it "attributes a thread started during an example to that example's file" do
    expect(recorded["thread a"]).to eq(a_path)
  end

  it "keeps the example's file through a group run inside the example, and after it" do
    expect(recorded.values_at("inside sandbox", "after sandbox")).to eq([a_path, a_path])
  end

  it "names no file outside loading and running a spec file" do
    expect(recorded.values_at("before suite", "after suite")).to eq([nil, nil])
  end

  it "yields each change of interval once, through a suite interval, and closes the last" do
    expect(boundaries).to eq([[nil, a_path], [a_path, b_path], [b_path, "suite"], ["suite", a_path],
                              [a_path, b_path], [b_path, nil]])
  end

  it "opens the suite interval before any other before(:suite) hook runs" do
    expect(recorded_rows.index(["boundary", [b_path, "suite"]]))
      .to be < recorded_rows.index(["early before suite", nil])
  end

  it "closes the last interval after every other after(:suite) hook has run" do
    expect(recorded_rows.index(["early after suite", nil])).to be < recorded_rows.index(["boundary", [b_path, nil]])
  end

  it "returns nil from on_boundary" do
    expect(recorded["on_boundary returns nil"]).to be(true)
  end

  it "hands a child process no recording directory" do
    expect(recorded["child a"]).to eq("")
  end

  it "starts coverage only when recording" do
    expect([recorded["coverage"], plain["coverage"]]).to eq([true, false])
  end

  it "names no file and yields no boundary when not recording" do
    expect(plain.except("coverage", "child a", "on_boundary returns nil").values.uniq).to eq([nil])
    expect(plain_rows.assoc("boundary")).to be_nil
  end
end
