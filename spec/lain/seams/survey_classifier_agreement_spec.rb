# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# The editor rail {Lain::CLI::HumanReplies} asks for, at the four messages it
# sends one. Its own class rather than the one `command/survey_spec.rb`
# declares -- that file is one `parallel_tests` may hand to another worker.
class ClassifierAgreementRail
  def push(*) = nil
  def pop(*) = nil
  def review_refused(message) = message
  def attached? = true
end

# The frontend at the three messages {Lain::CLI::HumanReplies} asks of one. The
# surface is the REAL text surface and the view the REAL sidebar view, so what
# the survey draws is what a human would be looking at.
class ClassifierAgreementEditor
  def initialize(sink)
    @view = Lain::Frontend::Neovim::ReviewView.new
    @surface = Lain::Review::Surface::Text.new(sink:)
  end

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = review
end

# The divergence ARCHITECTURE.md's "The secret boundary" describes, driven as a
# session actually produces it: a turn legitimately rewrites the `[sensitivity]`
# table the gate was built from, and the survey must still withhold what the
# gate still refuses.
#
# Nothing between the board and the walk is doubled: a real
# {Lain::CLI::Wiring::BoardBuild} board over a real `.lain/config.toml`, the
# real `read_file`/`write_file` tools over a real {Lain::Session} rewriting it,
# the real {Lain::CLI::Command::Surface} assembled from the board's own
# `surface_kwargs`, and the real `/survey` reaching a real walk. The doubles
# here are the ones on neither end of that path -- the agent, the role spawn,
# the status feed and the terminal.
RSpec.describe "a survey and the gate beside it, after the config changes mid-session", :seam do
  let(:sink) { StringIO.new }
  let(:record) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: record) }
  let(:questions) { Async::Queue.new }
  let(:editor) { ClassifierAgreementEditor.new(sink) }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::WriteFile.new]) }
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions:)
  end

  # The project as the session starts: a table denying one basename, one file it
  # denies, and one it says nothing about.
  around do |example|
    Dir.mktmpdir("lain-survey-agreement") do |made|
      @tmp = File.realpath(made)
      @root = File.join(@tmp, "repo")
      @home = File.join(@tmp, "home")
      FileUtils.mkdir_p([File.join(@root, ".lain"), @home])
      File.write(config, %([sensitivity]\ndenied = ["*.ledger"]\n))
      File.write(File.join(@root, "payroll.ledger"), "a roster of salaries\n")
      File.write(File.join(@root, "notes.md"), "# Notes\n\nOne line of prose.\n")
      example.run
    end
  end

  def config = File.join(@root, ".lain", "config.toml")

  def paths = Lain::Paths.new(env: { "HOME" => @home })

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  # The board a chat opens with, built the way {Lain::CLI::Wiring} builds one:
  # the table is compiled HERE, once, and every reader of it holds what this
  # returns.
  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(chronicle: Lain::CLI::Chronicle::Null.new, options: {},
                                                 model: "m", toolset:, project:, paths:)
  end

  # The command surface a typed line reaches, over the board's OWN kwargs --
  # never a hand-assembled set, because the wiring is what is under test.
  def surface
    @surface ||= Lain::CLI::Command::Surface.new(
      agent: instance_spy(Lain::Agent), replies:, supervisor: Lain::Supervisor::Null,
      role_spawn: instance_spy(Lain::Skill::RoleSpawn), chronicle: Lain::CLI::Chronicle::Null.new,
      status_feed: instance_double(Lain::StatusFeed), library: Lain::Skill::Library.load(root: @root),
      root: @root, cwd: @root,
      **board.surface_kwargs(conductor: instance_double(Lain::CLI::Conductor),
                             tty: instance_double(Lain::Frontend::TTY))
    )
  end

  # A turn, at the two tools it takes: `write_file` refuses to clobber a file
  # this session never read, so the read is not scene-setting -- it is what a
  # model rewriting a config has to do first.
  def turn_rewrites_the_config
    session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {}))
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    Lain::Tools::ReadFile.new.call({ "path" => config }, invocation)
    Lain::Tools::WriteFile.new.call({ "path" => config, "content" => "[sensitivity]\ndenied = []\n" }, invocation)
  end

  def read_of(path)
    Lain::Effect::ToolCall.new(tool_use_id: "tu_2", name: "read_file", input: { "path" => path })
  end

  # The chat opening, which is WHEN the table is compiled -- and the reason
  # every example below says it out loud rather than letting a lazy memo decide.
  # A board built after the rewrite would read the rewritten file and agree with
  # the survey for the wrong reason, which is this file passing vacuously.
  def chat_started = surface

  def surveyed
    replies.bind_editor(ClassifierAgreementRail.new)
    replies.bind_review_editor(editor)
    surface.commands.dispatch("/survey #{@root}") { raise "fallthrough must not run" }
  end

  it "still refuses the denied read at the gate, because the board compiled its table at startup" do
    chat_started
    turn_rewrites_the_config

    expect(board.sensitivity.denial(read_of(File.join(@root, "payroll.ledger")))).not_to be_nil
  end

  # THE example. Before this card the survey re-read the rewritten file and
  # listed the very file its own gate goes on refusing.
  it "withholds from the listing exactly what the gate still refuses" do
    chat_started
    turn_rewrites_the_config

    expect(surveyed).to include("withheld 1 path", "payroll.ledger")
  end

  # The rows the human is actually looking at, which is where the narrowing
  # would have been invisible: the disclosure above says a path was held back,
  # and this says the path is not also sitting in the listing.
  it "draws no row for the denied path" do
    chat_started
    turn_rewrites_the_config
    surveyed

    expect(sink.string).not_to include("payroll.ledger")
  end

  # The other half, so the examples above cannot pass by withholding
  # everything: a path neither table names is drawn, rewrite or no rewrite.
  it "draws what neither table names" do
    chat_started
    turn_rewrites_the_config
    surveyed

    expect(sink.string).to include("notes.md")
  end
end
