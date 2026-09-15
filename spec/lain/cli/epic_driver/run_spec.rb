# frozen_string_literal: true

require "async"

# An actor that settled, as the loop sees one: it is only ever asked for
# identity, because the loop retires it through the supervisor.
class RunSpecActor
  def initialize(id) = @id = id
  attr_reader :id
end

# The registry row a retirement is taken on, and the report it answers. The
# report's `sha` is what the loop judges by -- never its kind.
class RunSpecSupervisor
  Row = Data.define(:actor)

  # `live` is shared with the actors fake: an actor is live from its launch
  # until the retirement that ends it, so counting it in one object and
  # discounting it in the other is what makes the width bound observable.
  def initialize(reports, live, raising: [], log: [])
    @reports = reports
    @live = live
    @raising = raising
    @log = log
    @rows = []
    @retired = []
  end

  attr_reader :retired

  def adopt(row) = @rows << row

  def find(&block) = @rows.find(&block)

  def retire(row)
    @retired << row.actor.id
    # Shared with the grading seam's own log, so "graded BEFORE retired" is an
    # ordering fact rather than two counts that happen to agree.
    @log << [:retired, row.actor.id]
    @live[:now] -= 1
    raise Lain::Error, "the supervisor refused to retire #{row.actor.id}" if @raising.include?(row.actor.id)

    @reports.fetch(row.actor.id)
  end
end

# Launches an actor per issue, recording how many were live at each launch so
# the width bound is observable rather than inferred.
class RunSpecActors
  Launch = Data.define(:actor, :worker_id, :branch, :tests)

  def initialize(supervisor, live, refusals: {})
    @supervisor = supervisor
    @live = live
    @refusals = refusals
    @launched = []
    @concurrency = []
  end

  attr_reader :launched, :concurrency

  def call(issue_id, subject:, level: nil, attempt: 1) # rubocop:disable Lint/UnusedMethodArgument
    raise @refusals.fetch(issue_id) if @refusals.key?(issue_id)

    @launched << [issue_id, attempt]
    @live[:now] += 1
    @concurrency << @live[:now]
    actor = RunSpecActor.new(issue_id)
    @supervisor.adopt(RunSpecSupervisor::Row.new(actor:))
    Launch.new(actor:, worker_id: "issue.demo.#{issue_id}.#{attempt}", branch: "lain/issue/demo/#{issue_id}",
               tests: Lain::CLI::EpicDriver::IssueTests::Red.new(record: nil, run: nil, sha: "red-#{issue_id}"))
  end
end

# The issue's implementation gate. It answers whether the commit may land,
# which is the only thing the loop asks of it.
class RunSpecGate
  def initialize(parked: [], raising: [], delay: nil)
    @parked = parked
    @raising = raising
    @delay = delay
    @asked = []
  end

  attr_reader :asked

  def call(issue_id, sha:)
    @asked << [issue_id, sha]
    sleep(@delay) unless @delay.nil?
    raise Lain::Error, "#{issue_id}'s gate could not be asked" if @raising.include?(issue_id)

    !@parked.include?(issue_id)
  end
end

# The landing queue, as the loop drives it. `done` is the queue's own answer
# about whether the work actually reached the branch, and the loop must honour
# it rather than assuming a call that returned is a landing.
class RunSpecLanding
  Landed = Data.define(:issue_id, :sha, :report, :done)

  def initialize(statuses, done: true, raising: [], kind: :merged, detail: "")
    @statuses = statuses
    @done = done
    @raising = raising
    @kind = kind
    @detail = detail
    @landed = []
  end

  attr_reader :landed

  def call(issue_id, sha:, ref:)
    raise Lain::Error, "the landing queue refused #{issue_id}" if @raising.include?(issue_id)

    @landed << [issue_id, sha]
    @statuses[issue_id] = "done" if @done
    report = Lain::Isolation::WorkerHandoff::Report.new(kind: @kind, ref:, sha:, detail: @detail)
    [Landed.new(issue_id:, sha:, report:, done: @done)]
  end
end

# A landing that refuses, with the refusal the real queue would raise.
class RunSpecRefusingLanding
  def initialize(error) = @error = error

  def call(issue_id, sha:, ref:) = raise(@error) # rubocop:disable Lint/UnusedMethodArgument
end

# The epic's loop, over doubled collaborators: fold the epic, launch an issue
# actor per runnable issue up to a width, retire each as it settles, put the
# commit retirement anchored through that issue's implementation gate, and land
# it through the queue -- which is the only thing that merges.
#
# Every collaborator here is a fake and no git runs: what these examples are
# about is the ORDER and the REFUSALS, which is the whole of this object. The
# end-to-end run over a real repository is the seam spec beside it.
RSpec.describe Lain::CLI::EpicDriver::Run do
  # A real Progress over a real Graph, rebuilt per fold from the statuses the
  # fakes mutate: doubling the fold would let the loop's dependency rule pass
  # against an answer no epic could give.
  def progress_over(issues, statuses)
    lambda do
      graph = Lain::Epic::Graph.new(issues: issues.map { |issue| issue.with_status(statuses.fetch(issue.id)) })
      Lain::Epic::Progress.new(graph:, stage: Lain::Epic::Stage.new("implementation"), epic_slug: "demo", parked: [])
    end
  end

  def issue(id, blocks: [])
    Lain::Epic::Issue.new(id:, title: "the #{id} issue", blocks:,
                          criteria: "```gherkin\nScenario: s\n  Given g\n  When w\n  Then t\n```\n")
  end

  def anchored(sha) = Lain::Isolation::WorkerHandoff::Report.new(kind: :declined, ref: "refs/lain/worker/#{sha}", sha:)

  def plans = ->(_id) { Lain::CLI::EpicDriver::PlanSubject.new(subject: "app/models/order.rb") }

  # The REAL implementation gate over a real asker, which is what makes the
  # outstanding-set rule observable from up here.
  def gate_over(asker, timeout: 30)
    gate = Lain::Approval::Gate.new(journal: Lain::Journal.new(io: StringIO.new), timeout:)
    lambda do |issue_id, sha:|
      gate.call(Lain::Epic::Submission.implementation(slug: "demo", issue_id:, digest: sha),
                asker:, stage: "implementation", epic_slug: "demo", issue_id:)
    end
  end

  # A plan reader that refuses the issues named, the way reading a plan does.
  def plans_refusing(refusals)
    lambda do |id|
      raise refusals.fetch(id) if refusals.key?(id)

      plans.call(id)
    end
  end

  # The loop, assembled over the fakes an example set up.
  def run_over(issues:, statuses:, reports:, landing: nil, gate: RunSpecGate.new, refusals: {}, retiring: [],
               width: 2, budget: nil, attempts: nil, grading: nil, log: [], red_only: nil, subjects: plans)
    live = { now: 0 }
    supervisor = RunSpecSupervisor.new(reports, live, raising: retiring, log:)
    actors = RunSpecActors.new(supervisor, live, refusals:)
    settled = landing || RunSpecLanding.new(statuses)
    run = described_class.new(progress: progress_over(issues, statuses), plans: subjects, actors:, supervisor:, gate:,
                              landing: settled, width:, budget:,
                              red_only: red_only || described_class::Identical,
                              **(attempts ? { attempts: } : {}), **(grading ? { grading: } : {}))
    [run, actors, settled, supervisor]
  end

  describe "dependency order" do
    # a blocks b, and BOTH plans are approved, so both issues are in flight from
    # the start. b is not runnable until a's commit has landed and the fold
    # reports it done. The loop refolds after each landing, which is the whole
    # mechanism: nothing else makes b start.
    it "lands a before b's actor launches, and both end done" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      issues = [issue("a", blocks: ["b"]), issue("b")]
      run, actors, landing = run_over(issues:, statuses:,
                                      reports: { "a" => anchored("sha-a"), "b" => anchored("sha-b") })

      result = run.call

      expect(actors.launched.map(&:first)).to eq(%w[a b])
      expect(landing.landed).to eq([%w[a sha-a], %w[b sha-b]])
      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      expect(statuses.values).to all(eq("done"))
    end

    it "never launches an issue whose blocker is abandoned" do
      statuses = { "a" => "abandoned", "b" => "in_flight" }
      run, actors = run_over(issues: [issue("a", blocks: ["b"]), issue("b")], statuses:, reports: {})

      run.call

      expect(actors.launched).to be_empty
    end
  end

  describe "width" do
    it "bounds how many actors are live at once" do
      statuses = %w[a b c].to_h { |id| [id, "in_flight"] }
      reports = %w[a b c].to_h { |id| [id, anchored("sha-#{id}")] }
      run, actors = run_over(issues: %w[a b c].map { |id| issue(id) }, statuses:, reports:, width: 2)

      run.call

      expect(actors.concurrency.max).to eq(2)
      expect(actors.launched.map(&:first)).to contain_exactly("a", "b", "c")
    end
  end

  # ONE WRITER FOR pending -> in_flight, and it is the plan approval
  # ({Epic::InFlight}), never this loop. A pending issue is one whose plan has
  # not been approved yet, and the landing would refuse it anyway, so it is
  # reported for the human to plan rather than launched.
  describe "an issue that is still pending" do
    it "is reported as waiting on its plan, and no actor launches for it" do
      statuses = { "a" => "in_flight", "c" => "pending" }
      run, actors, landing = run_over(issues: [issue("a"), issue("c")], statuses:,
                                      reports: { "a" => anchored("sha-a") })

      result = run.call

      expect(actors.launched.map(&:first)).to eq(["a"])
      expect(landing.landed).to eq([%w[a sha-a]])
      expect(result.reported.map(&:issue_id)).to eq(["c"])
      expect(result.reported.first.reason).to include("issue_plan")
    end
  end

  describe "an issue whose plan is not approved" do
    it "is reported as waiting on its plan, and no actor launches for it" do
      statuses = { "a" => "in_flight", "c" => "in_flight" }
      refusal = Lain::CLI::EpicSubmit::PlanNotApproved.new(%(issue "c"'s issue_plan carries no approval))
      run, actors = run_over(issues: [issue("a"), issue("c")], statuses:,
                             reports: { "a" => anchored("sha-a") }, refusals: { "c" => refusal })

      result = run.call

      expect(actors.launched.map(&:first)).to eq(["a"])
      expect(result.reported.map(&:issue_id)).to eq(["c"])
      expect(result.reported.first.reason).to include("issue_plan")
    end
  end

  # A refused launch takes no room, so the fill offers the next startable issue
  # in its place: a run whose every launch in one fill refused would otherwise
  # have nothing live to settle, and stop with approved issues never mentioned.
  describe "a refused launch" do
    def no_subject = Lain::Error.new("the plan for a declares no test subject")

    it "reports the refused issue and launches the next one" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      run, actors, landing = run_over(issues: [issue("a"), issue("b")], statuses:,
                                      reports: { "b" => anchored("sha-b") }, width: 1,
                                      subjects: plans_refusing("a" => no_subject))

      result = run.call

      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.reported.first.reason).to include("declares no test subject")
      expect(actors.launched.map(&:first)).to eq(["b"])
      expect(landing.landed).to eq([%w[b sha-b]])
    end

    # Three issues survive the refusals at width 2, so a fill that stopped
    # counting room would have all three live at once.
    it "keeps refilling past several refusals without ever exceeding the width" do
      ids = %w[a b c d e f]
      statuses = ids.to_h { |id| [id, "in_flight"] }
      reports = ids.to_h { |id| [id, anchored("sha-#{id}")] }
      refusals = %w[a b d].to_h { |id| [id, Lain::Error.new("the plan for #{id} declares no test subject")] }
      run, actors = run_over(issues: ids.map { |id| issue(id) }, statuses:, reports:, width: 2,
                             subjects: plans_refusing(refusals))

      result = run.call

      expect(actors.launched.map(&:first)).to eq(%w[c e f])
      expect(actors.concurrency.max).to eq(2)
      expect(result.reported.map(&:issue_id)).to contain_exactly("a", "b", "d")
      expect(result.landed.map(&:issue_id)).to contain_exactly("c", "e", "f")
    end

    # The refill offers only what the fold calls startable: approving the plan
    # is the one writer of pending -> in_flight, never this loop.
    it "never starts a pending issue in a refused one's place" do
      statuses = { "a" => "in_flight", "c" => "pending" }
      run, actors = run_over(issues: [issue("a"), issue("c")], statuses:, reports: {}, width: 1,
                             subjects: plans_refusing("a" => no_subject))

      result = run.call

      expect(actors.launched).to be_empty
      expect(result.reported.map(&:issue_id)).to contain_exactly("a", "c")
    end
  end

  # A journal the loop cannot read is nobody's issue in particular: every
  # plan read would meet the same damage, so it ends the run rather than being
  # reported once per issue.
  describe "a sign-off journal that cannot be read" do
    [Lain::CLI::SessionJournals::Unreadable.new("the session journal x.ndjson is damaged at line 1"),
     Lain::Approval::SignoffQueue::UnreadableRecord.new("the gate_decision record cannot be read")].each do |torn|
      it "refuses the whole run over #{torn.class.name.split("::").last}, and launches nothing" do
        statuses = { "a" => "in_flight", "b" => "in_flight" }
        run, actors = run_over(issues: [issue("a"), issue("b")], statuses:, reports: {}, width: 1,
                               subjects: plans_refusing("a" => torn))

        expect { run.call }.to raise_error(torn.class, torn.message)
        expect(actors.launched).to be_empty
      end
    end

    # A Result that already carries a landing survives whatever comes after it:
    # the work is on the branch, so the reply has to say so, and the damage
    # ends the run in words instead.
    def torn_record = Lain::Approval::SignoffQueue::UnreadableRecord.new("the gate_decision record cannot be read")

    it "ends the run in words, keeping what already landed, when a later plan read meets it" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      run, actors, landing = run_over(issues: [issue("a", blocks: ["b"]), issue("b")], statuses:,
                                      reports: { "a" => anchored("sha-a"), "b" => anchored("sha-b") }, width: 1,
                                      subjects: plans_refusing("b" => torn_record))

      result = run.call

      expect(landing.landed).to eq([%w[a sha-a]])
      expect(actors.launched.map(&:first)).to eq(["a"])
      expect(result.landed.map(&:issue_id)).to eq(["a"])
      expect(result.stopped).to include("the gate_decision record cannot be read")
      expect(result.to_s).to include("landed a at sha-a", "the gate_decision record cannot be read")
    end

    # At width 2 a sibling is still working when the refill meets the damage:
    # it is reported as left where it stood, never silently dropped.
    it "strands a sibling still live, reports it, and keeps the landing" do
      statuses = { "a" => "in_flight", "b" => "in_flight", "c" => "in_flight" }
      run, actors, landing, supervisor = run_over(issues: [issue("a"), issue("b"), issue("c")], statuses:,
                                                  reports: { "a" => anchored("sha-a"), "b" => anchored("sha-b") },
                                                  width: 2, subjects: plans_refusing("c" => torn_record))

      result = run.call

      expect(actors.launched.map(&:first)).to eq(%w[a b])
      expect(landing.landed).to eq([%w[a sha-a]])
      expect(supervisor.retired).to eq(["a"])
      expect(result.landed.map(&:issue_id)).to eq(["a"])
      expect(result.reported.map { |entry| [entry.issue_id, entry.reason] }).to eq([["b", described_class::UNSETTLED]])
      expect(result.stopped).to start_with("the run stopped because a session journal could not be read")
      expect(Ractor.shareable?(result)).to be(true)
    end

    it "ends the run in words, keeping what already landed, when a later fold meets it" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      folds = progress_over([issue("a"), issue("b")], statuses)
      torn = Lain::CLI::SessionJournals::Unreadable.new("the session journal x.ndjson is damaged at line 9")
      live = { now: 0 }
      supervisor = RunSpecSupervisor.new({ "a" => anchored("sha-a") }, live)
      run = described_class.new(progress: -> { statuses.value?("done") ? raise(torn) : folds.call }, plans:,
                                actors: RunSpecActors.new(supervisor, live), supervisor:, gate: RunSpecGate.new,
                                landing: RunSpecLanding.new(statuses), width: 1, red_only: described_class::Identical)

      result = run.call

      expect(result.landed.map(&:issue_id)).to eq(["a"])
      expect(result.stopped).to include("damaged at line 9")
    end
  end

  describe "the gate" do
    it "lands nothing for an issue whose implementation gate parked" do
      statuses = { "a" => "in_flight" }
      run, _actors, landing = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("sha-a") },
                                       gate: RunSpecGate.new(parked: ["a"]))

      result = run.call

      expect(landing.landed).to be_empty
      expect(result.landed).to be_empty
      expect(result.reported.first.reason).to include("implementation gate")
      expect(statuses.fetch("a")).to eq("in_flight")
    end
  end

  # A caller building the loop directly must choose how "committed no work"
  # is judged: SHA equality is blind to a rebase, so it is never implied.
  it "requires a red-step judge, rather than defaulting to comparing SHAs" do
    expect { described_class.new(progress: -> {}, plans:, actors: nil, supervisor: nil, gate: nil, landing: nil) }
      .to raise_error(ArgumentError, /red_only/)
  end

  describe "a settled actor that committed nothing" do
    it "is reported and its issue stops, with nothing submitted and nothing landed" do
      statuses = { "a" => "in_flight" }
      empty = Lain::Isolation::WorkerHandoff::Report.new(kind: :nothing_to_do, ref: nil, sha: nil)
      run, _actors, landing = run_over(issues: [issue("a")], statuses:, reports: { "a" => empty })

      result = run.call

      expect(landing.landed).to be_empty
      expect(result.reported.first.issue_id).to eq("a")
      expect(result.reported.first.reason).to include("committed nothing")
    end

    # Retirement anchors whatever the branch holds, and an actor that made no
    # commit of its own leaves the red step's commit there. Gating that would
    # ask a human to approve an implementation made of failing tests.
    it "reports an issue whose only commit is its red step's as having committed no work, and opens no gate" do
      statuses = { "a" => "in_flight" }
      gate = RunSpecGate.new
      run, _actors, landing = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("red-a") }, gate:)

      result = run.call

      expect(gate.asked).to be_empty
      expect(landing.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.reported.first.reason).to include("committed no work", "red-a")
      expect(statuses.fetch("a")).to eq("in_flight")
    end

    # Whether a retired tip carries anything past the red commit is a question
    # about content, which the loop asks and does not answer itself.
    it "asks its red-step judge about the tip it retired, and opens no gate when the judge finds only red" do
      statuses = { "a" => "in_flight" }
      gate = RunSpecGate.new
      asked = []
      red_only = lambda do |red, tip|
        asked << [red, tip]
        tip == "rebased-red-a"
      end
      run, _actors, landing = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("rebased-red-a") },
                                       gate:, red_only:)

      result = run.call

      expect(asked).to eq([%w[red-a rebased-red-a]])
      expect(gate.asked).to be_empty
      expect(landing.landed).to be_empty
      expect(result.reported.first.reason).to include("committed no work")
    end

    it "reports a retirement the standing anchor refused, and stops that issue" do
      statuses = { "a" => "in_flight" }
      refused = Lain::Isolation::WorkerHandoff::Report.new(kind: :failed, ref: nil, sha: nil,
                                                           detail: "already anchors work")
      run, _actors, landing = run_over(issues: [issue("a")], statuses:, reports: { "a" => refused })

      result = run.call

      expect(landing.landed).to be_empty
      expect(result.reported.first.issue_id).to eq("a")
    end
  end

  # ONE ISSUE'S REFUSAL STOPS THAT ISSUE, NEVER THE RUN. Everything after the
  # launch -- the retirement, the gate, the landing -- can refuse, and the
  # Result has to survive every one of them carrying whatever already landed.
  describe "a refusal on the settle side" do
    it "keeps the run going and keeps what already landed when the landing queue refuses" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "a" => anchored("sha-a"), "b" => anchored("sha-b") }
      landing = RunSpecLanding.new(statuses, raising: ["a"])
      run, actors = run_over(issues: [issue("a"), issue("b")], statuses:, reports:, landing:, width: 1)

      result = run.call

      expect(actors.launched.map(&:first)).to eq(%w[a b])
      expect(result.landed.map(&:issue_id)).to eq(["b"])
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.stopped).to be_nil
    end

    it "keeps the run going when the retirement itself refuses" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "b" => anchored("sha-b") }
      run, _actors, landing = run_over(issues: [issue("a"), issue("b")], statuses:, reports:, retiring: ["a"],
                                       width: 1)

      result = run.call

      expect(landing.landed).to eq([%w[b sha-b]])
      expect(result.reported.map(&:issue_id)).to eq(["a"])
    end

    it "keeps the run going when the gate itself refuses" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "a" => anchored("sha-a"), "b" => anchored("sha-b") }
      run, _actors, landing = run_over(issues: [issue("a"), issue("b")], statuses:, reports:, width: 1,
                                       gate: RunSpecGate.new(raising: ["a"]))

      result = run.call

      expect(landing.landed).to eq([%w[b sha-b]])
      expect(result.reported.map(&:issue_id)).to eq(["a"])
    end

    # A crash between the retirement and the landing leaves the work anchored
    # and off the branch, and a rerun cannot finish it -- the anchor stands, so
    # the issue's own retry is refused. The reply has to name the way out.
    it "names `lain epic land --resume` when the work was anchored but never landed" do
      statuses = { "a" => "in_flight" }
      landing = RunSpecLanding.new(statuses, raising: ["a"])
      run, = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("sha-a") }, landing:)

      result = run.call

      expect(result.reported.first.reason).to include("lain epic land", "--resume", "a")
    end
  end

  # HONOUR THE QUEUE'S ANSWER. A conflicted landing did not put the work on the
  # branch, so it is not a landing: it must not be counted, must not spend the
  # budget, and must say what actually happened.
  describe "a landing that did not move the work" do
    it "is not counted as landed, and says the conflict stands" do
      statuses = { "a" => "in_flight" }
      landing = RunSpecLanding.new(statuses, done: false, kind: :conflicted,
                                             detail: "the conflict stands; the work waits on its ref")
      run, = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("sha-a") }, landing:)

      result = run.call

      expect(result.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.to_s).not_to include("landed a")
      expect(statuses.fetch("a")).to eq("in_flight")
    end

    it "does not spend the budget on it" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "a" => anchored("sha-a"), "b" => anchored("sha-b") }
      landing = RunSpecLanding.new(statuses, done: false, kind: :conflicted)
      run, actors = run_over(issues: [issue("a"), issue("b")], statuses:, reports:, landing:, width: 1, budget: 1)

      run.call

      expect(actors.launched.map(&:first)).to eq(%w[a b])
    end
  end

  describe "the whole-run budget" do
    it "stops the loop cleanly once it is spent, naming the budget" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "a" => anchored("sha-a"), "b" => anchored("sha-b") }
      run, _actors, landing = run_over(issues: [issue("a"), issue("b")], statuses:, reports:, width: 1, budget: 1)

      result = run.call

      expect(landing.landed.size).to eq(1)
      expect(result.stopped).to include("budget")
      expect(result.to_s).to include("budget")
    end
  end

  describe "the interrupt" do
    it "stops between issues when the interrupt says the run is over" do
      statuses = { "a" => "in_flight", "b" => "in_flight" }
      reports = { "a" => anchored("sha-a"), "b" => anchored("sha-b") }
      live = { now: 0 }
      supervisor = RunSpecSupervisor.new(reports, live)
      actors = RunSpecActors.new(supervisor, live)
      landing = RunSpecLanding.new(statuses)
      interrupted = false
      run = described_class.new(progress: progress_over([issue("a"), issue("b")], statuses), plans:, actors:,
                                supervisor:, gate: RunSpecGate.new, landing:, width: 1,
                                red_only: described_class::Identical, interrupt: -> { interrupted })

      allow(landing).to receive(:call).and_wrap_original do |original, *args, **options|
        interrupted = true
        original.call(*args, **options)
      end
      result = run.call

      expect(landing.landed.size).to eq(1)
      expect(result.stopped).to include("interrupt")
    end

    # A Ctrl-C at 3am must not wait out a 300-second gate: the interrupt is
    # checked WHILE the gate waits, not only between issues.
    it "stops during a gate wait rather than waiting it out" do
      statuses = { "a" => "in_flight" }
      live = { now: 0 }
      supervisor = RunSpecSupervisor.new({ "a" => anchored("sha-a") }, live)
      actors = RunSpecActors.new(supervisor, live)
      landing = RunSpecLanding.new(statuses)
      interrupted = false

      elapsed = Sync do |task|
        run = described_class.new(progress: progress_over([issue("a")], statuses), plans:, actors:, supervisor:,
                                  gate: RunSpecGate.new(delay: 30), landing:, width: 1,
                                  red_only: described_class::Identical,
                                  interrupt: -> { interrupted })
        task.async do
          sleep 0.2
          interrupted = true
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @result = run.call
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      expect(elapsed).to be < 10
      expect(landing.landed).to be_empty
      expect(@result.stopped).to include("interrupt")
    end

    # AN INTERRUPTED WAIT STILL WITHDRAWS. Stopping the gate's fiber unwinds it
    # at its await, so a withdrawal that ran only after the answer would never
    # run at all -- and the asker admits ONE outstanding set, so the NEXT run's
    # first gate would be refused as outstanding for the life of that asker.
    # Production is shielded only because the one wired interrupt closes the
    # Repl; the seam is injected, so a bench driving several arms over one asker
    # is exactly where this bites.
    it "leaves the asker free for the next run's first gate" do
      asker = Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty(store: Lain::Store.new) })
      statuses = { "a" => "in_flight" }
      interrupted = false

      Sync do |task|
        live = { now: 0 }
        supervisor = RunSpecSupervisor.new({ "a" => anchored("sha-a") }, live)
        run = described_class.new(progress: progress_over([issue("a")], statuses), plans:,
                                  actors: RunSpecActors.new(supervisor, live), supervisor:,
                                  gate: gate_over(asker), landing: RunSpecLanding.new(statuses), width: 1,
                                  red_only: described_class::Identical,
                                  interrupt: -> { interrupted })
        task.async do
          sleep 0.2
          interrupted = true
        end
        run.call
      end

      expect(asker).not_to be_pending
      expect { Sync { asker.ask("the next run's first gate?") } }.not_to raise_error
    end
  end

  # THE ATTEMPT COMES FROM THE REPOSITORY, so a retry after a failed attempt
  # launches under the next id instead of being refused by the anchor the first
  # one left standing.
  describe "the attempt" do
    it "launches under the attempt its reader answers" do
      statuses = { "a" => "in_flight" }
      run, actors = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("sha-a") },
                             attempts: ->(_id) { 3 })

      run.call

      expect(actors.launched).to eq([["a", 3]])
    end
  end

  # DO NOT SEND A HUMAN TO A COMMAND THAT WILL REFUSE. `--resume` finishes a
  # merge that happened and was journaled; for a refusal raised BEFORE anything
  # merged there is nothing to resume, and `lain epic land --resume` would
  # answer that there is no landing to resume. So the resume sentence is said only when the work is
  # anchored and unmerged, and a refusal reports itself instead -- its own
  # message already names what would clear it.
  describe "a landing refused before anything merged" do
    def refused_by(error)
      statuses = { "a" => "in_flight" }
      run, = run_over(issues: [issue("a")], statuses:, reports: { "a" => anchored("sha-a") },
                      landing: RunSpecRefusingLanding.new(error))
      run.call.reported.first.reason
    end

    it "reports misplaced tests without offering a resume that would refuse" do
      reason = refused_by(Lain::Forge::LocalLanding::MisplacedTests.new("it belongs at spec/unit/models/order_spec.rb"))

      expect(reason).to include("spec/unit/models/order_spec.rb")
      expect(reason).not_to include("--resume")
    end

    it "reports an unapproved commit without offering a resume that would refuse" do
      reason = refused_by(Lain::Approval::Gate::NotApproved.new("issue a's implementation gate has not approved"))

      expect(reason).to include("implementation gate")
      expect(reason).not_to include("--resume")
    end

    it "reports a commit already on the branch without offering a resume that would refuse" do
      reason = refused_by(Lain::Forge::LocalLanding::AlreadyOnBranch.new("already on epic/demo"))

      expect(reason).to include("already on epic/demo")
      expect(reason).not_to include("--resume")
    end

    # The genuine stranding: the merge was under way and something broke, so the
    # work IS anchored and unmerged and `--resume` is exactly the way out.
    it "still names the resume when the failure came after the merge began" do
      reason = refused_by(RuntimeError.new("power cut mid-merge"))

      expect(reason).to include("lain epic land", "--resume", "a")
    end
  end

  # The hook a bench binds its grader to. Retirement anchors, stops the actor
  # and RELEASES its lease -- which removes the checkout -- so anything that
  # judges an issue by running its tests has exactly one moment to do it: after
  # the actor has settled, before it is retired.
  describe "grading, between an actor settling and its retirement" do
    def grading_into(log) = ->(issue_id, _row) { log << [:graded, issue_id] }

    it "grades an issue before that issue is retired" do
      log = []
      run, = run_over(issues: [issue("a")], statuses: { "a" => "in_flight" },
                      reports: { "a" => anchored("sha-a") }, grading: grading_into(log), log:)

      run.call

      expect(log).to eq([[:graded, "a"], [:retired, "a"]])
    end

    # The row is what carries the lease, so the seam can reach the checkout the
    # actor worked in rather than being handed a path somebody guessed.
    it "hands the seam the issue id and the registry row the lease rides on" do
      seen = []
      run, = run_over(issues: [issue("a")], statuses: { "a" => "in_flight" },
                      reports: { "a" => anchored("sha-a") },
                      grading: ->(issue_id, row) { seen << [issue_id, row] })

      run.call

      expect(seen.map(&:first)).to eq(["a"])
      expect(seen.first.last).to respond_to(:actor)
    end

    it "grades every issue the run carries, each before its own retirement" do
      log = []
      run, = run_over(issues: [issue("a"), issue("b")],
                      statuses: { "a" => "in_flight", "b" => "in_flight" },
                      reports: { "a" => anchored("sha-a"), "b" => anchored("sha-b") },
                      grading: grading_into(log), log:)

      run.call

      expect(log).to eq([[:graded, "a"], [:retired, "a"], [:graded, "b"], [:retired, "b"]])
    end

    # Nobody is benching an ordinary `/implement-epic` run, so the default
    # grades nothing and the loop behaves exactly as it did before the seam.
    it "grades nothing, and lands as usual, when no seam is given" do
      run, = run_over(issues: [issue("a")], statuses: { "a" => "in_flight" },
                      reports: { "a" => anchored("sha-a") })

      expect(run.call.landed.map(&:issue_id)).to eq(["a"])
    end

    # One issue's grader blowing up must not take the run down with it: the
    # rest of the loop is somebody else's landing.
    it "stops only that issue when the grader itself raises" do
      run, = run_over(issues: [issue("a")], statuses: { "a" => "in_flight" },
                      reports: { "a" => anchored("sha-a") },
                      grading: ->(*) { raise Lain::Error, "the grader could not run the suite" })

      result = run.call

      expect(result.landed).to be_empty
      expect(result.reported.map(&:reason).join).to include("the grader could not run the suite")
    end
  end

  describe "the reply" do
    it "lists what landed and what is still waiting" do
      statuses = { "a" => "in_flight", "c" => "in_flight" }
      refusal = Lain::CLI::EpicSubmit::PlanNotApproved.new(%(issue "c"'s issue_plan carries no approval))
      run, = run_over(issues: [issue("a"), issue("c")], statuses:, reports: { "a" => anchored("sha-a") },
                      refusals: { "c" => refusal })

      rendered = run.call.to_s

      expect(rendered).to include("a", "sha-a", "c")
    end

    # Every value object here is deeply frozen, like every other one in lain.
    it "answers a Result nothing can mutate" do
      statuses = { "a" => "in_flight", "c" => "in_flight" }
      refusal = Lain::CLI::EpicSubmit::PlanNotApproved.new(%(issue "c"'s issue_plan carries no approval))
      run, = run_over(issues: [issue("a"), issue("c")], statuses:, reports: { "a" => anchored("sha-a") },
                      refusals: { "c" => refusal })

      expect(Ractor.shareable?(run.call)).to be(true)
    end
  end
end
