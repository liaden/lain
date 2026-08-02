# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# `exe/lain` is a script, not a lib file; it guards its own `LainCLI.start`, so
# loading it here defines the Thor commands without running one. Needed for the
# argv guard at the bottom of this file.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Epic)

# `lain epic land` is the command boundary over {Lain::Forge::Landing}. Every
# object it drives carries its own spec, so what is pinned here is the WIRING
# and the four ways it must stop.
#
# The SHA is an ARGUMENT, and that is the whole design. No record binds an
# approved implementation digest to a commit -- {Lain::Approval::GateDecision}
# journals the COMPOSED `(stage, slug, content)` hash and nothing journals the
# content -- so the binding is the hash itself: this command rebuilds
# {Lain::Epic::Submission.implementation} from the sha it was handed and lets
# {Lain::Approval::Gate#ensure_approved!} answer. A sha nobody approved hashes
# to an address the registry has never seen, so landing an unapproved commit is
# unrepresentable rather than merely detected.
#
# `--resume` takes no sha, because taking one would let a human resume a
# landing onto a DIFFERENT commit than the gate cleared. It derives the sha from
# the journaled promote intent, which is by construction the one that passed the
# gate.
RSpec.describe Lain::CLI::EpicLand do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      FileUtils.mkdir_p(sessions_dir)
      write_epic
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def state_home = File.join(@tmp, "state")
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: {}))
  def sessions_dir = paths.sessions_dir

  # A full object name, because {Lain::Forge::Promotion::Remote#anchored!}
  # refuses anything else and the fixture must not be the reason a spec passes.
  def sha = "a" * 40
  def other_sha = "b" * 40

  def home(slug = "demo") = Lain::Epic::Home.resolve(config:, paths:, root:, slug:)

  def issue(id) = Lain::Epic::Issue.new(id:, title: "the #{id} issue")
  def graph = Lain::Epic::Graph.new(issues: [issue("a1"), issue("a2")])
  def write_epic = home.write_epic(graph)

  # --- the two injected seams -----------------------------------------------

  def shell(stdout: "", stderr: "", exitstatus: 0)
    instance_double(Mixlib::ShellOut, run_command: nil, stdout:, stderr:, exitstatus:)
  end

  # Every git subprocess {Lain::Forge::Promotion} and
  # {Lain::Forge::Reconcile::World.live} run, scripted by verb -- the
  # {Lain::CLI::Epic::GitIgnores} seam, so no example needs a repository or a
  # remote. argv is `git -C <root> <verb> ...`.
  def git(heads: "")
    lambda do |*argv, **|
      case argv[3]
      when "check-ref-format", "push" then shell
      when "rev-parse" then shell(stdout: "#{argv[6].to_s[/\h{40}/]}\n")
      when "ls-remote" then shell(stdout: heads)
      else shell(exitstatus: 1, stderr: "unscripted git #{argv.inspect}")
      end
    end
  end

  def github(**overrides)
    defaults = { pr_create: answer(value: 7), pr_merge: answer(value: 7), merge_state: answer(value: "CLEAN"),
                 pr_list: answer(value: []), pr_view: answer(value: { "state" => "OPEN" }) }
    instance_double(Lain::Forge::Gh, **defaults, **overrides)
  end

  def answer(value:) = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => value })

  def command(executor: github, heads: "")
    described_class.new(root:, paths:, config:, github: executor, shell_out_factory: git(heads:))
  end

  # --- journal fixtures, built through the real producers -------------------

  def session(*records, name: "fixture.ndjson", at: "2026-01-01T00:00:00Z")
    File.open(File.join(sessions_dir, name), "w") do |io|
      journal = Lain::Journal.new(io:, clock: -> { at })
      records.each { |record| journal.record(record) }
    end
  end

  def submission(issue_id: "a1", digest: sha)
    Lain::Epic::Submission.implementation(slug: "demo", issue_id:, digest:)
  end

  def approval(issue_id: "a1", digest: sha)
    Lain::Approval::GateDecision.new(artifact_digest: submission(issue_id:, digest:).digest, epic_slug: "demo",
                                     stage: "implementation", approved: true, answered_by: "human",
                                     policy: "hands_off", latency: 0.0)
  end

  def promote_intent(issue_id: "a1", at: sha)
    Lain::Forge::Intent.new(action: Lain::Forge::PROMOTE, epic_slug: "demo", issue_id:,
                            params: { "ref" => "refs/heads/epic/demo/#{issue_id}", "sha" => at })
  end

  def settled(intent)
    Lain::Forge::Outcome.new(intent_id: intent.intent_id, ok: true, observed: false,
                             detail: { "epic_slug" => intent.epic_slug, "issue_id" => intent.issue_id })
  end

  # --- reading back what the run wrote --------------------------------------

  def journal_files(except: nil)
    Dir.children(sessions_dir).select { |name| name.end_with?(".ndjson") }.sort - Array(except)
  end

  def records_in(names)
    names.flat_map { |name| Lain::Journal.records(File.foreach(File.join(sessions_dir, name))).to_a }
         .sort_by { |record| record["ts"].to_s }
  end

  def journal_records = records_in(journal_files)

  def forge_intents = journal_records.select { |record| record["type"] == Lain::Forge::Intent::JOURNAL_TYPE }

  # What THIS run journaled, as opposed to what the fixture already held: the
  # skipped promote is a fixture record, and an example about not re-attempting
  # it has to be able to tell the two apart.
  def run_intents
    records_in(journal_files(except: "fixture.ndjson"))
      .select { |record| record["type"] == Lain::Forge::Intent::JOURNAL_TYPE }
  end

  def progress
    Lain::Epic::Progress.fold(journal_records, graph: home.read_epic, epic_slug: "demo")
  end

  it "names the branch, the pull request and the merged state on the happy path" do
    session(approval)

    output = command.land("a1", sha)

    expect(output).to eq(["landed a1 at #{sha}", "  branch epic/demo/a1", "  pull request #7 -- merged"].join("\n"))
    expect(progress.status("a1")).to eq(Lain::Epic::DONE)
  end

  it "resumes from the sha the promote intent recorded, naming what it skipped" do
    intent = promote_intent
    session(approval, intent, settled(intent))
    allow(Lain::Forge::Landing).to receive(:resume).and_call_original

    output = command.resume("a1")

    expect(Lain::Forge::Landing).to have_received(:resume).with(hash_including(sha:))
    expect(output).to eq(["landed a1 at #{sha}", "  branch epic/demo/a1", "  skipped promote -- already settled",
                          "  pull request #7 -- merged"].join("\n"))
    expect(run_intents.map { |record| record["action"] }).to eq(%w[pr_create pr_merge])
  end

  # The conflicted answer {Lain::Forge::Landing} builds carries a merge state
  # and NO address, so a report that only forwarded it would tell a human that
  # something is dirty without saying which ref to go look at.
  it "names the branch a stop-and-escalate outcome leaves for the human" do
    session(approval)

    output = command(executor: github(merge_state: answer(value: "DIRTY"))).land("a1", sha)

    expect(output).to eq(["stopped a1 at #{sha}", "  branch epic/demo/a1", "  conflicted -- DIRTY",
                          "  act on epic/demo/a1 -- nothing else will land this issue"].join("\n"))
  end

  it "refuses an unapproved implementation before any forge intent" do
    session(approval(digest: other_sha))

    expect { command.land("a1", sha) }.to raise_error(Lain::Approval::Gate::NotApproved, /not approved/)
    expect(forge_intents).to be_empty
  end

  it "refuses a resume with no promote intent, naming the issue" do
    session(approval)

    expect { command.resume("a1") }.to raise_error(described_class::NothingToResume, /a1/)
    expect(forge_intents).to be_empty
  end

  # Through the Thor command object rather than `LainCLI::Epic.start`. `.start`
  # rescues the Thor::Error and calls `Kernel#exit`, because `exe/lain` declares
  # `exit_on_failure? = true` -- inside an example that KILLS the rspec process,
  # which reports the examples that had run as a pass with a nonzero status. It
  # cost this suite 6500 silently missing examples once; the exit contract is
  # pinned in `arms_command_spec.rb`, and what belongs here is the guard.
  it "refuses a second selector on the resume command" do
    command = LainCLI::Epic.new([], { resume: true })

    expect { command.land("demo", "stray", "third") }
      .to raise_error(Thor::Error, /accepts at most one slug/)
  end

  it "folds one issue's intents only, so two landings in one epic do not interleave" do
    mine = promote_intent
    session(approval, mine, settled(mine), promote_intent(issue_id: "a2", at: other_sha))
    folded = []
    allow(Lain::Forge::Reconcile).to receive(:new).and_wrap_original do |original, **kwargs|
      folded << kwargs.fetch(:entries)
      original.call(**kwargs)
    end

    command.resume("a1")

    expect(folded).not_to be_empty
    expect(folded.flatten(1)).to all(satisfy { |record| !record.to_s.include?("a2") })
  end
end
