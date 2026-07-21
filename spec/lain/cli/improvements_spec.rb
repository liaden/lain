# frozen_string_literal: true

RSpec.describe Lain::CLI::Improvements do
  subject(:cli) { described_class.new(paths:) }

  let(:tmp) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => tmp }) }
  let(:improvements_path) { File.join(tmp, "lain", "improvements.ndjson") }

  after { FileUtils.remove_entry(tmp) }

  def append(project_hash:, session: "sess-1", **overrides)
    sink = Lain::Improvement::Sink.new(paths:, session:, project_hash:)
    sink.append(note: "a note", kind: "knob", evidence_digests: [], **overrides)
  end

  describe "before any dogfooding" do
    it "states no improvements are recorded yet and names the file path it looked for, when no file exists" do
      expect(File.exist?(improvements_path)).to be(false)

      expect(cli.report).to eq("no improvements recorded yet -- looked for #{improvements_path}")
    end

    it "renders the same friendly message for an empty existing file" do
      FileUtils.mkdir_p(File.dirname(improvements_path))
      FileUtils.touch(improvements_path)

      expect(cli.report).to eq("no improvements recorded yet -- looked for #{improvements_path}")
    end
  end

  describe "notes group across projects" do
    before do
      append(project_hash: "aaaaaaaaaaaa", kind: "knob", note: "raise the bash timeout",
             evidence_digests: %w[deadbeef])
      append(project_hash: "aaaaaaaaaaaa", kind: "bug", note: "friction report double-counts",
             evidence_digests: %w[cafebabe])
      append(project_hash: "bbbbbbbbbbbb", kind: "doc", note: "no mention of the sink in CLAUDE.md")
    end

    it "renders both projects as sections with their notes and evidence digests" do
      report = cli.report

      expect(report).to include("project aaaaaaaaaaaa:")
      expect(report).to include("project bbbbbbbbbbbb:")
      expect(report).to include("raise the bash timeout")
      expect(report).to include("evidence: deadbeef")
      expect(report).to include("friction report double-counts")
      expect(report).to include("no mention of the sink in CLAUDE.md")
      expect(report).to include("no evidence")
      expect(report).to include("[session sess-1")
    end

    it "groups a project's notes under their own kind, in the closed-vocabulary order" do
      report = cli.report
      section = report[/project aaaaaaaaaaaa:.*?(?=\nproject|\z)/m]

      expect(section.index("knob:")).to be < section.index("bug:")
    end

    it "omits the other project when filtering by one project hash" do
      report = cli.report(project: "aaaaaaaaaaaa")

      expect(report).to include("project aaaaaaaaaaaa:")
      expect(report).not_to include("project bbbbbbbbbbbb:")
      expect(report).not_to include("no mention of the sink in CLAUDE.md")
    end

    it "resolves a --project value that is not a 12-hex-char hash via Paths#project_hash" do
      resolved = paths.project_hash("/some/repo")
      append(project_hash: resolved, kind: "missing-feature", note: "needs a --project path form")

      report = cli.report(project: "/some/repo")

      expect(report).to include("needs a --project path form")
      expect(report).not_to include("raise the bash timeout")
    end

    it "filters by kind across all projects" do
      report = cli.report(kind: "doc")

      expect(report).to include("no mention of the sink in CLAUDE.md")
      expect(report).not_to include("raise the bash timeout")
      expect(report).not_to include("friction report double-counts")
    end

    it "combines --project and --kind" do
      report = cli.report(project: "aaaaaaaaaaaa", kind: "bug")

      expect(report).to include("friction report double-counts")
      expect(report).not_to include("raise the bash timeout")
      expect(report).not_to include("project bbbbbbbbbbbb:")
    end

    it "renders the friendly no-records message when a filter matches nothing" do
      report = cli.report(project: "cccccccccccc")

      expect(report).to eq("no improvements recorded yet -- looked for #{improvements_path}")
    end

    it "counts records and projects in the header line" do
      expect(cli.report).to start_with("3 improvement(s) across 2 project(s):")
    end
  end

  describe "a note with embedded newlines" do
    it "keeps the bullet on one physical line, replacing the newlines rather than breaking the layout" do
      append(project_hash: "aaaaaaaaaaaa", kind: "knob", note: "line one\nline two\r\nline three")

      report = cli.report
      bullet_lines = report.lines.grep(/^    - /)

      expect(bullet_lines.size).to eq(1)
      expect(bullet_lines.first).to include("line one").and include("line two").and include("line three")
      expect(bullet_lines.first).not_to match(/\r/)
    end
  end

  describe "a torn line in the improvements file (a crash mid-write)" do
    it "still renders every intact record, skipping the torn one" do
      append(project_hash: "aaaaaaaaaaaa", kind: "knob", note: "an intact note before the tear")
      File.open(improvements_path, "a") { |file| file.write("{\"type\":\"improvement\",\"note\":\"cut off mid\n") }
      append(project_hash: "aaaaaaaaaaaa", kind: "bug", note: "an intact note after the tear")

      report = cli.report

      expect(report).to include("an intact note before the tear")
      expect(report).to include("an intact note after the tear")
      expect(report).not_to include("cut off mid")
    end
  end
end
