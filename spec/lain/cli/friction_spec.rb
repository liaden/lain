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

  # Lineage-bearing sessions, recorded by a real Scribe: friction reads their
  # child work from the file, and refuses only real damage, naming the file.
  describe "a session that spawned subagents" do
    def boom_session(**options)
      RecordedSpawnSession.new(
        tools: [BoomTool.new], child_tools: [BoomTool.new],
        parent_responses: [tool_response(["tu_b1", "boom", {}], ["tu_s", "subagent", { "prompt" => "try boom" }]),
                           text_response("parent done")],
        child_responses: [tool_response(["tu_c1", "boom", {}]), text_response("child gave up")], **options
      )
    end

    it "reports a child's repeat of a failing call in a resumed session that spawned" do
      prior = RecordedSpawnSession.new(parent_responses: [text_response("hello")], child_responses: []).run
      prior.write(File.join(sessions_dir, "prior.ndjson"))
      boom_session(resuming: [prior, "prior.ndjson"]).run("again").write(File.join(sessions_dir, "resumed.ndjson"))

      expect(cli.report("resumed")).to include("1 friction signal(s)", "rephrase_loop")
    end

    it "reports on a live session whose child is still running" do
      session = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "first" }]),
                           tool_response(["tu_b", "subagent", { "prompt" => "second" }]), text_response("done")],
        child_responses: [text_response("first done"), tool_response(["tu_snap", "snapshot", {}]),
                          text_response("second done")]
      ).run
      File.write(File.join(sessions_dir, "live.ndjson"), session.snapshots.first)

      expect(cli.report("live")).to include("friction")
    end

    it "refuses a closed session with a torn child_turn line, naming the file" do
      lines = boom_session.run.lines
      torn = lines.index { |line| JSON.parse(line)["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }
      lines[torn] = "#{lines[torn][0, 40]}\n"
      path = File.join(sessions_dir, "torn.ndjson")
      File.write(path, lines.join)

      expect { cli.report("torn") }.to raise_error(Lain::Error, /#{Regexp.escape(path)}: /)
    end
  end

  it "keeps no per-class SessionNotFound of its own" do
    expect(described_class.const_defined?(:SessionNotFound, false)).to be(false)
  end
end
