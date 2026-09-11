# frozen_string_literal: true

# Arrived here from spec/lain/friction_spec.rb, which held this alongside
# Lain::Friction::Report's own examples before the mirror-path split
# (CLAUDE.md's "one spec file per code file").
RSpec.describe Lain::CLI::Friction do
  subject(:cli) { described_class.new(paths:) }

  let(:tmpdir) { Dir.mktmpdir }
  let(:sessions_dir) { File.join(tmpdir, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:paths) { instance_double(Lain::Paths, sessions_dir:) }

  before do
    fixture_path = File.join(__dir__, "..", "..", "fixtures", "friction", "clean.ndjson")
    FileUtils.cp(fixture_path, File.join(sessions_dir, "20260721T000000-1.ndjson"))
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "resolves a bare filename under this project's session dir and renders the report" do
    expect(cli.report("20260721T000000-1.ndjson")).to include("no friction found")
  end

  it "resolves a filename missing its .ndjson suffix" do
    expect(cli.report("20260721T000000-1")).to include("no friction found")
  end

  it "resolves an explicit path directly" do
    explicit = File.join(sessions_dir, "20260721T000000-1.ndjson")

    expect(cli.report(explicit)).to include("no friction found")
  end

  # The ONE session-resolution refusal, shared with `lain consolidate` and
  # `lain improve` ({CLI::SessionFile}) -- this class no longer owns a copy, so
  # a rescuer naming the type catches all three surfaces.
  it "raises SessionFile::SessionNotFound, naming what it looked at, for an unresolvable selector" do
    expect { cli.report("does-not-exist") }
      .to raise_error(Lain::CLI::SessionFile::SessionNotFound, /does-not-exist/)
  end

  it "keeps no per-class SessionNotFound of its own" do
    expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
  end
end
