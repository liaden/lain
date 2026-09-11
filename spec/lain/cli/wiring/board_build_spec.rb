# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# The unit's own seam. {Lain::CLI::Wiring} drives this module with everything
# defaulted, so the production assertions live beside that assembler in
# wiring_spec.rb; what belongs HERE is the `paths:` injection Wiring does not
# expose, and the vocabularies the module exists to keep apart -- approval
# rules, the path boundary, and the shell verdict, which is the one it builds
# and hands back rather than keeps.
RSpec.describe Lain::CLI::Wiring::BoardBuild do
  # A REAL journal behind the chronicle, because the production-path examples
  # below read the ladder's own record: "which rung refused, and what it said"
  # is the assertion, and {Chronicle::Null} writes it to the null device.
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
  # A REAL Toolset, for switchboard_spec's reason: the ladder's deterministic
  # rung reads the tier off the live capability set, so a call that is not
  # gated at all never reaches a rung and every example here would pass vacuously.
  let(:toolset) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

  def in_tree(config: nil)
    Dir.mktmpdir("lain-board-build") do |dir|
      base = File.realpath(dir)
      root = File.join(base, "repo")
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "config.toml"), config) if config
      yield(root, File.join(base, "home"))
    end
  end

  def project_at(root, cwd = root) = Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag)

  def paths_at(home) = Lain::Paths.new(env: { "HOME" => home })

  # `.classifier` takes the COMPILED table rather than a `notice:` of its own:
  # the file is parsed once, by `.for`, and handed to all three readers. This
  # composes the two the way `.for` does, so the examples below still drive the
  # real "what does a broken config cost" behaviour.
  def classifier_at(root, home, notice: nil, cwd: root)
    project = project_at(root, cwd)
    described_class.classifier(project:, paths: paths_at(home),
                               table: described_class.rules(project:, notice:))
  end

  def board_for(root, home, options: {}, **rest)
    described_class.for(chronicle:, options:, model: "m", toolset:, project: project_at(root),
                        paths: paths_at(home), **rest)
  end

  # What {Lain::CLI::Wiring} does: ONE verdict, read off this project's config,
  # handed to the board here and to the bash tool at the other seam. Spelled
  # out at every call site that needs it rather than defaulted inside `.for`,
  # because the whole point of the object is that the toolset holds the SAME
  # instance and a default built here could not be shared.
  def board_over(root, home, notice: nil, **rest)
    board_for(root, home, verdict: described_class.shell_verdict(project: project_at(root), notice:), **rest)
  end

  def read_of(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

  def bash_of(command, **rest)
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => command }.merge(rest))
  end

  def rulings = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  # The ladder BLOCKS on the queue when every deterministic rung abstains, which
  # is itself the assertion for two of these examples. Driven the way
  # switchboard_spec drives it: the call runs in a task, the pending is drained
  # so the ask is observable, and the task is stopped rather than answered.
  def while_parked(board, effect)
    Sync do |task|
      call = task.async { board.policy_switch.call(effect, nil) }
      task.with_timeout(1) { board.approvals.dequeue }
      yield
    ensure
      call&.stop
    end
  end

  describe ".classifier" do
    it "anchors the home-relative table at the INJECTED home, not the process's" do
      in_tree do |root, home|
        classifier = classifier_at(root, home)

        expect(classifier.denied?(File.join(home, ".kube", "config"))).to be(true)
        expect(classifier.denied?(File.join(Dir.home, ".kube", "config"))).to be(false)
      end
    end

    # The `cwd:` half of the same injection, and the one the panel found
    # mattered: a relative path is joined LEXICALLY to the project's cwd, so a
    # tool call written the way a model writes one still classifies.
    #
    # The `.env` line alone does NOT see cwd -- it is a BASENAME rule, so it
    # answers gated at any cwd whatever, and mutating `cwd: project.cwd` to
    # `paths.home` survives it. `.kube/config` is the discriminator: it is a
    # HOME-ANCHORED rule, so resolving this relative path against the project's
    # cwd puts it outside home and ordinary, while resolving it against home
    # would deny it. One assertion, and it is the only one here that can tell
    # which directory the classifier was given.
    it "resolves a relative path against the project's cwd" do
      in_tree do |root, home|
        cwd = File.join(root, "services")
        FileUtils.mkdir_p(cwd)
        classifier = classifier_at(root, home, cwd:)

        expect(classifier.gated?(".env")).to be(true)
        expect(classifier.classify(".kube/config").reason).to eq(:none)
      end
    end

    it "compiles the project's own [sensitivity] table into the rules" do
      in_tree(config: "[sensitivity]\ndenied = [\"*.secret\"]\n") do |root, home|
        classifier = classifier_at(root, home)

        expect(classifier.classify(File.join(root, "prod.secret")).reason).to eq(:configured)
      end
    end

    # Loud, and unrescued: this table RESTRICTS, so a session that ran with it
    # silently un-parsed would be running with the project's denials off.
    it "refuses a malformed table by name, and names the file" do
      in_tree(config: "sensitivity = \"strict\"\n") do |root, home|
        expect { classifier_at(root, home) }
          .to raise_error(Lain::Sensitivity::Rules::NotATable, /config\.toml.*must be a table/)
      end
    end

    # The other side of that asymmetry, and the regression it exists to prevent:
    # a typo in a table this class never reads must cost that table's feature
    # and NOT the session. `[epics]` is the neighbour with the loudest refusal,
    # so it is the one worth pinning.
    it "is unmoved by a typo in a table it does not read" do
      in_tree(config: %(epics = "not a table"\n\n[sensitivity]\ndenied = ["*.secret"]\n)) do |root, home|
        classifier = classifier_at(root, home)

        expect(classifier.classify(File.join(root, "prod.secret")).reason).to eq(:configured)
      end
    end

    # A file nobody can parse costs the project its ADDITIONS and says so; the
    # built-in tables are unaffected, because they were never in the file. Told
    # rather than dropped -- silence here would be a boundary quietly narrowing.
    it "degrades to the built-in rules when the file will not parse, and reports it" do
      in_tree(config: "this is not [valid toml") do |root, home|
        said = []
        classifier = classifier_at(root, home, notice: ->(message) { said << message })

        expect(classifier.classify(File.join(home, ".ssh", "id_rsa")).reason).to eq(:protected)
        expect(said.join).to match(/\[sensitivity\].*not in force/)
      end
    end

    it "stays silent about a file that parses" do
      in_tree(config: %([sensitivity]\ndenied = ["*.secret"]\n)) do |root, home|
        said = []
        classifier_at(root, home, notice: ->(message) { said << message })

        expect(said).to be_empty
      end
    end
  end

  describe ".for" do
    it "hands the board a live policy rather than the Null" do
      in_tree do |root, home|
        board = board_for(root, home)

        expect(board.sensitivity).not_to equal(Lain::Sensitivity::Policy::Null.instance)
        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")))).to be(true)
      end
    end

    # The two vocabularies, asserted apart. A project that RESTRICTS paths and
    # grants no call shapes must come back with a live path boundary and NO
    # remembered answer -- the `[sensitivity]` table must never arrive at the
    # deterministic rung as one. The term-approval rule is unconditional and is
    # the whole chain here, which is what makes its absence readable.
    it "keeps the sensitivity table out of the approval rung" do
      in_tree(config: "[sensitivity]\ndenied = [\"*.secret\"]\n") do |root, home|
        board = board_for(root, home)

        expect(board.instance_variable_get(:@rules).map(&:name)).to eq(%w[composed_term])
        expect(board.sensitivity.denial(read_of(File.join(root, "a.secret")))&.reason).to eq(:configured)
      end
    end
  end

  # The third config-derived authority this module builds, and the only one it
  # does not keep: the session's {Lain::Shell::Verdict} is handed BACK to
  # {Lain::CLI::Wiring}, which gives the same instance to the board here and to
  # the bash tool through {Lain::CLI::Wiring::ToolsetBuild}. It is built here
  # because this is where a project's config is read, and its refusal postures
  # have to match `.rules`' -- a table that RESTRICTS is loud about a typo, and
  # a file nobody can parse costs the project its additions and says so.
  # The `[tests]` table restricts where a test may be written, and a table the
  # project wrote wrong must not take a chat down with it: enforcement is
  # opt-in, so the honest degradation is "no layout", said out loud.
  describe ".test_layout" do
    def run_at(root, notice: nil) = described_class.test_layout(project: project_at(root), notice:)

    it "holds the project to the layout its [tests] table declares" do
      in_tree(config: "[tests]\npreset = \"rspec\"\nsource_roots = [\"app\"]\n") do |root, _home|
        told = []

        expect(run_at(root, notice: told.method(:push)).guard.layout.in_force?).to be(true)
        expect(told).to be_empty
      end
    end

    it "holds a project with no [tests] table to nothing, silently" do
      in_tree(config: "[shell]\ndeny = []\n") do |root, _home|
        told = []

        expect(run_at(root, notice: told.method(:push)).guard.layout).to be(Lain::TestLayout::None)
        expect(told).to be_empty
      end
    end

    it "ignores a malformed [tests] table and tells the human so, rather than refusing the chat" do
      in_tree(config: "[tests]\nprest = \"rspec\"\n") do |root, _home|
        told = []

        expect(run_at(root, notice: told.method(:push)).guard.layout).to be(Lain::TestLayout::None)
        expect(told.join).to include("[tests]", "prest")
      end
    end

    # `.for` is what a chat reaches, so the run it builds is the board's.
    it "hands the board the project's layout, which every tool guard reads" do
      in_tree(config: "[tests]\npreset = \"rspec\"\nsource_roots = [\"app\"]\n") do |root, home|
        expect(board_for(root, home).test_layout.guard.layout.in_force?).to be(true)
      end
    end

    it "tells the human through the board's notice seam when the table is malformed" do
      in_tree(config: "[tests]\nprest = \"rspec\"\n") do |root, home|
        told = []

        board = board_for(root, home, notice: told.method(:push))

        expect(board.test_layout.layout).to be(Lain::TestLayout::None)
        expect(told.join).to include("[tests]", "ignored")
      end
    end

    it "ignores a file that will not parse, and says so" do
      in_tree(config: "[tests\n") do |root, _home|
        told = []

        expect(run_at(root, notice: told.method(:push)).guard.layout).to be(Lain::TestLayout::None)
        expect(told.join).to include("[tests]")
      end
    end
  end

  describe ".shell_verdict" do
    def verdict_at(root, notice: nil) = described_class.shell_verdict(project: project_at(root), notice:)

    it "compiles the project's own [shell] table into the capability set" do
      in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root, _home|
        expect(verdict_at(root).call("curl http://example.com")).to be_deny
      end
    end

    # The other half of the same question: a project that says nothing
    # restricts nothing, so a session with no config behaves exactly as it did
    # before the table existed.
    it "restricts no program when the project has no table" do
      in_tree do |root, _home|
        expect(verdict_at(root).call("curl http://example.com")).to be_allow
      end
    end

    # Loud, and unrescued, on `.rules`' argument for the `[sensitivity]` table:
    # this one RESTRICTS, so a session running with it silently un-parsed would
    # be running with the project's refusals off.
    it "refuses a malformed [shell] table by name, and names the file" do
      in_tree(config: %([shell]\nexclude = "curl"\n)) do |root, _home|
        expect { verdict_at(root) }
          .to raise_error(Lain::Shell::Exclusions::NotAList, /config\.toml.*list of program names/)
      end
    end

    # The other side of that asymmetry, and `.rules`' exact posture: a file
    # nobody can parse costs the project its ADDITIONS and is SAID, because
    # taking `lain chat` down over an unrelated syntax error is a regression a
    # user meets mid-task.
    it "degrades to restricting nothing when the file will not parse, and reports it" do
      in_tree(config: "this is not [valid toml") do |root, _home|
        said = []

        verdict = verdict_at(root, notice: ->(message) { said << message })

        expect(verdict.call("curl http://example.com")).to be_allow
        expect(said.join).to match(/\[shell\].*not in force/)
      end
    end

    it "stays silent about a file that parses" do
      in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root, _home|
        said = []
        verdict_at(root, notice: ->(message) { said << message })

        expect(said).to be_empty
      end
    end
  end

  # What this chunk's spine buys, driven through the REAL construction path: a
  # program a project ruled out becomes a NAMED REFUSAL where there was a
  # prompt. `Shell::Verdict`'s `capability_set` has existed, unwired, since it
  # was written -- `AnyProgram` permits everything and nothing in lib/ ever
  # built another -- so these examples are what make the deny path reachable in
  # production for the first time.
  describe "the project's [shell] exclusions, on the production path" do
    it "denies an excluded program at the triage rung, naming it and the session's table" do
      in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root, home|
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("curl http://example.com"), nil)).to be(false)
        expect(rulings.first).to include("rung" => "triage", "verdict" => "deny", "faulted" => false)
        expect(rulings.first["reason"]).to include("curl", "the session's capability set excludes")
      end
    end

    # The half a human would otherwise lift. This rung answers BEFORE the
    # queue, so nothing parks and no surface is ever asked.
    it "parks no approval for a human, because the rung already answered" do
      in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root, home|
        board = board_over(root, home)
        board.policy_switch.call(bash_of("curl http://example.com"), nil)

        expect(board.approvals.each.count).to eq(0)
        expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage])
      end
    end

    # And the same command with no table parks exactly as it did before any of
    # this existed, with the ladder reading as it always has -- which is what
    # makes the deny above evidence about the TABLE rather than about the rung.
    it "leaves the same command parking when the project excludes nothing" do
      in_tree do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("curl http://example.com")) do
          expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage rules])
          expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
        end
      end
    end

    # The exclusion is gated on the parse having COVERED the command, and that
    # gate is the honest one: a denial names a program, and a parse that was
    # not understood has no reliable name to offer. So a loop mentioning `sh`
    # abstains to a human rather than claiming a refusal it cannot ground.
    it "abstains rather than denying on a command the parser could not read" do
      in_tree(config: %([shell]\nexclude = ["sh"]\n)) do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("for i in a; do sh; done")) do
          expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
        end
      end
    end

    # The same refusal one step further out: the word that would be asked about
    # is a substitution, so the name the parse reconstructs is not the name that
    # would run. Abstention is the only answer a denylist can honestly give.
    it "abstains when the program name is not one the parse stands behind" do
      in_tree(config: %([shell]\nexclude = ["sh"]\n)) do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("$(echo sh) -c hi")) do
          expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
        end
      end
    end

    # IDENTITY at the construction site, on the classifier example's shape and
    # for its reason: `verdict:` has a permissive default, so dropping the
    # argument at the one call site restores it and disarms the deny path with
    # a fully green suite.
    it "hands the triage rung the session's own verdict rather than the permissive default" do
      in_tree(config: %([shell]\nexclude = ["curl"]\n)) do |root, home|
        verdict = described_class.shell_verdict(project: project_at(root))
        board = board_for(root, home, verdict:)

        expect(board.ladder.first.instance_variable_get(:@verdict)).to be(verdict)
      end
    end
  end

  # The defect this whole group exists for: {Approval::Escalation::Triage}'s argv
  # check has been implemented and spec'd from the start and has never once run,
  # because nothing built a board that handed it a classifier. These examples
  # drive the REAL construction path -- `BoardBuild.for` and nothing injected --
  # so a call site that stops passing one goes red here rather than passing
  # everywhere and protecting nothing.
  describe "the triage rung's path classifier, on the production path" do
    def key_under(home) = File.join(home, ".ssh", "id_rsa")

    it "denies a bash call whose argv names a protected path, at the triage rung" do
      in_tree do |root, home|
        board = board_for(root, home)

        expect(board.policy_switch.call(bash_of("cat #{key_under(home)}"), nil)).to be(false)
        expect(rulings.first).to include("rung" => "triage", "verdict" => "deny", "faulted" => false)
        expect(rulings.first["reason"])
          .to include(key_under(home), Lain::Approval::Escalation::Triage::PROTECTED)
      end
    end

    # The other half of the same refusal, and the half a human would otherwise
    # lift: this rung answers BEFORE the queue, so nothing parks.
    it "parks no approval for a human, because the rung already answered" do
      in_tree do |root, home|
        board = board_for(root, home)
        board.policy_switch.call(bash_of("cat #{key_under(home)}"), nil)

        expect(board.approvals.each.count).to eq(0)
        expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage])
      end
    end

    it "leaves an ordinary command to park exactly as it did before" do
      in_tree do |root, home|
        board = board_for(root, home)

        while_parked(board, bash_of("ls -la")) do
          expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage rules])
          expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
        end
      end
    end

    # `cwd` is MODEL-CONTROLLED (`bash.rb:50`), so what the factory does with one
    # it cannot resolve IS the security question. Two answers are wrong and one
    # is right. Raising is a {Escalation::RUNG_BROKE} fault, and a fault turns
    # this deny into an abstention a human then approves. Falling back to
    # {Triage::AnyPath} protects nothing, which is the same disarm without the
    # fault -- and the call's cwd contributes NOTHING to classifying an absolute
    # path, so discarding the whole classifier over a bad one is over-broad
    # besides. The fallback is the SESSION's own classifier, anchored on `home`
    # and the project cwd, both of which come from the wiring.
    it "still denies a protected absolute path when the cwd cannot be resolved" do
      in_tree do |root, home|
        board = board_for(root, home)

        expect(board.policy_switch.call(bash_of("cat #{key_under(home)}", "cwd" => "bad\0dir"), nil)).to be(false)
        expect(rulings.first).to include("rung" => "triage", "verdict" => "deny", "faulted" => false)
        expect(board.approvals.each.count).to eq(0)
      end
    end

    # Every one of these is JSON a model can put in the `cwd` field, and the
    # factory has to stay TOTAL over all of them: nothing raises, nothing
    # faults, and none of them costs the refusal.
    it "denies under every hostile cwd shape a model can write, and raises on none" do
      in_tree do |root, home|
        board = board_for(root, home)
        hostile = ["bad\0dir", 42, { "a" => 1 }, true, "~nosuchuser999", [1], "",
                   (+"/tmp/\xC3\x28").force_encoding("UTF-8")]

        answers = hostile.map { |cwd| board.policy_switch.call(bash_of("cat #{key_under(home)}", "cwd" => cwd), nil) }

        expect(answers).to eq([false] * hostile.size)
        expect(rulings.map { |ruling| ruling["verdict"] }).to eq(["deny"] * hostile.size)
        expect(rulings.map { |ruling| ruling["faulted"] }).to eq([false] * hostile.size)
        expect(board.approvals.each.count).to eq(0)
      end
    end

    # A cwd it CAN resolve still anchors the relative words -- the fallback is a
    # fallback, not the whole behaviour.
    it "still anchors a relative word on the cwd the call named" do
      in_tree do |root, home|
        board = board_for(root, home)

        answer = board.policy_switch.call(bash_of("cat .kube/config", "cwd" => root), nil)

        expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain", "faulted" => false)
        # And what the abstention now COSTS, said out loud rather than left to a
        # discarded return value: anchored on the project root this path is
        # ordinary, so the term rule approves it with no human. Anchored on home
        # it would have DENIED at triage, which is what makes this the example
        # that can tell the two cwds apart.
        expect(answer).to be(true)
        expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
      end
    end

    # IDENTITY at the construction site, not merely behaviour, and on
    # tool_guard_spec's shape. The keyword has a default, and a default is how
    # this rung gets silently re-disarmed: deleting the argument from
    # `BoardBuild.for` restores {Triage::AnyPath} and every behavioural example
    # above still passes on a board that protects nothing.
    it "hands the triage rung a real classifier factory rather than the inert default" do
      in_tree do |root, home|
        board = board_for(root, home)
        triage = board.ladder.first
        factory = triage.instance_variable_get(:@sensitivity)

        expect(triage.name).to eq("triage")
        expect(factory).not_to be_a(Lain::Approval::Escalation::Triage::AnyPath)
        expect(factory).to be_a(described_class::Classifiers)
      end
    end
  end

  # The rung that can APPROVE, driven through a real assembled ladder rather
  # than against the rule. What is under test here is the WIRING: a rule built
  # but never appended, or appended holding a classifier that protects nothing,
  # passes every example in composed_term_spec.rb and decides nothing in a live
  # session -- which is how the three unwired guards in this codebase shipped.
  describe "the term-approval rule, on the production path" do
    it "approves a fully safe pipeline at the rules rung, with no human asked" do
      in_tree do |root, home|
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("cat README.md | head -20", "cwd" => root), nil)).to be(true)
        expect(rulings.last).to include("rung" => "rules", "verdict" => "allow", "faulted" => false)
        expect(rulings.last["reason"]).to start_with("composed_term:")
        expect(board.approvals.each.count).to eq(0)
      end
    end

    # The motivating pipeline from the Intent, and the one the `-r` refusal
    # narrowed: `grep -rn foo lib | wc -l` no longer qualifies, `grep -n` does.
    it "approves the non-recursive pipeline and leaves the recursive one to a human" do
      in_tree do |root, home|
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("grep -n foo lib | wc -l", "cwd" => root), nil)).to be(true)
        while_parked(board, bash_of("grep -rn foo lib | wc -l", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # The blocker, through the shipped ladder: triage DOWNGRADES a bare denied
    # word to an abstention, so this rung is the only thing standing between
    # `cat .netrc` and an approval nobody made.
    it "leaves a denied path written as a bare word parking for a human" do
      in_tree do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("cat .netrc", "cwd" => root)) do
          expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage rules])
          expect(rulings.first).to include("rung" => "triage", "verdict" => "abstain")
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "leaves a gated credential parking for a human, though nothing denies it" do
      in_tree do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("cat .env", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # THE BLOCKER, pinned where the review round found it: through the real
    # assembled ladder, not against the rule. `/proc/self/root` aliases `/`, so
    # a home-anchored DENIED path wearing that prefix stops matching every
    # `Rule.homed` entry -- and the deny that the plain spelling earns at triage
    # simply does not happen. Measured before the fix: approved, rules:allow,
    # no human.
    it "does not approve a denied path reached through the /proc/self/root alias" do
      in_tree do |root, home|
        board = board_over(root, home)
        aliased = bash_of("cat /proc/self/root#{home}/.kube/config", "cwd" => root)

        expect(board.policy_switch.call(bash_of("cat #{home}/.kube/config", "cwd" => root), nil)).to be(false)
        while_parked(board, aliased) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # IDENTITY at the construction site, on the triage-factory example's shape:
    # every behavioural example above still passes on a board whose rule was
    # handed a classifier refusing nothing, so the object is asserted directly.
    it "appends the rule to the chain Project::Consent supplied, holding the real factory" do
      in_tree do |root, home|
        rules = board_over(root, home).ladder.to_a[1].instance_variable_get(:@rules)

        expect(rules.map(&:name)).to eq(%w[composed_term])
        expect(rules.last.instance_variable_get(:@sensitivity)).to be_a(described_class::Classifiers)
      end
    end

    # APPENDED and not prepended, which is the precedence: a human's remembered
    # refusal of the whole tool still wins over an allowlisted pipeline.
    it "keeps a remembered answer ahead of it, so a human's refusal still wins" do
      in_tree(config: %([[approval.deny_tool]]\ntool = "bash"\n)) do |root, home|
        board = board_over(root, home)
        rules = board.ladder.to_a[1].instance_variable_get(:@rules)

        expect(rules.map(&:name)).to eq(%w[remembered composed_term])
        expect(board.policy_switch.call(bash_of("cat README.md | head -20", "cwd" => root), nil)).to be(false)
        expect(rulings.last["reason"]).to start_with("remembered:")
      end
    end

    # The exclusion reaches this rule as a verdict DENY carrying no term, so
    # predicate 1 refuses it -- and triage answers first regardless, which is
    # what makes the ordering a convenience rather than the safety property.
    it "does not approve an excluded program that is on the allowlist" do
      in_tree(config: %([shell]\nexclude = ["cat"]\n)) do |root, home|
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("cat README.md | head -20", "cwd" => root), nil)).to be(false)
        expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage])
      end
    end
  end

  # The factory's own seam. Everything it needs to anchor on comes from the
  # WIRING -- `home` from {Paths}, `cwd` from the resolved {Project} -- so a
  # value it cannot use is a startup bug and belongs at startup. Built eagerly
  # for exactly that reason: a lazily-discovered bad home made the rung inert
  # for the whole session and said nothing, and the only thing making that loud
  # was that `.for` happens to evaluate `sensitivity:` before `classifiers:`.
  # Loudness must not rest on Ruby's keyword evaluation order.
  describe described_class::Classifiers do
    it "refuses a home it cannot anchor on, at construction rather than per call" do
      expect { described_class.new(home: "", cwd: "/tmp") }
        .to raise_error(ArgumentError, /home must be an absolute path/)
      expect { described_class.new(home: "/", cwd: "/tmp") }
        .to raise_error(ArgumentError, /home must not be the filesystem root/)
    end

    it "refuses a session cwd it cannot anchor on, for the same reason" do
      expect { described_class.new(home: "/home/u", cwd: "relative") }
        .to raise_error(ArgumentError, /cwd must be an absolute path/)
      expect { described_class.new(home: "/home/u", cwd: nil) }
        .to raise_error(ArgumentError, /cwd must be an absolute path/)
    end

    # Total over the model's half regardless, which is the asymmetry that
    # matters: the wiring's values are refused loudly, and the model's are
    # absorbed onto the session's own classifier.
    it "answers a real classifier for a cwd nothing could resolve" do
      factory = described_class.new(home: "/home/u", cwd: "/home/u/work")

      expect(factory.call("bad\0dir").denied?("/home/u/.ssh/id_rsa")).to be(true)
      expect(factory.call(nil).denied?("/home/u/.ssh/id_rsa")).to be(true)
    end
  end

  # ONE parse, one notice. `.for` needs the compiled table twice -- once for the
  # path boundary the gates read, once for the classifier the triage rung
  # anchors per call -- and calling {.rules} again for the second would parse
  # the config twice and say the same thing to the operator twice.
  describe "the [sensitivity] table, compiled once" do
    it "reports an unparseable config exactly once, however many collaborators need it" do
      in_tree(config: "this is not [valid toml") do |root, home|
        said = []
        described_class.for(chronicle:, options: {}, model: "m", toolset:, project: project_at(root),
                            paths: paths_at(home), notice: ->(message) { said << message })

        expect(said.grep(/\[sensitivity\].*not in force/).size).to eq(1)
      end
    end
  end
end
