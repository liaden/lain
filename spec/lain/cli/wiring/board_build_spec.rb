# frozen_string_literal: true

require "fileutils"
require "stringio"
require "timeout"
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
          .to raise_error(Lain::Config::Refusal, /config\.toml.*must be a table/)
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
        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")), cwd: root)).to be(true)
      end
    end

    # A link's landing is a REAL path, while the home-anchored rules are spelled
    # under HOME as configured; when HOME is itself a link the two differ.
    it "refuses a link landing under a home that is itself a symlink" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(home, ".kube"))
        File.write(File.join(home, ".kube", "config"), "token: x\n")
        linked_home = File.join(File.dirname(home), "home-link")
        File.symlink(home, linked_home)
        File.symlink(File.join(linked_home, ".kube", "config"), File.join(root, "k"))

        denial = board_for(root, linked_home).sensitivity.denial(read_of("k"), cwd: root)

        expect(denial&.reason).to eq(:protected)
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

        expect(board.ladder.to_a[1].instance_variable_get(:@rules).map(&:name)).to eq(%w[composed_term])
        expect(board.sensitivity.denial(read_of(File.join(root, "a.secret")), cwd: root)&.reason).to eq(:configured)
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

    # The degrade is the `[tests]` table's own and nobody else's, and the width
    # of this rescue has to be checked rather than inherited: since the seven
    # config families collapsed into one {Lain::Config::Refusal}, the class no
    # longer says which table refused -- `#table` does. A bare rescue here would
    # let an `[isolation]` typo degrade the layout and start the chat, which is
    # a restricting table failing open at the one site that could hide it.
    #
    # The refusal is INJECTED because today's shared parse builds each table on
    # the reader that asks for it, so `Config.test_layout` cannot raise about a
    # foreign table at all. This arm is what keeps that safe if it ever stops
    # being true, and an arm no example drives is an arm nobody maintains.
    it "re-raises a refusal about another table rather than degrading the layout" do
      in_tree(config: "[tests]\npreset = \"rspec\"\n") do |root, _home|
        told = []
        foreign = Lain::Config::Refusal.new("retain_days = -1 is not a whole number of days",
                                            path: File.join(root, ".lain", "config.toml"),
                                            table: Lain::Config::Isolation::TABLE)
        allow(Lain::Config).to receive(:test_layout).and_raise(foreign)

        expect { run_at(root, notice: told.method(:push)) }.to raise_error(foreign)
        expect(told).to be_empty
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
          .to raise_error(Lain::Config::Refusal, /config\.toml.*list of program names/)
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

    it "leaves a reader of a path outside the project root parking for a human" do
      in_tree do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("cat #{home}/notes.txt", "cwd" => root)) do
          expect(rulings.map { |ruling| ruling["rung"] }).to eq(%w[triage rules])
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "does not approve a call whose cwd escapes the root" do
      in_tree do |root, home|
        board = board_over(root, home)

        while_parked(board, bash_of("cat README.md", "cwd" => "/")) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # `$HOME` as the root is intent when a flag says so, and it is still no
    # boundary: everything the user owns lies under it.
    it "approves nothing automatically when the project root is the home directory" do
      in_tree do |_root, home|
        FileUtils.mkdir_p(home)
        project = Lain::Project.new(root: home, cwd: home, kind: :home, detected_by: :flag)
        board = described_class.for(chronicle:, options: {}, model: "m", toolset:, project:, paths: paths_at(home))

        while_parked(board, bash_of("cat README.md", "cwd" => home)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # No marker was found, so the root is merely wherever the process started --
    # evidence of nothing, and no boundary to approve inside.
    it "approves nothing automatically when no project was detected" do
      in_tree do |root, home|
        project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :none)
        board = described_class.for(chronicle:, options: {}, model: "m", toolset:, project:, paths: paths_at(home))

        while_parked(board, bash_of("cat README.md", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "leaves a named credential file inside the root to a human, on both read paths" do
      in_tree do |root, home|
        key = File.join(root, "config", "master.key")
        FileUtils.mkdir_p(File.dirname(key))
        File.write(key, "0123456789abcdef")
        board = board_over(root, home)

        while_parked(board, bash_of("cat config/master.key", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
        expect(board.sensitivity.gates?(read_of(key), cwd: root)).to be(true)
        expect(board.sensitivity.classify(key)).to have_attributes(level: :gated, reason: :credential)
      end
    end

    # A flag or config root ABOVE home holds every file its user owns: measured,
    # `cat home/notes.txt` was approved there with nobody asked.
    it "approves nothing automatically when the project root lies above the home directory" do
      in_tree do |root, home|
        FileUtils.mkdir_p(home)
        base = File.dirname(root)
        project = Lain::Project.new(root: base, cwd: base, kind: :project, detected_by: :flag)
        board = described_class.for(chronicle:, options: {}, model: "m", toolset:, project:, paths: paths_at(home))

        while_parked(board, bash_of("cat home/notes.txt", "cwd" => base)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # A symlink in the checkout -- git stores them, so a clone can ship one --
    # spells a file outside the root with a path that is lexically inside it.
    # The approving rule checks where the path really lands.
    it "leaves a read through an in-root symlink to outside the root parking for a human" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(home, ".config", "gh"))
        File.symlink(home, File.join(root, "h"))
        File.symlink("/", File.join(root, "link"))
        board = board_over(root, home)

        %w[h/.config/gh/hosts.yml link/etc/shadow].each do |path|
          while_parked(board, bash_of("cat #{path}", "cwd" => root)) do
            expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
          end
        end
      end
    end

    # The cwd a bash call runs in is the CLEANED one: `inner/../h` is `h`, and
    # `h` links to home, so the read below is of home's own credential file.
    it "parks a call whose cleaned cwd lands outside the root through a symlink" do
      in_tree do |root, home|
        FileUtils.mkdir_p([File.join(root, "lib", "deep"), File.join(home, ".config", "gh")])
        File.write(File.join(home, ".config", "gh", "hosts.yml"), "oauth_token: ghp_FAKE\n")
        File.symlink(home, File.join(root, "h"))
        File.symlink(File.join(root, "lib", "deep"), File.join(root, "inner"))
        board = board_over(root, home)

        while_parked(board, bash_of("cat .config/gh/hosts.yml", "cwd" => "inner/../h")) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    # The name classifier reads no bytes, so a key under an ordinary name was
    # released by `cat` while `read_file` of the same file masked it. Driven
    # through the assembled board, over files on disk.
    it "leaves a 0600 file behind an ordinary name parking for a human" do
      in_tree do |root, home|
        key = File.join(root, "deploy_key")
        File.write(key, "opaque bytes\n")
        File.chmod(0o600, key)
        board = board_over(root, home)

        while_parked(board, bash_of("cat deploy_key", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "leaves a world-readable file holding a private key parking for a human" do
      in_tree do |root, home|
        notes = File.join(root, "notes.txt")
        File.write(notes, "-----BEGIN PRIVATE KEY-----\nMIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8AgEAAkEAqwertyuiop\n" \
                          "-----END PRIVATE KEY-----\n")
        File.chmod(0o644, notes)
        board = board_over(root, home)

        while_parked(board, bash_of("cat notes.txt", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "approves an ordinary read of a file that exists, with nobody asked" do
      in_tree do |root, home|
        readme = File.join(root, "README.md")
        File.write(readme, "# A project\n\nNothing to see.\n")
        File.chmod(0o644, readme)
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("cat README.md | head -20", "cwd" => root), nil)).to be(true)
        expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
      end
    end

    # Over the real file, whose base64 blob is a high-entropy run: the approval
    # holds only while the detector knows a public key is not a secret.
    it "still approves the public half of a key pair with nobody asked" do
      in_tree do |root, home|
        pub = File.join(root, "id_ed25519.pub")
        line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRIVMdBD52mo93GQUaBiP1vMNsCtBXvXV5RzHSnbH8E dev@example.com"
        File.write(pub, "#{line}\n")
        File.chmod(0o644, pub)
        expect(File.file?(pub)).to be(true)
        board = board_over(root, home)

        expect(board.policy_switch.call(bash_of("cat id_ed25519.pub", "cwd" => root), nil)).to be(true)
        expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
      end
    end
  end

  # An exemption subtracts from the gated half, so one pattern broad enough to
  # lift a whole class of credential names is the table turned off by a
  # different spelling -- `.*` loaded and ungated every dot-named credential.
  describe "an exemption that lifts a class of credentials" do
    it "refuses the chat at load, naming the config file and the entries it would lift" do
      in_tree(config: %([sensitivity]\nexempt = [".*"]\n)) do |root, home|
        expect { board_for(root, home) }
          .to raise_error(Lain::Config::Refusal, %r{\.lain/config\.toml.*exempt.*\.env.*\.envrc}m)
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

  # A committed config names project files from the root, wherever the checkout
  # lives. Driven from a real config file through the board every attended chat
  # is built from, and through the real tools its listing half guards.
  describe "a project-anchored [sensitivity] pattern, on the production path" do
    def write(root, name, body, mode: 0o644)
      File.join(root, name).tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
        File.chmod(mode, path)
      end
    end

    def listed(board, root, name, tool, input)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {}))
      stack = Lain::Middleware::Stack.new([Lain::Middleware::WithholdSecretPaths.new(filter: board.sensitivity.filter)])
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
      stack.call({ effect:, context: session }) do |inner|
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: inner.fetch(:context))
        inner.merge(result: tool.call(input, invocation))
      end.fetch(:result).content
    end

    it "refuses a read inside an anchored denied directory, and withholds it from a listing and a grep", :seam do
      in_tree(config: %([sensitivity]\ndenied = ["/vault/"]\n)) do |root, home|
        write(root, "vault/a.txt", "TOKEN=inside\n")
        write(root, "notes.txt", "TOKEN=outside\n")
        board = board_for(root, home)

        expect(board.sensitivity.denial(read_of("vault/a.txt"), cwd: root)).to have_attributes(reason: :configured)
        expect(board.sensitivity.denial(read_of(File.join(root, "vault", "a.txt")), cwd: root)).not_to be_nil
        listing = listed(board, root, "list_files", Lain::Tools::ListFiles.new, { "path" => ".", "recursive" => true })
        hits = listed(board, root, "grep", Lain::Tools::Grep.new, { "pattern" => "TOKEN", "path" => "." })

        expect(listing).to include("notes.txt", "withheld (configured)")
        expect(listing).not_to include("vault")
        expect(hits).to include("notes.txt:1:", "1 match withheld (configured)")
        expect(hits).not_to include("inside")
      end
    end

    it "reads an anchored exempt file without a prompt, while cat of it still parks for a human" do
      in_tree(config: %([sensitivity]\nexempt = ["/fixtures/.env"]\n)) do |root, home|
        fixture = write(root, "fixtures/.env", "PLAIN=value\n")
        write(root, ".env", "PLAIN=value\n")
        board = board_over(root, home)

        expect(board.sensitivity.gates?(read_of(fixture), cwd: root)).to be(false)
        expect(board.sensitivity.gates?(read_of("fixtures/.env"), cwd: root)).to be(false)
        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")), cwd: root)).to be(true)
        while_parked(board, bash_of("cat fixtures/.env", "cwd" => root)) do
          expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
        end
      end
    end

    it "withholds a directory's contents from a read, a listing and a grep when the denial has no trailing slash",
       :seam do
      in_tree(config: %([sensitivity]\ndenied = ["/vault"]\n)) do |root, home|
        write(root, "vault/a.txt", "TOKEN=inside\n")
        write(root, "notes.txt", "TOKEN=outside\n")
        board = board_for(root, home)

        listing = listed(board, root, "list_files", Lain::Tools::ListFiles.new, { "path" => ".", "recursive" => true })
        hits = listed(board, root, "grep", Lain::Tools::Grep.new, { "pattern" => "TOKEN", "path" => "." })

        expect(board.sensitivity.denial(read_of("vault/a.txt"), cwd: root)).to have_attributes(reason: :configured)
        expect(listing).not_to include("vault")
        expect(hits).to include("notes.txt:1:")
        expect(hits).not_to include("inside")
      end
    end

    it "refuses an exemption naming a directory that exists, though it carries no trailing slash" do
      in_tree(config: %([sensitivity]\nexempt = ["/fixtures"]\n)) do |root, home|
        write(root, "fixtures/.env", "PLAIN=value\n")

        expect { board_for(root, home) }
          .to raise_error(Lain::Config::Refusal, %r{\.lain/config\.toml.*exempt.*"/fixtures"}m)
      end
    end

    it "refuses an anchored directory exemption at load, naming the pattern" do
      in_tree(config: %([sensitivity]\nexempt = ["/fixtures/"]\n)) do |root, home|
        expect { board_for(root, home) }
          .to raise_error(Lain::Config::Refusal, %r{\.lain/config\.toml.*exempt.*"/fixtures/"}m)
      end
    end

    # The same table reaches the triage and approving rungs through the factory,
    # anchored on the same root the policy uses.
    it "anchors the factory's classifiers on the project root, not on the call's cwd" do
      in_tree(config: %([sensitivity]\ndenied = ["/vault/"]\n)) do |root, home|
        FileUtils.mkdir_p(File.join(root, "lib"))
        project = project_at(root)
        factory = described_class.classifiers(project:, paths: paths_at(home), table: described_class.rules(project:))

        expect(factory.call(File.join(root, "lib")).classify("../vault/a.txt")).to be_denied
        expect(factory.call("bad\0dir").classify(File.join(root, "vault", "a.txt"))).to be_denied
      end
    end

    it "anchors on the project root even where the root confines nothing" do
      in_tree(config: %([sensitivity]\ndenied = ["/vault/"]\n)) do |root, home|
        project = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :none)
        board = described_class.for(chronicle:, options: {}, model: "m", toolset:, project:, paths: paths_at(home))

        expect(board.policy_switch.call(bash_of("cat #{root}/vault/a.txt", "cwd" => root), nil)).to be(false)
        expect(rulings.first).to include("rung" => "triage", "verdict" => "deny")
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

    # The same fallback would be fail-OPEN for the root predicate: the session's
    # cwd is inside the root by construction, so falling back to it would place
    # an unresolvable call inside the project. The root answer fails CLOSED.
    it "confines nothing for a cwd nothing could resolve, where the classifier falls back" do
      in_tree do |root, home|
        factory = described_class.new(home:, cwd: root, confinement: Lain::Approval::Risk::Root.new(root))

        expect(factory.confinement(nil).contains?("README.md")).to be(true)
        expect(factory.confinement("lib").contains?("../README.md")).to be(true)
        expect(factory.confinement("bad\0dir").contains?("README.md")).to be(false)
        expect(factory.confinement(42).contains?("README.md")).to be(false)
        expect(factory.confinement("/").contains?(root.delete_prefix("/"))).to be(false)
      end
    end

    # A root that is not a real directory has no real path to be under, and
    # the real half of the question fails closed on it.
    it "confines nothing under a root that does not exist" do
      factory = described_class.new(home: "/home/u", cwd: "/home/u/work",
                                    confinement: Lain::Approval::Risk::Root.new("/home/u/work"))

      expect(factory.confinement(nil).contains?("README.md")).to be(false)
    end

    # Closed by default, so a factory built without a confinement -- the triage
    # rung's own examples build one -- can never be the thing that approves.
    it "confines nothing when it was given no confinement" do
      expect(described_class.new(home: "/home/u", cwd: "/home/u/work").confinement(nil).contains?("x")).to be(false)
    end

    # The directory the command will really run in, which this factory has to
    # resolve anyway to answer the root question -- so it says the answer
    # rather than making a per-word caller resolve the same cwd again. It is
    # exactly the landing of `.`, and the approving rule reads it once per
    # decision instead of once per word.
    it "names the landing of the cwd it already resolved" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(root, "docs"))
        File.symlink(File.join(root, "docs"), File.join(root, "manual"))
        factory = described_class.new(home:, cwd: root, confinement: Lain::Approval::Risk::Root.new(root))

        expect(factory.confinement(nil).real_landing).to eq(root)
        expect(factory.confinement("manual").real_landing).to eq(File.join(root, "docs"))
        expect(factory.confinement("manual").real_landing).to eq(factory.confinement("manual").landing_of("."))
      end
    end

    # This factory is documented never to raise, so every confinement it hands
    # back answers every message -- including the one that confines nothing,
    # which the approving rule short-circuits past and never asks. Totality,
    # not a live caller: the unresolved spelling is the answer because nobody
    # is there to need a resolved one.
    it "answers a landing even where it confines nothing, rather than raising" do
      factory = described_class.new(home: "/home/u", cwd: "/home/u/work")

      expect(factory.confinement("bad\0dir").real_landing).to eq("/home/u/work")
    end

    describe "#content" do
      def confined_factory(home, root)
        described_class.new(home:, cwd: root, confinement: Lain::Approval::Risk::Root.new(root))
      end

      def put(root, name, body, mode: 0o644)
        File.join(root, name).tap do |path|
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
          File.chmod(mode, path)
        end
      end

      it "admits a world-readable regular file with no region in it" do
        in_tree do |root, home|
          put(root, "lib/app.rb", "puts 1\n")

          expect(confined_factory(home, root).content(nil).admits?("lib/app.rb")).to be(true)
          expect(confined_factory(home, root).content("lib").admits?("app.rb")).to be(true)
        end
      end

      it "refuses a regular file that is not world-readable" do
        in_tree do |root, home|
          put(root, "deploy_key", "opaque\n", mode: 0o640)

          expect(confined_factory(home, root).content(nil).admits?("deploy_key")).to be(false)
        end
      end

      it "refuses a world-readable file whose first bytes carry a region" do
        in_tree do |root, home|
          put(root, "notes.txt", "API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n")

          expect(confined_factory(home, root).content(nil).admits?("notes.txt")).to be(false)
        end
      end

      # The scan is bounded because it is paid on every judged call, and what it
      # did not read it does not vouch for: `tail` prints exactly those bytes.
      it "refuses a file larger than the scan, whatever lies past it" do
        in_tree do |root, home|
          put(root, "big.log", "#{"x" * (64 * 1024)}\nplain\n")
          put(root, "exact.log", "x" * (64 * 1024))
          factory = confined_factory(home, root)

          expect(factory.content(nil).admits?("big.log")).to be(false)
          expect(factory.content(nil).admits?("exact.log")).to be(true)
        end
      end

      it "judges the file a symlink lands on, not the link" do
        in_tree do |root, home|
          put(root, "keys/deploy", "opaque\n", mode: 0o600)
          File.symlink(File.join(root, "keys", "deploy"), File.join(root, "keylink"))

          expect(confined_factory(home, root).content(nil).admits?("keylink")).to be(false)
        end
      end

      # A word that names nothing on disk -- a flag, a pattern, a file not yet
      # there -- has no bytes to ask about; and `grep -n foo lib` reads no
      # directory as content.
      it "admits a word naming nothing, and a directory" do
        in_tree do |root, home|
          FileUtils.mkdir_p(File.join(root, "lib"))
          FileUtils.chmod(0o700, File.join(root, "lib"))
          factory = confined_factory(home, root)

          expect(%w[-n foo missing.txt lib].map { |word| factory.content(nil).admits?(word) }).to all(be(true))
        end
      end

      # Nothing outside the root is opened to answer, and the content answer
      # fails closed wherever the root answer does.
      it "admits nothing the confinement does not contain" do
        in_tree do |root, home|
          FileUtils.mkdir_p([root, home])
          outside = put(home, "notes.txt", "plain\n")
          factory = confined_factory(home, root)

          expect(factory.content(nil).admits?(outside)).to be(false)
          expect(factory.content("bad\0dir").admits?("missing.txt")).to be(false)
          expect(described_class.new(home:, cwd: root).content(nil).admits?("missing.txt")).to be(false)
        end
      end

      # A FIFO blocks an open for read until a writer arrives, and a device can
      # block a read forever. Neither may hang the ladder, and neither is a file
      # whose bytes can be asked about, so neither is admitted.
      it "refuses a named pipe without blocking on it" do
        in_tree do |root, home|
          FileUtils.mkdir_p(root)
          File.mkfifo(File.join(root, "pipe"))
          factory = confined_factory(home, root)

          allow(File).to receive(:open).and_call_original

          answer = Timeout.timeout(2) { factory.content(nil).admits?("pipe") }

          expect(answer).to be(false)
          expect(File).not_to have_received(:open).with(File.join(root, "pipe"), anything)
        end
      end

      # The path is judged, then opened, and it can change in between. Each swap
      # below is REAL, made on disk the moment the pre-open check has answered.
      describe "a path swapped between the check and the open" do
        def swap_after_check(path)
          allow(File).to receive(:file?).and_wrap_original do |original, asked|
            original.call(asked).tap { yield if asked == path }
          end
        end

        # Opened non-blocking, or the open waits for a writer forever; and the
        # descriptor is asked again, or a writer-less FIFO reads as an empty,
        # clean file.
        it "refuses a regular file that became a named pipe, without blocking" do
          in_tree do |root, home|
            path = put(root, "notes.txt", "plain\n")
            swap_after_check(path) do
              File.delete(path)
              File.mkfifo(path)
            end

            answer = Timeout.timeout(2) { confined_factory(home, root).content(nil).admits?("notes.txt") }

            expect(answer).to be(false)
          end
        end

        # The word's landing is already resolved, so a link at the open is a
        # swap, and following it would read a file nothing placed in the root.
        it "refuses a regular file that became a link to a clean file outside the root" do
          in_tree do |root, home|
            outside = put(home, "clean.txt", "plain\n")
            path = put(root, "notes.txt", "plain\n")
            swap_after_check(path) do
              File.delete(path)
              File.symlink(outside, path)
            end

            expect(confined_factory(home, root).content(nil).admits?("notes.txt")).to be(false)
          end
        end
      end
    end

    # A leased worker runs its commands in its own checkout, which sits outside
    # the project root, so the factory it is judged by is anchored there.
    describe "#for" do
      def leased_at(checkout) = Lain::WorkerEnv.new(cwd: checkout, env: {}, checkout:)

      def project_factory(root, home, table: Lain::Sensitivity::Rules.empty)
        described_class.new(home:, cwd: root, rules: table, root:, confinement: Lain::Approval::Risk::Root.new(root))
      end

      def in_checkout(config: nil)
        in_tree(config:) do |root, home|
          checkout = File.join(File.dirname(root), "lease")
          FileUtils.mkdir_p([checkout, home, File.join(root, "lib")])
          yield(root, home, checkout)
        end
      end

      it "answers itself for a worker no lease cut a checkout for" do
        in_checkout do |root, home, checkout|
          factory = project_factory(root, home)

          expect(factory.for(Lain::WorkerEnv.new(cwd: File.join(root, "lib"), env: {}))).to be(factory)
          expect(factory.for(Lain::WorkerEnv.new(cwd: checkout, env: {}))).to be(factory)
        end
      end

      it "confines a leased worker's words to its checkout, where the project's factory confines them to the root" do
        in_checkout do |root, home, checkout|
          File.write(File.join(checkout, "README.md"), "a readme\n")
          leased = project_factory(root, home).for(leased_at(checkout))

          expect(leased.confinement(nil).contains?("README.md")).to be(true)
          expect(leased.confinement(checkout).contains?("README.md")).to be(true)
          expect(leased.confinement(root).contains?("README.md")).to be(false)
          expect(leased.content(nil).admits?("README.md")).to be(true)
        end
      end

      it "asks what a word holds in the checkout, following a link there" do
        in_checkout do |root, home, checkout|
          File.write(File.join(checkout, "key.txt"), "opaque\n")
          File.chmod(0o600, File.join(checkout, "key.txt"))
          File.symlink("key.txt", File.join(checkout, "keylink"))

          expect(project_factory(root, home).for(leased_at(checkout)).content(nil).admits?("keylink")).to be(false)
          expect(project_factory(root, home).content(nil).admits?("keylink")).to be(true)
        end
      end

      def table_at(root) = Lain::CLI::Wiring::BoardBuild.rules(project: project_at(root))

      # The checkout carries a copy of the tracked tree, and the project's own is
      # one absolute word away, so an anchored pattern denies under either root.
      it "denies an anchored pattern under the checkout AND under the project root, and its home rules as before" do
        in_checkout(config: %([sensitivity]\ndenied = ["/vault/"]\n)) do |root, home, checkout|
          leased = project_factory(root, home, table: table_at(root)).for(leased_at(checkout))

          expect(leased.call(nil).denied?("vault/token")).to be(true)
          expect(leased.call(nil).denied?(File.join(root, "vault", "token"))).to be(true)
          expect(leased.call("bad\0dir").denied?(File.join(root, "vault", "token"))).to be(true)
          expect(leased.call(nil).denied?(File.join(home, ".ssh", "id_rsa"))).to be(true)
          expect(leased.call(nil).denied?("README.md")).to be(false)
        end
      end

      it "gates an anchored pattern under either root, and answers the stricter of the two verdicts" do
        config = %([sensitivity]\ngated = ["/notes/"]\nexempt = ["/fixtures/.env"]\n)
        in_checkout(config:) do |root, home, checkout|
          leased = project_factory(root, home, table: table_at(root)).for(leased_at(checkout))

          expect(leased.call(nil).classify(File.join(root, "notes", "a.txt"))).to be_gated
          expect(leased.call(nil).classify("notes/a.txt")).to be_gated
          expect(leased.call(nil).classify("fixtures/.env")).to be_gated
        end
      end

      it "confines a leased worker to its checkout alone, whichever root denies" do
        in_checkout(config: %([sensitivity]\ndenied = ["/vault/"]\n)) do |root, home, checkout|
          leased = project_factory(root, home, table: table_at(root)).for(leased_at(checkout))

          expect(leased.confinement(nil).contains?(File.join(root, "README.md"))).to be(false)
        end
      end

      it "answers the checkout-anchored factory itself when the checkout is the project root" do
        in_checkout do |root, home|
          leased = project_factory(root, home).for(leased_at(root))

          expect(leased.call(nil)).to be_a(Lain::Sensitivity)
        end
      end

      it "confines nothing in a checkout holding the home directory" do
        in_checkout do |root, home|
          above = File.dirname(home)

          expect(project_factory(root, home).for(leased_at(above)).confinement(nil).contains?("README.md"))
            .to be(false)
        end
      end

      # A root the parent confines nothing under -- a home, or a directory
      # nothing detected -- gives its workers nothing to be confined to either.
      it "confines nothing for a worker of a factory that confines nothing" do
        in_checkout do |root, home, checkout|
          File.write(File.join(checkout, "README.md"), "a readme\n")
          unconfined = described_class.new(home:, cwd: root, root:)

          expect(unconfined.for(leased_at(checkout)).confinement(nil).contains?("README.md")).to be(false)
        end
      end
    end
  end

  describe ".classifiers" do
    def confined?(project, home, word)
      described_class.classifiers(project:, paths: paths_at(home), table: Lain::Sensitivity::Rules.empty)
                     .confinement(nil).contains?(word)
    end

    it "confines a detected project to its root" do
      in_tree do |root, home|
        expect(confined?(project_at(root), home, "README.md")).to be(true)
        expect(confined?(project_at(root), home, "../elsewhere")).to be(false)
      end
    end

    it "confines nothing when the root is the home directory or nothing was detected" do
      in_tree do |root, home|
        FileUtils.mkdir_p(home)
        homed = Lain::Project.new(root: home, cwd: home, kind: :home, detected_by: :flag)
        undetected = Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :none)

        expect(confined?(homed, home, "README.md")).to be(false)
        expect(confined?(undetected, home, "README.md")).to be(false)
      end
    end

    # Equality missed a root spelled differently from HOME, and a root ABOVE
    # it -- `--root /home` -- holds everything its users own just as surely.
    it "confines nothing when the root contains the home directory, however HOME is spelled" do
      in_tree do |root, home|
        FileUtils.mkdir_p(home)
        base = File.dirname(root)
        above = Lain::Project.new(root: base, cwd: base, kind: :project, detected_by: :flag)
        same = Lain::Project.new(root: home, cwd: home, kind: :project, detected_by: :git)

        expect(confined?(above, home, "home/notes.txt")).to be(false)
        expect(confined?(same, "#{home}/", "notes.txt")).to be(false)
      end
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
