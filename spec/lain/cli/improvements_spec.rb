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

  # A record Improvement itself could never build: the sink guards every field,
  # so damage only ever arrives through the file, and only the file can stage it.
  def append_raw(**record)
    FileUtils.mkdir_p(File.dirname(improvements_path))
    line = JSON.generate({ "type" => "improvement" }.merge(record.transform_keys(&:to_s)))
    File.open(improvements_path, "a") { |file| file.write("#{line}\n") }
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

  describe "a --kind outside the closed vocabulary" do
    before do
      append(project_hash: "aaaaaaaaaaaa", kind: "bug", note: "friction report double-counts")
      append(project_hash: "aaaaaaaaaaaa", kind: "knob", note: "raise the bash timeout")
    end

    it "refuses a mistyped kind, naming the four valid kinds, rather than reporting an empty store" do
      expect { cli.report(kind: "bugs") }
        .to raise_error(Lain::CLI::Improvements::UnknownKind,
                        %(--kind must be one of ["knob", "bug", "missing-feature", "doc"], got "bugs"))
    end

    it "still reports the friendly empty message for a valid kind that matches nothing" do
      expect(cli.report(kind: "doc")).to eq("no improvements recorded yet -- looked for #{improvements_path}")
    end
  end

  # Nothing is seeded here on purpose. Resolution used to happen inside the
  # `select` block, so a --project this process cannot resolve was invisible
  # against an empty store and raised a raw ArgumentError against a populated
  # one -- past Boundary#render, with a backtrace.
  describe "a --project value this process cannot resolve" do
    it "refuses a `~user` that does not exist, rather than letting File.expand_path's ArgumentError escape" do
      expect { cli.report(project: "~definitelynosuchuser99") }
        .to raise_error(Lain::CLI::Improvements::UnusableProject, /~definitelynosuchuser99.*doesn't exist/m)
    end

    it "refuses a value carrying a NUL byte" do
      expect { cli.report(project: "a\0b") }
        .to raise_error(Lain::CLI::Improvements::UnusableProject, /null byte/)
    end

    it "refuses invalid UTF-8, which HASH_FORMAT.match? itself rejects before any path expansion" do
      expect { cli.report(project: (+"\xff\xfe").force_encoding("UTF-8")) }
        .to raise_error(Lain::CLI::Improvements::UnusableProject, /invalid byte sequence/)
    end

    it "refuses an empty --project instead of silently meaning this process's working directory" do
      expect { cli.report(project: "") }
        .to raise_error(Lain::CLI::Improvements::UnusableProject, /empty/)
    end

    it "refuses the same way whether the store is empty or populated, since it resolves before reading" do
      unresolvable = -> { cli.report(project: "a\0b") }

      expect(&unresolvable).to raise_error(Lain::CLI::Improvements::UnusableProject)

      append(project_hash: "aaaaaaaaaaaa")

      expect(&unresolvable).to raise_error(Lain::CLI::Improvements::UnusableProject)
    end
  end

  describe "a record whose kind is outside the closed vocabulary" do
    it "refuses by name rather than counting it in the header and printing no bullet under the project" do
      append_raw(kind: "bugs", note: "THIS NOTE WOULD BE INVISIBLE", project_hash: "aaaaaaaaaaaa",
                 session: "sess-badkind", at: "2026-08-23T00:00:01.000000Z", evidence_digests: [])

      expect { cli.report }
        .to raise_error(Lain::CLI::Improvements::UnreadableRecord, /sess-badkind.*"bugs".*knob/m)
    end

    it "refuses when the kind is null, which group_by keys as nil and KIND_ORDER silently drops" do
      append_raw(kind: nil, note: "ALSO INVISIBLE", project_hash: "aaaaaaaaaaaa",
                 session: "sess-nilkind", at: "2026-08-23T00:00:02.000000Z", evidence_digests: [])

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord, /sess-nilkind/)
    end

    it "refuses even when a well-formed record beside it would have rendered on its own" do
      append(project_hash: "aaaaaaaaaaaa", kind: "bug", note: "a real bug")
      append_raw(kind: "bugs", note: "invisible", project_hash: "aaaaaaaaaaaa",
                 session: "sess-badkind", at: "2026-08-23T00:00:03.000000Z", evidence_digests: [])

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord)
    end
  end

  describe "a record damaged in a way an intact JSON line still parses" do
    let(:damaged) do
      { kind: "knob", note: "a note", project_hash: "aaaaaaaaaaaa", session: "sess-damaged",
        at: "2026-08-23T00:00:00.000000Z" }
    end

    it "refuses by name when a record carries no evidence_digests, rather than raising NoMethodError" do
      append_raw(**damaged)

      expect { cli.report }
        .to raise_error(Lain::CLI::Improvements::UnreadableRecord, /sess-damaged.*evidence_digests/m)
    end

    it "refuses the same way when evidence_digests is present but is not a list" do
      append_raw(**damaged, evidence_digests: nil)

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord)
    end

    it "refuses a list holding something that is not a digest string, not merely a non-list" do
      append_raw(**damaged, evidence_digests: [nil])

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord, /\[nil\]/)
    end

    it "refuses a list holding an object, which would otherwise render as inspected Ruby in the bullet" do
      append_raw(**damaged, evidence_digests: [{ "a" => 1 }])

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord)
    end

    it "names what the record actually carries, so the message cannot contradict itself" do
      append_raw(**damaged, evidence_digests: "deadbeef")

      expect { cli.report }.to raise_error(Lain::CLI::Improvements::UnreadableRecord) do |error|
        expect(error.message).to include(%(carries "deadbeef"))
        expect(error.message).not_to include("carries no")
      end
    end
  end
end
