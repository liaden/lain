# frozen_string_literal: true

# The REAL reply router, outbox, session and text surface; only the editor's two
# rail methods are stood in, because what is under test is the order and the
# wiring of one opening, which a double anywhere in that chain would hide.
class RoundEditor
  def initialize(surface, outbox)
    @surface = surface
    @outbox = outbox
    @view = Lain::Frontend::Neovim::ReviewView.new
  end

  attr_reader :bound, :open_when_drawn

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
  def held_review_notes = 0
  def note_draw = @open_when_drawn = @outbox.open?
end

# Notes whether the outbox already held the round at the moment of the draw.
class RoundSurface < Lain::Review::Surface::Text
  def initialize(sink:, editor_ref:)
    super(sink:)
    @editor_ref = editor_ref
  end

  def present(changeset, scope:)
    @editor_ref.call.note_draw
    super
  end
end

RSpec.describe Lain::CLI::Command::ReviewRound do
  subject(:round) { described_class.new(outbox:, paths: Lain::Paths.new) }

  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:sink) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal, journal_path: nil) }
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions: Async::Queue.new)
  end
  let(:spawn) { instance_double(Lain::Skill::RoleSpawn) }
  let(:env) { build_command_env(replies:, chronicle:, role_spawn: spawn) }
  let(:surface) { RoundSurface.new(sink:, editor_ref: -> { editor }) }
  let(:editor) { RoundEditor.new(surface, outbox) }
  let(:headline) { ->(session, scope) { "opened #{session.changeset.files.size} files at #{scope}" } }

  around do |example|
    Dir.mktmpdir("lain-review-round") do |made|
      @root = File.realpath(made)
      File.write(File.join(@root, "notes.md"), "# Notes\n\nOne line.\n")
      example.run
    end
  end

  def opening(bounds: Lain::Review::Bounds.new, **overrides)
    walk = Lain::Survey::Walk.new(root: @root, sensitivity: Lain::Sensitivity.new(home: @root, cwd: @root))
    source = Lain::Review::Source::Corpus.new(walk:, projection: Lain::Survey::Projection.new(ledger: Lain::Sensitivity::Ledger.new),
                                              bounds:, named_from: @root)
    described_class::Opening.new(source:, source_name: "corpus", target: @root, label: "survey of #{@root}",
                                 number: nil, bounds:, policy: Lain::Review::Verdict::Policy.default, spawn:,
                                 headline:, **overrides)
  end

  def attach = replies.bind_review_editor(editor)

  it "answers the headline and holds the round it opened under the opening's label" do
    attach

    banner = round.open(opening, env, scope: "by_directory")

    expect(banner).to include("opened 1 files at by_directory")
    expect([outbox.target, outbox.held_source]).to eq(["survey of #{@root}", "corpus"])
  end

  it "binds the gesture rails to a handover before it draws" do
    attach

    round.open(opening, env, scope: "by_directory")

    expect(editor.bound).to be_a(Lain::Review::Handover)
  end

  it "holds before the draw by default" do
    attach

    round.open(opening, env, scope: "by_directory")

    expect(editor.open_when_drawn).to be(true)
  end

  it "holds after the draw when asked, so a refused draw never displaced a held round" do
    attach

    round.open(opening, env, scope: "by_directory", hold_after_draw: true)

    expect([editor.open_when_drawn, outbox.open?]).to eq([false, true])
  end

  it "lets the round go and unbinds when the draw refuses" do
    attach
    tight = Lain::Review::Bounds.new(max_files: 0)

    expect { round.open(opening(bounds: tight), env, scope: "by_directory") }
      .to raise_error(Lain::Review::Bounds::TooLarge)

    expect([outbox.open?, editor.bound]).to eq([false, nil])
  end
end
