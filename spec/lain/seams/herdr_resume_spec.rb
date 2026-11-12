# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# What herdr stores to bring a chat back is built by the real Up and the real Reporter and read by the
# real Selector, because the three only agree if each speaks the others' words.
RSpec.describe Lain::Herdr::Reporter, :seam do
  let(:dir) { @dir ||= File.realpath(Dir.mktmpdir("herdr-resume")) }
  let(:sessions) { Lain::Paths.new.filing_dir(root: dir).tap { FileUtils.mkdir_p(_1) } }
  let(:name) { "20260727T090000-111.ndjson" }
  let(:journal_path) { File.join(sessions, name) }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, journal_path:) }
  let(:target) { Lain::Herdr::Target.new(bin: "herdr", pane: "w1:p7", socket: "s", via:) }
  let(:resolver) { instance_double(Lain::Herdr::Target::Resolver, current: target) }

  around do |example|
    with_env("XDG_STATE_HOME" => File.join(dir, "state")) { example.run }
  end

  after { FileUtils.remove_entry(@dir) if @dir }

  before do
    header = Lain::SessionRecord.header(context: Lain::Context.new(model: "m", max_tokens: 8),
                                        toolset: Lain::Toolset.new, writer: CoreGraph::NO_WRITER,
                                        sections: SessionSections.complete).merge("ts" => "2026-07-27T09:00:00Z")
    File.write(journal_path, "#{JSON.generate(header)}\n")
  end

  # Resolves the way `lain` would: the project the command line itself names, from wherever it is run.
  def resolved(words, root)
    Dir.chdir(Dir.tmpdir) do
      Lain::CLI::Resume::Selector.new(dir: Lain::Paths.new.filing_dir(root:)).call(words.last)
    end
  end

  def stored_by_up(**)
    calls = []
    tmux = lambda do |*argv, **|
      calls << argv
      instance_double(Lain::Shell::Out, run_command: nil, stdout: "", stderr: "",
                                        exitstatus: argv.include?("has-session") ? 1 : 0)
    end
    Lain::CLI::Up.new(session: "work", cwd: dir, shell_out_factory: tmux, chat_preflight: ->(_args) { [] },
                      gc_schedule: -> {}, **).call(env: {})
    option = calls.find { _1.include?(Lain::Herdr::Reporter::CockpitSession::OPTION) && _1.include?("set-option") }
    JSON.parse(option.last)
  end

  context "when a cockpit runs inside herdr" do
    let(:via) { :cockpit }

    it "stores a command that comes back on the same socket and flags, and resumes the session" do
      stored = stored_by_up(socket: "alt", nvim: nil, chat_args: %w[--approval ask --resume older.ndjson])
      words = described_class.new(resolver:, session: chronicle, up_command: stored).resume_words(target)

      expect(words).to eq(["lain", "up", dir, "--session", "work", "--socket", "alt", "--no-nvim",
                           "--", "--approval", "ask", "--resume", name])
      root = Lain::Project::Resolver.new(home: Dir.home,
                                         paths: Lain::Paths.new).call(cwd: words[2]).project.root
      expect(resolved(words, root)).to eq(journal_path)
    end

    it "carries an explicit nvim socket" do
      stored = stored_by_up(nvim: "/run/n.sock")

      expect(stored).to include("--nvim-socket=/run/n.sock")
    end
  end

  context "when a plain chat runs inside herdr" do
    let(:via) { :env }

    it "stores a command that resumes the same session from another directory" do
      argv = Lain::CLI::ChildArgv.new(root: dir, cwd: dir, journal_path: -> { journal_path }, typed: {},
                                      chat_flags: [])
      words = described_class.new(resolver:, session: chronicle, child_argv: argv).resume_words(target)

      expect(words).to eq(["lain", "chat", "--root", dir, "--cwd", dir, "--resume", name])
      expect(resolved(words, words[words.index("--root") + 1])).to eq(journal_path)
    end
  end
end
