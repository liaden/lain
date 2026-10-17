# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Lain::SearchRules do
  let(:default) { Lain::Tool::Bounds::WalkLimit::DEFAULT }

  describe ".from" do
    it "reads the include globs and both limits" do
      rules = described_class.from({ "include" => ["notes/**/*.md"], "max_entries" => 5, "max_bytes" => 99 })

      expect([rules.include,
              rules.limit]).to eq([["notes/**/*.md"], Lain::Tool::Bounds::WalkLimit.new(entries: 5, bytes: 99)])
    end

    it "keeps the default for a limit the table leaves out" do
      rules = described_class.from({ "max_entries" => 5 })

      expect(rules.limit).to eq(Lain::Tool::Bounds::WalkLimit.new(entries: 5, bytes: default.bytes))
    end

    it "answers an absent table with the empty value" do
      expect(described_class.from(nil)).to eq(described_class.empty)
    end

    it "is empty when nothing is re-included and the limits are the defaults" do
      expect([described_class.empty.include, described_class.empty.limit]).to eq([[], default])
    end

    it "refuses an unknown key by name, listing the known ones" do
      expect { described_class.from({ "incldue" => ["x"] }) }
        .to raise_error(Lain::Config::Refusal, /"incldue".*include, max_entries, max_bytes/)
    end

    it "refuses an include glob that leaves the project, naming it" do
      expect { described_class.from({ "include" => ["../other/**"] }) }
        .to raise_error(Lain::Config::Refusal, %r{"\.\./other/\*\*".*include globs stay under the project root})
    end

    it "refuses every spelling of a glob that leaves the project" do
      escapes = ["a/../../x", "~", "~/x", "{..,a}/x", "a/..", "./../x", "a\\..\\x", "**/../x", "..", "C:/x", "c:x"]

      refused = escapes.select do |glob|
        described_class.from({ "include" => [glob] })
        false
      rescue Lain::Config::Refusal
        true
      end

      expect(refused).to eq(escapes)
    end

    it "refuses a glob with a dot or empty segment, which can never match a listed path" do
      expect { described_class.from({ "include" => ["a/./b"] }) }.to raise_error(Lain::Config::Refusal, %r{a/\./b})
      expect { described_class.from({ "include" => ["a//b"] }) }.to raise_error(Lain::Config::Refusal, %r{a//b})
    end

    it "refuses an absolute include glob" do
      expect { described_class.from({ "include" => ["/etc/**"] }) }
        .to raise_error(Lain::Config::Refusal, /include globs stay under the project root/)
    end

    it "refuses an include that is not a list of strings" do
      expect do
        described_class.from({ "include" => "notes/**" })
      end.to raise_error(Lain::Config::Refusal, /include is a list/)
      expect { described_class.from({ "include" => [3] }) }.to raise_error(Lain::Config::Refusal, /include .*string/)
    end

    it "refuses a limit that is not a positive integer" do
      expect { described_class.from({ "max_entries" => 0 }) }.to raise_error(Lain::Config::Refusal, /max_entries/)
      expect { described_class.from({ "max_bytes" => "big" }) }.to raise_error(Lain::Config::Refusal, /max_bytes/)
    end

    it "is deeply frozen" do
      expect(described_class.from({ "include" => ["a/**"] })).to be_deeply_frozen
    end
  end

  describe "through the tools" do
    around do |example|
      Dir.mktmpdir("lain-search-rules") { |made| @root = File.realpath(made) and example.run }
    end

    let(:root) { @root }
    let(:rules) { described_class.from({ "include" => ["planning/notes/**/*.md"], "max_entries" => 5 }) }

    def write(relative, body)
      File.join(root, relative).tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
    end

    def git(*argv)
      _out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", *argv, chdir: root)
      raise err unless status.success?
    end

    def tool(klass, rules)
      klass.new(walk_limit: rules.limit, include: rules.include)
    end

    it "searches an ignored path the include names and no other ignored path" do
      git("init", "-q")
      write(".gitignore", "planning/notes/\ntarget/\n")
      write("planning/notes/a.md", "needle\n")
      write("planning/notes/a.txt", "needle\n")
      write("target/x.txt", "needle\n")
      write("src.rb", "needle\n")

      result = tool(Lain::Tools::Grep, described_class.from({ "include" => ["planning/notes/**/*.md"] }))
               .call(pattern: "needle", path: root)

      expect(result.content.lines.map { _1.split(":").first }).to eq(%w[planning/notes/a.md src.rb])
    end

    it "lists an ignored include through list_files" do
      git("init", "-q")
      write(".gitignore", "planning/notes/\n")
      write("planning/notes/a.md", "x\n")

      result = tool(Lain::Tools::ListFiles, rules).call(path: root, recursive: true)

      expect(result.content.lines.map(&:chomp)).to include("planning/notes/a.md")
    end

    it "finds an ignored include through glob" do
      git("init", "-q")
      write(".gitignore", "planning/notes/\ntarget/\n")
      write("planning/notes/a.md", "x\n")
      write("target/b.md", "x\n")

      result = tool(Lain::Tools::Glob, rules).call(pattern: "**/*.md", path: root)

      expect(result.content.lines.map(&:chomp)).to eq(["planning/notes/a.md"])
    end

    it "searches an ignored include through ast_search" do
      git("init", "-q")
      write(".gitignore", "gen/\n")
      write("gen/a.rb", "def hidden(x); end\n")
      write("gen/skip.rb", "def other(x); end\n")
      rules = described_class.from({ "include" => ["gen/a.rb"] })

      result = tool(Lain::Tools::AstSearch, rules).call(pattern: "def $NAME($$$A)", language: "ruby", path: root)

      expect(result.content).to include("gen/a.rb").and(satisfy { !_1.include?("skip.rb") })
    end

    it "reaches the file tools of the production floor with real rules" do
      git("init", "-q")
      write(".gitignore", "planning/notes/\n")
      write("planning/notes/a.md", "needle\n")
      8.times { write("plain/f#{_1}.txt", "needle\n") }
      floor = Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new, search: rules)
      grep = floor.find { _1.name == "grep" }

      expect(grep.call(pattern: "needle", path: File.join(root, "planning")).content).to include("a.md:1:needle")
      expect(grep.call(pattern: "needle", path: File.join(root, "plain")).content)
        .to include("listing stopped at 5 entries")
    end

    it "reaches the chat's tools through ToolsetBuild from the project's config" do
      git("init", "-q")
      write(".gitignore", "notes/\n")
      write("notes/a.md", "needle\n")
      8.times { write("plain/f#{_1}.txt", "needle\n") }
      write_config(root, "search include: [\"notes/**/*.md\"], max_entries: 5\n")
      backend = Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root:)
      chronicle = Lain::CLI::Chronicle::Null.new
      journal = RecordingChannel.new
      toolset = Lain::CLI::Wiring::ToolsetBuild.new(
        backend:, provider: backend.provider(spool: chronicle.spool), chronicle:, options: {},
        supervisor: Lain::Supervisor.new(journal:), parent: -> { Lain::Timeline.new }, journal:,
        library: backend.library, epic: SpecNulls.unmounted_epic, root:,
        switchboard: -> { SpecNulls::NoSwitchboard }, askers: SpecNulls::UnwiredAskers.build,
        **SpecNulls.unloaded_project
      ).build(Lain::Memory::Recorder.new, ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }))
      grep = toolset.fetch("grep")

      expect(grep.call(pattern: "needle", path: File.join(root, "notes")).content).to include("a.md:1:needle")
      expect(grep.call(pattern: "needle", path: File.join(root, "plain")).content)
        .to include("listing stopped at 5 entries")
    end

    it "reports the configured entry limit" do
      8.times { write("plain/f#{_1}.txt", "needle\n") }

      result = tool(Lain::Tools::Grep, rules).call(pattern: "needle", path: File.join(root, "plain"))

      expect(result.content).to include("listing stopped at 5 entries")
    end

    it "keeps the default limits and ignore handling when nothing is configured" do
      git("init", "-q")
      write(".gitignore", "target/\n")
      write("target/x.txt", "needle\n")
      write("src.rb", "needle\n")

      result = tool(Lain::Tools::Grep, described_class.empty).call(pattern: "needle", path: root)

      expect(result.content.lines.map { _1.split(":").first }).to eq(["src.rb"])
    end
  end
end
