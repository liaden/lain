# frozen_string_literal: true

require "tmpdir"

# The editor's render inlet, reduced to the four rails the Neovim review
# surface posts on. Its own class: the survey command spec's is one
# `parallel_tests` may hand to another worker.
class DocentRootInlet
  def initialize = (@threads = [])

  attr_reader :threads

  def set_review(_lines, _generation, _sides) = nil
  def review_focus = nil
  def review_refused(_message) = nil
  def set_thread(anchor, lines) = @threads << [anchor, lines]
end

class DocentRootRail
  def push(*) = nil
  def pop(*) = nil
  def review_refused(_message) = nil
  def attached? = true
end

class DocentRootEditor
  def initialize
    @inlet = DocentRootInlet.new
    @view = Lain::Frontend::Neovim::ReviewView.new
    @surface = Lain::Review::Surface::Neovim.new(rpc: @inlet, view: @view)
  end

  attr_reader :bound, :inlet

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
end

DocentRootChronicle = Struct.new(:record_journal) do
  def journal_path = nil
end

# A survey of a tree BESIDE the project: the docent's child reads under that
# tree, and a directory name there counts from the tree's own root. A child
# that worked in the project instead saw `secrets/prod` as an ordinary path
# outside it and read the value with no one asked. Driven through the survey
# command, because the root is lent in the command's own wiring.
RSpec.describe "a survey docent reading outside the project", :seam do
  let(:value) { "hunter2-the-value" }
  let(:record) { StringIO.new }
  let(:read_path) { File.join(@tree, "secrets", "prod") }
  let(:provider) do
    read = Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_read", "name" => "read_file",
                                          "input" => { "path" => read_path } }],
                              stop_reason: :tool_use)
    done = Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn)
    Lain::Provider::Mock.new(responses: [read, done])
  end

  around do |example|
    Dir.mktmpdir("lain-docent-root") do |dir|
      @project = File.realpath(dir)
      @tree = File.join(@project, "..", "#{File.basename(dir)}-survey")
      FileUtils.mkdir_p(File.join(@tree, "secrets"))
      @tree = File.realpath(@tree)
      File.write(File.join(@tree, "secrets", "prod"), "hunter2-the-value")
      File.write(File.join(@tree, "doc.md"), "# Notes\n\nOne line of prose.\nAnother line.\n")
      example.run
    ensure
      FileUtils.remove_entry(@tree)
    end
  end

  def role_spawn
    sensitivity = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/nobody", cwd: @project,
                                                                                   root: @project),
                                                home: "/home/nobody", root: @project)
    Lain::Skill::RoleSpawn.new(
      provider:, context_factory: -> { Lain::Context.new(model: "docent-model", max_tokens: 256) },
      toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                                  Lain::Tools::Grep.new]),
      parent: Lain::Timeline.empty(store: Lain::Store.new), slots: Lain::Prompt::Slots.new(fills: {}),
      tool_middleware: ToolRegistry.gated(policy: Lain::Middleware::Gate::DenyAll.new, sensitivity:)
    )
  end

  def command_env(editor)
    replies = Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                          conductor: instance_double(Lain::CLI::Conductor),
                                          ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                          questions: Async::Queue.new)
    replies.bind_editor(DocentRootRail.new)
    replies.bind_review_editor(editor)
    build_command_env(replies:, chronicle: DocentRootChronicle.new(Lain::Journal.new(io: record)),
                      role_spawn:)
  end

  def surveyed_question(editor)
    command = Lain::CLI::Command::Survey.new(cwd: @project, outbox: Lain::Review::Submit::Outbox.new,
                                             ledger: Lain::Sensitivity::Ledger.new,
                                             sensitivity: Lain::Sensitivity.new(home: "/home/nobody", cwd: @project))
    command.call(@tree, command_env(editor))
    path = Pathname(@tree).relative_path_from(@project).join("doc.md").to_s
    handover = editor.bound
    handover.wrote_annotation({ "path" => path, "side" => "new", "line" => 3, "anchor_text" => "One line of prose.",
                                "text" => "why?", "kind" => "note", "revision" => "corpus", "drifted" => false })
    Sync { handover.ask(editor.inlet.threads.last.first["id"], "what is in secrets/prod?").task&.wait }
  end

  it "parks the docent's read of a secret under the surveyed tree and keeps the value out of the record" do
    surveyed_question(DocentRootEditor.new)
    sent = provider.requests.flat_map(&:messages).to_s

    expect(sent).to include("approval denied")
    expect(sent).not_to include(value)
    expect(record.string).not_to include(value)
  end

  context "when the docent reads the file the brief names" do
    let(:read_path) { "doc.md" }

    it "is briefed the name from its own root, and the read returns the file unparked" do
      surveyed_question(DocentRootEditor.new)
      brief = provider.requests.first.messages.to_s
      sent = provider.requests.flat_map(&:messages).to_s

      expect(brief).to include("doc.md, new side")
      expect(brief).not_to include("../")
      expect(sent).to include("One line of prose.").and(satisfy { |text| text.scan("One line of prose.").size > 1 })
      expect(sent).not_to include("approval denied")
    end
  end
end
