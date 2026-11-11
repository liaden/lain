# frozen_string_literal: true

require "pathname"

# One fold of gate decisions. Where a partition stands -- which digest its
# newest settling verdict approved or denied -- is answered by Lain::Epic::Signoff
# alone, so the gate, the sign-off queue, landing, the planning view and `lain
# epic status` cannot disagree about a digest. Before this rule 6 readers folded
# the same records 6 ways, and an approve-then-deny read as approved in some and
# denied in others.
#
# A text scan rather than type inference, like the other discipline specs: a
# `gate_decision` reader cannot be told apart from a fold by its syntax, so
# every lib/ file that reads the records is named here with what it does with
# them, and a new one fails until somebody rules on it. Whole-line comments are
# skipped, so prose about the records is not a reader.
module GateDecisionFoldDiscipline
  READS = [
    /SignoffQueue::JOURNAL_TYPE/,
    /\bGATE_DECISION\b/,
    /["']gate_decision["']/,
    /%w\[[^\]]*\bgate_decision\b/,
    /GateDecision\.verdict_in/,
    /(is_a\?\(|when +)(::)?(Lain::)?(Epic::)?GateDecision\b/
  ].freeze

  # Reading a verdict off a record is what a fold of the standing does.
  VERDICT = /GateDecision\.verdict_in/

  # A record's verdict field read raw, which a reader could fold by without
  # ever naming verdict_in.
  VERDICT_FIELD = /\[["']verdict["']\]|(fetch|dig|key\?)\(["']verdict["']/

  FOLD = "lain/epic/signoff.rb"

  # The other reader that may read a verdict off a record: it folds the parks
  # and the holds, which a standing does not carry, and asks Signoff for the rest.
  PARKS_AND_HOLDS = "lain/epic/signoff_queue.rb"

  READERS = {
    FOLD => "the one fold of the standing",
    PARKS_AND_HOLDS => "folds the parked and held items; its standing is Signoff's",
    "lain/epic/gate.rb" => "steps its records through Signoff and indexes which partitions decided each digest",
    "lain/epic/gate/adjudicator.rb" => "scans for a terminal adjudication by policy, which no standing records; " \
                                       "the verdict it names is Signoff's",
    "lain/frontend/neovim/planning_view.rb" => "takes the newest gate record per issue for its stage and " \
                                               "digest; the state shown is the sign-off queue's",
    "lain/forge/local_landing.rb" => "collects the epics that decided an implementation; the standing is the " \
                                     "sign-off queue's",
    "lain/cli/epic.rb" => "collects records for the sign-off queue",
    "lain/cli/epic_land.rb" => "collects records for landing's approvals",
    "lain/cli/epic_driver/factory.rb" => "collects records for landing's approvals",
    "lain/cli/wiring/planning_build.rb" => "collects records for the planning view",
    "lain/epic/progress.rb" => "collects records for the sign-off queue",
    "lain/cli/epic_submit.rb" => "collects records for the sign-off queue; ReadBack reads this command's own " \
                                 "live decisions, not the journal, so it is not a second fold",
    "lain/remote/agenda.rb" => "dates a parked item by its first decision's timestamp",
    "lain/bench/epic_metrics.rb" => "counts decisions per partition",
    "lain/journal/projection/waits.rb" => "closes a waiting item on a decision event, live or read back",
    "lain/cli/epic_queue.rb" => "reads a deferral as the evidence a parked item has a record behind it",
    "lain/cli/gate_verdict_rewrite.rb" => "rewrites records written before verdicts",
    "lain/cli/session_journals.rb" => "refuses and locates records written before verdicts"
  }.freeze

  # The files that may read a `verdict` field raw: where a gate decision's word
  # is parsed or rewritten, and readers of other record types whose field shares
  # the name. Any other file reading one, a gate_decision reader above included,
  # is folding a verdict outside Signoff.
  VERDICT_FIELDS = {
    "lain/epic/gate_decision.rb" => "verdict_in parses the journaled word: where a record becomes a verdict",
    "lain/cli/gate_verdict_rewrite.rb" => "finds records written before verdicts",
    "lain/cli/session_journals.rb" => "finds records written before verdicts",
    "lain/journal/projection/waits.rb" => "a hold closes no wait; records from before verdicts still close theirs",
    "lain/bench/approval_replay.rb" => "an approval_decision record's verdict",
    "lain/bench/approval_replay/call.rb" => "an approval_decision record's verdict",
    "lain/bench/approval_replay/recorded_judge.rb" => "a recorded judge's verdict",
    "lain/bench/approval_replay/report.rb" => "a live approval ruling's verdict",
    "lain/bench/approval_replay/score.rb" => "a judge's verdict",
    "lain/grader/rubric/scale.rb" => "a grader judge's verdict",
    "lain/qa/answer.rb" => "a QA answer's verdict",
    "lain/review/session/replay.rb" => "a review_verdict record's verdict",
    "lain/telemetry/shell_arm.rb" => "a shell arm record's verdict",
    "lain/tripwire/hit.rb" => "an approval record's verdict"
  }.freeze

  module_function

  def lib_root = Pathname(__dir__).join("..", "lib").expand_path

  # @return [Array<String>] the code lines of a source, whole-line comments dropped
  def code(source) = source.lines.grep_v(/\A\s*#/)

  # @return [Hash{String => Array<String>}] each lib/ file to its code lines
  def sources
    lib_root.glob("**/*.rb").to_h { |file| [file.relative_path_from(lib_root).to_s, code(file.read)] }
  end

  def readers = sources.select { |_, lines| lines.any? { |line| READS.any? { line.match?(_1) } } }.keys.sort

  def verdict_readers = sources.select { |_, lines| lines.any? { _1.match?(VERDICT) } }.keys.sort

  def verdict_field_readers = sources.select { |_, lines| lines.any? { _1.match?(VERDICT_FIELD) } }.keys.sort
end

RSpec.describe "gate decision fold discipline" do
  it "names every lib/ file that reads gate_decision records, with what it does with them" do
    unruled = GateDecisionFoldDiscipline.readers - GateDecisionFoldDiscipline::READERS.keys

    expect(unruled).to be_empty,
                       "#{unruled.join(", ")} read gate_decision records. Where a partition stands is " \
                       "Lain::Epic::Signoff's answer: read it through Signoff or Epic::SignoffQueue#standing. If " \
                       "the file does something else with the records, add it to " \
                       "GateDecisionFoldDiscipline::READERS with its reason."
  end

  it "names no file that no longer reads them, so the list stays the ruling" do
    expect(GateDecisionFoldDiscipline::READERS.keys - GateDecisionFoldDiscipline.readers).to be_empty
  end

  it "reads a verdict off a record only in Signoff and the sign-off queue's parks and holds" do
    expect(GateDecisionFoldDiscipline.verdict_readers)
      .to eq([GateDecisionFoldDiscipline::FOLD, GateDecisionFoldDiscipline::PARKS_AND_HOLDS])
  end

  it "reads a verdict field raw only where a word is parsed or rewritten, or another record type is read" do
    unruled = GateDecisionFoldDiscipline.verdict_field_readers - GateDecisionFoldDiscipline::VERDICT_FIELDS.keys

    expect(unruled).to be_empty,
                       "#{unruled.join(", ")} read a verdict field raw. A gate decision's verdict is " \
                       "Lain::Epic::Signoff's to fold: ask SignoffQueue#standing. If the field belongs to another " \
                       "record type, add the file to GateDecisionFoldDiscipline::VERDICT_FIELDS with its reason."
  end

  it "names no verdict field reader that no longer reads one" do
    expect(GateDecisionFoldDiscipline::VERDICT_FIELDS.keys - GateDecisionFoldDiscipline.verdict_field_readers)
      .to be_empty
  end

  it "skips prose, and finds a reader by its code (self-test)" do
    lines = GateDecisionFoldDiscipline.code(<<~RUBY)
      # GateDecision.verdict_in(record) in a comment
      verdict = Lain::Epic::GateDecision.verdict_in(record)
    RUBY

    expect(lines.grep(GateDecisionFoldDiscipline::VERDICT).size).to eq(1)
  end
end
