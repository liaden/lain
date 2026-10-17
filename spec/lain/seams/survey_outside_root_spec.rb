# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# A survey of a tree outside the project the run is anchored on: the directory
# names below the survey root must still count as secret names, and a note
# placed on such a file must journal its evidence masked.
RSpec.describe "a survey of a tree outside the project", :seam do
  let(:home) { "/home/surveyor" }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:value) { "hunter2-not-a-real-value" }
  let(:policy) { Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: @project)) }
  let(:walk) { Lain::Survey::Walk.new(root: @tree, sensitivity: policy) }
  let(:session) do
    corpus = Lain::Review::Source::Corpus.new(
      walk:,
      projection: Lain::Survey::Projection.new(ledger: Lain::Sensitivity::Ledger.new)
    )
    Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source: corpus), journal:,
                               source: "corpus", surface: Lain::Review::Surface::Text.new(sink: StringIO.new))
  end

  around do |example|
    Dir.mktmpdir("lain-survey-outside-root") do |made|
      base = File.realpath(made)
      @project = File.join(base, "project")
      @tree = File.join(base, "tree")
      FileUtils.mkdir_p([File.join(@project, "src"), File.join(@tree, "secrets"), File.join(@tree, "credentials")])
      File.write(File.join(@tree, "secrets/prod"), "line one\nTOKEN=#{value}\n")
      File.write(File.join(@tree, "credentials/x"), "line one\nTOKEN=#{value}\n")
      example.run
    end
  end

  def placed = journal_records(journal_io, "annotation_placed")

  it "projects both secret directories masked whole" do
    verdicts = walk.files.to_h { [_1.path, _1.verdict] }

    expect(verdicts.values_at("secrets/prod", "credentials/x")).to all(have_attributes(named?: true))
  end

  it "journals a note on a masked file's line with its anchor_text masked" do
    handover = Lain::Review::Handover.new(session:)
    note = { "path" => "secrets/prod", "side" => "new", "line" => 1, "anchor_text" => "line one",
             "text" => "rotate", "kind" => "note", "revision" => session.changeset.head_ref, "drifted" => false }
    Lain::Frontend::Neovim::ReviewWrite.notes([[note]]) { |one| handover.wrote_annotation(one) }

    expect(placed.map { _1["anchor_text"] }).to eq([format(Lain::Sensitivity::Regions::PLACEHOLDER, 1)])
    expect(journal_io.string).not_to include("line one")
  end
end
