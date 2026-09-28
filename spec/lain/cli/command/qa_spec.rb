# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "mixlib/shellout"

# What a spawn hands back: the child's final answer, which is all a rung reads.
QaCommandSpecAnswer = Data.define(:content)

# `/qa PLAN --base REF`: the door onto the QA ladder, and the one place in `lib/`
# that builds one. The model is the only thing doubled anywhere below -- every
# example runs the real {Lain::QA::PlanCards}, {Lain::QA::ClaimCheck},
# {Lain::QA::SessionTiers}, {Lain::QA::Ladder} and {Lain::QA::Report}, because a
# command specced against a doubled ladder would pin the door and leave the room
# behind it unreachable.
RSpec.describe Lain::CLI::Command::QA do
  around do |example|
    Dir.mktmpdir("lain-qa-command") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "planning/specs"))
      File.write(plan_path, plan)
      example.run
    end
  end

  let(:asked) { [] }
  let(:head) { "b" * 40 }
  let(:risk) { "low" }
  let(:plan) do
    <<~MARKDOWN
      ### T1 — Add the order total          [wave 1] [risk: #{risk}]

      **Files:** `lib/order.rb` (create), `spec/order_spec.rb` (create)

      ```gherkin
      Scenario: the total sums the lines
        Given an order of two lines
        Then its total is their sum
      ```
    MARKDOWN
  end

  def plan_path = File.join(@root, "planning/specs/totals.md")

  # The one doubled collaborator: what a rung's model said. The ladder reads
  # `content`, so the reply is the whole of the fake.
  def answer(verdict:, executed: false, confidence: 0.9)
    body = { "verdict" => verdict, "confidence" => confidence, "executed" => executed,
             "summary" => "the total drops the tax", "evidence" => "lib/order.rb:4 sums the lines and stops",
             "reproduction" => "bundle exec rspec spec/order_spec.rb -e 'the total sums the lines'" }
    "I read it.\n\n```qa-answer\n#{JSON.generate(body)}\n```\n"
  end

  def spawn(reply)
    instance_double(Lain::Skill::RoleSpawn).tap do |double|
      allow(double).to receive(:call) do |_role, _mode, prompt, **|
        asked << prompt
        QaCommandSpecAnswer.new(content: reply)
      end
    end
  end

  def renderer = Lain::Skill::Library.load(root: @root).renderer

  # What the fixture's git resolves each ref to. TWO refs, because one pass's
  # report may not be allowed to overwrite another's, and a single base could
  # never show that.
  def bases = { "main" => "a" * 40, "wave-1" => "c" * 40 }

  def changeset(base, *changed) = Lain::QA::Changeset.new(base: bases.fetch(base), head:, changed:)

  def command(changed: %w[lib/order.rb spec/order_spec.rb], **rest)
    described_class.new(root: @root, renderer:,
                        changeset: ->(root:, base:) { changeset(base, *changed) if root == @root },
                        **rest)
  end

  def run(line = "planning/specs/totals.md --base main", verdict: "pass", **rest)
    command(**rest).call(line, build_command_env(role_spawn: spawn(answer(verdict:))))
  end

  def report_path(base = "main")
    File.join(@root,
              ".lain/qa/planning-specs-totals-#{bases.fetch(base)[0,
                                                                  7]}..#{head[0,
                                                                              12]}.md")
  end

  it "is named for the verb a human types, and says in its usage that it reports rather than fixes" do
    expect(command.name).to eq("qa")
    expect(command.usage).to include("/qa PLAN --base REF", "never fixes")
  end

  # The default binding's whole posture, and the reply has to carry it: one rung
  # whose voice settles nothing leaves every criterion owing a manual pass, which
  # is neither a hold nor a clean pass. A reply that said only PASS would be the
  # silence the ladder exists to abolish.
  it "writes the report and answers with the verdict, the counts and where the report went" do
    reply = run

    expect(reply).to eq("QA PASS, with a manual pass owed: 1 findings, 0 holding, 1 unsettled, " \
                        "rungs t0/t2 -- report at .lain/qa/planning-specs-totals-aaaaaaa..bbbbbbbbbbbb.md")
    expect(File.read(report_path))
      .to include("# QA report: planning/specs/totals.md @ aaaaaaaaaaaa..bbbbbbbbbbbb",
                  "Verdict: PASS (1 unsettled)", "## Escalations", "no-strong-voice",
                  "## Unsettled criteria", "T1/the total sums the lines")
  end

  # The same argument as the range, one directory over: `planning/<epic>/plan.md`
  # twice is the ordinary shape for a tree of epics, and this repo's own
  # `planning/` already carries three duplicated basenames. A name built from the
  # basename alone would have the second pass destroy the first's blocker.
  it "names the report for the plan's PATH, so two plans sharing a basename cannot clobber" do
    %w[a b].each do |dir|
      FileUtils.mkdir_p(File.join(@root, "planning/specs", dir))
      File.write(File.join(@root, "planning/specs", dir, "totals.md"), plan)
    end

    run("planning/specs/a/totals.md --base main", changed: %w[lib/order.rb])
    run("planning/specs/b/totals.md --base main")

    expect(Dir.glob("#{@root}/.lain/qa/*totals*.md").map { |path| File.basename(path) })
      .to contain_exactly("planning-specs-a-totals-aaaaaaa..bbbbbbbbbbbb.md",
                          "planning-specs-b-totals-aaaaaaa..bbbbbbbbbbbb.md")
  end

  # A report IS the evidence, and the filename is the only thing keeping two of
  # them apart. Re-checking one wave against a narrower ref is an ordinary thing
  # to type, and a name carrying only the head would let this PASS overwrite that
  # HOLD with nothing said -- the silence this command exists to abolish,
  # arriving through the filename.
  it "names the report for the whole range, so a pass over another base cannot clobber a hold" do
    held = run("planning/specs/totals.md --base main", changed: %w[lib/order.rb])
    cleared = run("planning/specs/totals.md --base wave-1")

    expect(held).to start_with("QA HOLD")
    expect(cleared).to start_with("QA PASS")
    expect(File.read(report_path)).to include("[major] T1 claims spec/order_spec.rb")
    expect(Dir.glob("#{@root}/.lain/qa/*.md").map { |path| File.basename(path) })
      .to contain_exactly("planning-specs-totals-aaaaaaa..bbbbbbbbbbbb.md",
                          "planning-specs-totals-ccccccc..bbbbbbbbbbbb.md")
  end

  # The brief is the pass's one shared prefix, and it carries what only the
  # command knows: the range, the paths that moved, and what the free rung
  # already found.
  it "opens every rung's prompt with the rendered qa skill, the range and the changed paths" do
    run(changed: %w[lib/order.rb])

    expect(asked.first).to start_with(renderer.render("qa"))
    expect(asked.first).to include("aaaaaaaaaaaa..bbbbbbbbbbbb", "- lib/order.rb",
                                   "T1 claims spec/order_spec.rb")
    expect(asked.first).to include("Scenario: the total sums the lines")
  end

  # The other arm of the same brief: a rung told "nothing was found" reads
  # differently from one told nothing at all, and an empty section would leave it
  # guessing whether the free rung ran.
  it "says so in the brief when the free rung found nothing" do
    run

    expect(asked.first).to include("Nothing: every card's claimed paths are in the range.")
  end

  # The free rung holds before any model could: the card's named spec never
  # appeared, so its criteria were never made into anything that can fail.
  it "holds on a claimed spec file the changeset never touched, found at t0" do
    reply = run(changed: %w[lib/order.rb])

    expect(reply).to start_with("QA HOLD: 2 findings, 1 holding")
    expect(File.read(report_path)).to include("T1 claims spec/order_spec.rb", "- found at: t0")
  end

  it "refuses without a base rather than guessing where the work started" do
    expect { run("planning/specs/totals.md") }.to raise_error(Lain::Error, /needs --base REF/)
  end

  # `--base --width` is a base nobody named: {Args} hands back whatever word
  # followed, flag or not. Refused rather than resolved, and the refusal names
  # only the half that is missing -- telling somebody who typed a plan doc that
  # they need one sends them to re-read the wrong word.
  it "refuses a base that is another flag, naming the base and not the plan it was given" do
    expect { run("planning/specs/totals.md --base --width") }.to raise_error(Lain::Error) { |error|
      expect(error.message).to include("needs --base REF")
      expect(error.message).not_to include("plan doc")
    }
  end

  it "refuses with no plan at all, naming the plan and not the base it was given" do
    expect { run("--base main") }.to raise_error(Lain::Error) { |error|
      expect(error.message).to include("needs a plan doc")
    }
  end

  it "refuses a plan it cannot read, naming the path it looked for" do
    expect { run("planning/specs/nope.md --base main") }
      .to raise_error(Lain::Error, %r{cannot read the plan at .*planning/specs/nope\.md})
  end

  # A plan whose cards state no criteria would climb an empty ladder and report
  # a clean pass over nothing at all -- the one reading of a plan that looks
  # exactly like success.
  it "refuses a plan whose cards state no acceptance criteria" do
    File.write(plan_path, "### T1 — Add the order total [risk: low]\n\n**Files:** `lib/order.rb`\n")

    expect { run }.to raise_error(Lain::Error, /no acceptance criteria/)
  end

  # The rungs are the caller's, and the model rides beside the role per call --
  # so a project's own binding reaches the record, and the command invents none.
  it "runs the rungs it was handed and records the model each one named" do
    tiers = lambda do |role_spawn|
      [Lain::QA::Ladder::Rung.spawning(
        tier: "t1", role_spawn:, role: :qa, strong: true,
        model: Lain::Tools::Subagent::ModelChoice.new(model: "laguna-xs-2.1", declared_by: "the project's tiers")
      )]
    end

    run(tiers:)

    expect(File.read(report_path)).to include("t1 [laguna-xs-2.1]", "Tiers run: t0, t1")
  end

  # Every object on the real path, wired as production wires it: a real git repo,
  # a real plan, the real default binding, and nothing doubled but the model's
  # reply. The blocker is what makes the never-touches-the-tree half meaningful,
  # since a run that found nothing proves nothing about a run that reports.
  #
  # The reply that produces it answers `executed: true`, which the shipped role
  # and skill both FORBID -- the role holds no command tool, so an honest answer
  # from it can only say false. So what these examples pin is the ladder's
  # wiring, not an outcome a shipped pass can reach: the two rules whose action
  # is `report` are unreachable until some rung can genuinely run something.
  describe "over a real checkout", :seam do
    let(:risk) { "high" }

    def git(*args)
      Mixlib::ShellOut.new("git", "-C", @root, *args, environment: SeedRepo::SCRUB)
                      .run_command.tap(&:error!).stdout
    end

    # Every byte of the tree the command promised not to touch, keyed by path.
    # `.lain/` is excluded because the report is the one thing it does write.
    def tree
      paths = Dir.glob("#{@root}/**/*", File::FNM_DOTMATCH).grep_v(%r{/\.git/|/\.lain(/|\z)})
      paths.select { |path| File.file?(path) }.to_h { |path| [path, File.read(path)] }
    end

    # The plan lands in the BASE commit, so the range under test holds exactly
    # what the card claims and nothing the fixture brought with it.
    def seeded
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @root)
      git("add", "-A")
      git("commit", "-q", "-m", "the plan")
      base = git("rev-parse", "HEAD").strip
      FileUtils.mkdir_p([File.join(@root, "lib"), File.join(@root, "spec")])
      %w[lib/order.rb spec/order_spec.rb].each { |path| File.write(File.join(@root, path), "# #{path}\n") }
      git("add", "-A")
      git("commit", "-q", "-m", "the order total")
      base
    end

    it "reports a blocker, writes the report under .lain/qa, and changes nothing else in the tree" do
      base = seeded
      before = tree
      real = described_class.new(root: @root, renderer:)
      expect(before.keys).to include(plan_path, File.join(@root, "lib/order.rb"))

      reply = real.call("planning/specs/totals.md --base #{base}",
                        build_command_env(role_spawn: spawn(answer(verdict: "fail", executed: true))))

      expect(reply).to start_with("QA HOLD: 1 findings, 1 holding, 0 unsettled, rungs t0/t2")
      expect(Dir.glob("#{@root}/.lain/qa/planning-specs-totals-*.md").map { |path| File.read(path) })
        .to contain_exactly(include("[blocker] the total drops the tax", "corroborated-executed-fail"))
      expect(tree).to eq(before)
      expect(git("status", "--porcelain").lines.reject { |line| line.start_with?("?? .lain/") }).to be_empty
    end

    # The whole point of the card: a human types a line and the ladder runs. Every
    # example above holds the command directly, which would stay green for a
    # command no `you>` line could ever reach -- the fate `lain review` met for a
    # whole chunk. So one example goes through the registry the Repl consults,
    # over a Surface built as the wiring builds it.
    it "runs from a typed line, through the surface's own registry" do
      base = seeded
      surface = build_surface(spawn(answer(verdict: "pass")))

      reply = surface.commands.dispatch("/qa planning/specs/totals.md --base #{base}") { "fell through" }

      expect(reply).to start_with("QA PASS, with a manual pass owed:")
      expect(surface.commands.registry.map(&:name)).to include("qa")
    end

    # Every collaborator the Surface requires, none of which `/qa` reads: it takes
    # the root and the library's renderer from the Surface, and its spawn from the
    # Env the Surface assembles.
    def build_surface(role_spawn)
      Lain::CLI::Command::Surface.new(
        agent: instance_spy(Lain::Agent), replies: instance_spy(Lain::CLI::HumanReplies),
        supervisor: Lain::Supervisor::Null, role_spawn:, root: @root, cwd: @root,
        chronicle: Lain::CLI::Chronicle::Null.new, library: Lain::Skill::Library.load(root: @root),
        status_feed: instance_double(Lain::StatusFeed), model_switch: instance_double(Lain::Context::ModelSwitch),
        mode_switch: instance_double(Lain::Mode::Switch), ledger: Lain::Sensitivity::Ledger.new,
        sensitivity: Lain::Sensitivity::Policy.new(
          sensitivity: Lain::Sensitivity.new(home: Dir.tmpdir, cwd: @root)
        ),
        snapshots: instance_double(Lain::Agent::SnapshotSlot),
        window: Lain::CLI::Backend::WindowBook::Served.new(model: "probe", window_tokens: 32_768)
      )
    end
  end
end
