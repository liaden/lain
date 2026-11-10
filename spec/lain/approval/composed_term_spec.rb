# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "timeout"
require "tmpdir"

module ComposedTermSpecSupport
  # Counts the resolutions a rule asks of the factory it is built over.
  class CountingFactory < SimpleDelegator
    attr_reader :resolutions

    def initialize(factory)
      super
      @resolutions = 0
    end

    def executables(...)
      @resolutions += 1
      super
    end
  end

  # A factory whose classifier passes every path, so only the root, content
  # and landing answers of the real one it wraps can refuse a word.
  class PassingClassifier < SimpleDelegator
    def call(_cwd) = Lain::Approval::Escalation::Triage::AnyPath.new
  end
end

# The one rule in `lib/` that can APPROVE, so most of this file is a question
# about what it REFUSES. Each refusal names a command MEASURED to reach
# `Shell::Verdict#allow`, and {#expect_allowed_by_the_verdict} re-measures it
# here: a command the verdict never allows is refused by arithmetic rather than
# by this rule, so an example resting on one would pass against a rule that
# approved everything.
RSpec.describe Lain::Approval::ComposedTerm do
  # A real `ssh-keygen` public line, fixed so no spec depends on the binary.
  let(:public_key_line) do
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGRIVMdBD52mo93GQUaBiP1vMNsCtBXvXV5RzHSnbH8E dev@example.com\n"
  end

  # A real tree, because the classifier resolves relative words against a cwd
  # and the home-anchored rules need a home that is not the developer's.
  def in_tree
    Dir.mktmpdir("lain-composed-term") do |dir|
      base = File.realpath(dir)
      root = File.join(base, "repo")
      home = File.join(base, "home")
      FileUtils.mkdir_p([root, File.join(home, ".ssh")])
      yield(root, home)
    end
  end

  # The REAL factory a session's wiring hands this rule, on escalation_spec's
  # precedent: a second copy of a security-relevant total factory is one that can
  # drift, and these examples would then exercise the copy while a live session
  # ran on the other. The session cwd doubles as the project root unless an
  # example says otherwise.
  def factory_for(home, session_cwd, confinement: Lain::Approval::Root.new(session_cwd),
                  rules: Lain::Sensitivity::Rules.empty)
    Lain::CLI::Wiring::BoardBuild::Classifiers.new(home:, cwd: session_cwd, rules:, root: session_cwd, confinement:)
  end

  def rule_for(home, session_cwd, **rest) = described_class.new(sensitivity: factory_for(home, session_cwd, **rest))

  # On disk, because the rule reads what a file holds: an approval asserted
  # over a file that does not exist passes without a byte being asked about.
  def on_disk(root, name, body, mode: 0o644)
    File.join(root, name).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
      File.chmod(mode, path)
    end
  end

  def call_of(command, cwd: nil, verdict: Lain::Shell::Verdict.new)
    tool = Lain::Tools::Bash.new(verdict:)
    Lain::Approval::Rule::Call.for(tool:, input: { "command" => command, "cwd" => cwd }.compact)
  end

  # The verdict this rule's first predicate reads through, asserted rather than
  # assumed: a command the verdict abstains on carries no term, so a refusal
  # here would prove nothing about the four predicates after it.
  def expect_allowed_by_the_verdict(*commands)
    verdict = Lain::Shell::Verdict.new
    expect(commands.map { |command| verdict.call(command).name }).to eq([:allow] * commands.size)
  end

  describe "a term whose every stage and every word is safe" do
    it "approves it, and the decision names this rule" do
      in_tree do |root, home|
        readme = on_disk(root, "README.md", "# A project\n\nRun the suite before believing it.\n")
        expect(File.file?(readme)).to be(true)

        decision = rule_for(home, root).decide(call_of("cat README.md | head -20", cwd: root))

        expect(decision).to have_attributes(verdict: :allow, rule: "composed_term", tool: "bash", gated: true)
      end
    end

    it "approves the pipeline the Intent names, now that it does not recurse" do
      in_tree do |root, home|
        expect(rule_for(home, root).decide(call_of("grep -n foo lib | wc -l", cwd: root))).to be_allow
      end
    end
  end

  describe "an inert utility" do
    def approved?(root, home, command) = rule_for(home, root).decide(call_of(command, cwd: root))&.allow? || false

    it "approves sleep with one numeric operand, true and false" do
      in_tree do |root, home|
        commands = ["sleep 13", "sleep 0.5", "true", "false", "sleep 1 && echo done"]
        expect_allowed_by_the_verdict(*commands)

        expect(commands.map { approved?(root, home, _1) }).to all(be(true))
      end
    end

    it "approves echo and printf over literal words" do
      in_tree do |root, home|
        on_disk(root, "README.md", "# A project\n")
        commands = ["echo hi", "echo -n 'a b'", "printf '%s' hi", "echo a && echo b", "cat README.md && echo done"]

        expect(commands.map { approved?(root, home, _1) }).to all(be(true))
      end
    end

    it "refuses a sleep that is not exactly one finite number" do
      in_tree do |root, home|
        commands = ["sleep x", "sleep infinity", "sleep 1 2", "sleep", "sleep 1d", "sleep -1", "sleep 99999"]
        expect_allowed_by_the_verdict(*commands)

        expect(commands.map { approved?(root, home, _1) }).to all(be(false))
      end
    end

    it "refuses a printf whose field width or precision would amplify its output" do
      in_tree do |root, home|
        wide = ["printf '%1000000000s' x", "printf '%.5000d' 1", "printf '%-0004000s' x",
                "printf '%*s' 1000000000 x", "printf '%.*s' 1000000000 x"]

        expect(wide.map { approved?(root, home, _1) }).to all(be(false))
        expect(approved?(root, home, "printf '%999s|%.3f' x 1")).to be(true)
      end
    end

    it "refuses what writes, expands or reads beyond its words" do
      in_tree do |root, home|
        commands = ["echo hi > notes.txt", "printf '%s' $(id)", "sleep 1; rm -rf x", "printf -v x hi",
                    "echo /etc/hostname", "echo .env"]

        expect(commands.map { approved?(root, home, _1) }).to all(be(false))
      end
    end
  end

  describe "a word the session's classifier denies" do
    # THE BLOCKER THIS RULE IS BUILT AROUND. `Triage::Command#literal`
    # partitions denied words on a path-like shape and DOWNGRADES a bare one
    # from deny to abstain, on the stated premise that "the call still reaches a
    # human because Triage downgrades every allow anyway" -- a premise an
    # approving rung destroys. So this rule classifies every word itself and
    # refuses whatever the spelling.
    it "refuses it written as a bare word, which the triage rung only abstains on" do
      in_tree do |root, home|
        expect_allowed_by_the_verdict("cat .netrc", "head -20 .netrc", "cat ./.netrc")

        rule = rule_for(home, root)
        ["cat .netrc", "head -20 .netrc", "cat ./.netrc"].each do |command|
          expect(rule.decide(call_of(command, cwd: root))).to be_nil
        end
      end
    end
  end

  describe "a word the classifier gates but does not deny" do
    # The predicate is "is ORDINARY", never "is not denied". `Sensitivity` is
    # three-valued and the GATED tier is where this codebase put the credential
    # files it declined to hard-refuse, so "not denied" would approve every one.
    it "refuses the whole credential tier, though nothing denies any of it" do
      in_tree do |root, home|
        gated = ["cat .env", "cat server.pem", "cat terraform.tfstate", "cat config/credentials.json"]
        expect_allowed_by_the_verdict(*gated)

        rule = rule_for(home, root)
        expect(gated.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * gated.size)
      end
    end

    # An exemption is a person saying one file needs no prompt when a person
    # reads it. This rule reads with nobody, so it does not take that word.
    it "refuses a credential an exemption lifted, though the classifier now calls it ordinary" do
      in_tree do |root, home|
        on_disk(root, ".gitconfig", "[user]\n  name = dev\n")
        factory = factory_for(home, root, rules: Lain::Sensitivity::Rules.from({ "exempt" => [".gitconfig"] }))
        expect_allowed_by_the_verdict("cat .gitconfig")
        expect(factory.call(root).classify(".gitconfig")).to have_attributes(level: :ordinary, reason: :exempt)

        expect(described_class.new(sensitivity: factory).decide(call_of("cat .gitconfig", cwd: root))).to be_nil
      end
    end

    # A home-anchored gated path reaches this rule only when it is spelled
    # absolutely: MEASURED, `cat ~/.git-credentials` ABSTAINS at the verdict,
    # because a leading `~` is an expanding construct the parser refuses. Both
    # spellings are here so the refusal is not resting on the parser.
    it "refuses a home credential by either spelling" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat #{home}/.git-credentials", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat ~/.git-credentials", cwd: root))).to be_nil
      end
    end

    # MEASURED end to end: a child spawned the way this codebase spawns one
    # inherits the session's `ANTHROPIC_API_KEY`, so `cat /proc/self/environ`
    # PRINTS A LIVE KEY. Nothing in this rule's five predicates covers it --
    # `/proc/self/environ` is a bare literal argument of an allowlisted reader --
    # so the refusal has to come from the classifier, which is where path
    # sensitivity is decided in this codebase and the only place it may be.
    it "refuses a read of the process environment, which carries a live API key" do
      in_tree do |root, home|
        expect_allowed_by_the_verdict("cat /proc/self/environ")

        rule = rule_for(home, root)
        expect(rule.decide(call_of("cat /proc/self/environ", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat /proc/1/environ", cwd: root))).to be_nil
        expect(rule.decide(call_of("head -1 /proc/self/cmdline", cwd: root))).to be_nil
      end
    end

    # A word the classifier could not READ is gated too (`Sensitivity::MALFORMED`),
    # so requiring `ordinary` refuses it for free.
    it "refuses a word the classifier cannot read lexically" do
      in_tree do |root, home|
        expect(rule_for(home, root).decide(call_of("cat a\0b", cwd: root))).to be_nil
      end
    end
  end

  describe "a flag that takes a stage outside its own arguments" do
    # The check is over the TERM and the hazard is over the READ SET, and those
    # coincide only for programs whose read set is exactly their literal
    # arguments. `-r` has every word classifying ordinary and prints a file
    # nothing may lift, so predicate 4 does not save it.
    #
    # DO NOT "simplify" these to the `~/.ssh` spelling the hazard is usually
    # written in. MEASURED: `grep -h -r . ~/.ssh` ABSTAINS at the parser,
    # because a leading `~` is an expanding construct {Shell::Verdict} refuses
    # -- so that command never reaches this rule and an example using it tests
    # nothing at all. The absolute spelling is what reaches `allow`, and it is
    # what proves the predicate: measured, `grep -h -r . /home/u/.ssh` allows
    # with EVERY word ordinary, the directory included, because the denied rule
    # names `id_*` INSIDE `.ssh` and the directory itself is not a match.
    it "refuses a recursive grep, in every spelling the real program accepts" do
      in_tree do |root, home|
        recursive = ["grep -h -r . lib", "grep -hr . lib", "grep -h --rec . lib", "grep -h -d recurse . lib",
                     "grep -h -R . lib", "grep -h --dereference-recursive . lib"]
        expect_allowed_by_the_verdict(*recursive)

        rule = rule_for(home, root)
        expect(recursive.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * recursive.size)
      end
    end

    # THE FOURTH EVASION CLASS, found by the review round. The long matcher ran
    # ONE way -- it asked whether a listed flag begins with the written word,
    # which catches ABBREVIATION and never EXTENSION. Measured:
    # `grep --exclude-dir=x` and `grep --exclude-from=/etc/passwd` were
    # APPROVED while `grep --exclude=x` was refused, so a flag that opens a file
    # walked straight through predicate 5's stated hazard.
    it "refuses a long flag that EXTENDS a listed one, not only one that abbreviates it" do
      in_tree do |root, home|
        extending = ["grep --exclude-dir=x foo lib", "grep --exclude-from=/etc/passwd foo lib"]
        expect_allowed_by_the_verdict(*extending)

        rule = rule_for(home, root)
        expect(extending.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil, nil])
        expect(rule.decide(call_of("grep --exclude=x foo lib", cwd: root))).to be_nil
        expect(rule.decide(call_of("grep --rec foo lib", cwd: root))).to be_nil
      end
    end

    # Symmetry costs a false refusal, MEASURED and named so it is not mistaken
    # for a hazard: `--files-with-matches` is grep's harmless `-l`, and it
    # extends the listed `--file`. One prompt, in the safe direction.
    it "over-refuses a benign long flag that extends a listed one, in the safe direction" do
      in_tree do |root, home|
        expect(rule_for(home, root).decide(call_of("grep --files-with-matches foo lib", cwd: root))).to be_nil
      end
    end

    # The other direction of the symmetric matcher, so a later reader can see it
    # does not simply refuse every long flag: neither of these is a prefix of a
    # listed name nor extends one, and both stay approved.
    it "leaves a long flag alone that neither abbreviates nor extends a listed one" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("grep --regexp=foo lib", cwd: root))).to be_allow
        expect(rule.decide(call_of("grep --fixed-strings foo lib", cwd: root))).to be_allow
      end
    end

    it "refuses a grep that takes its patterns from a file" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("grep -f patterns.txt lib", cwd: root))).to be_nil
        expect(rule.decide(call_of("grep --file=patterns.txt lib", cwd: root))).to be_nil
      end
    end

    it "refuses a sort that writes, including bundled and attached spellings" do
      in_tree do |root, home|
        writing = ["sort -o out in", "sort --output=out in", "sort -ro/tmp/out in"]
        expect_allowed_by_the_verdict(*writing)

        rule = rule_for(home, root)
        expect(writing.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * writing.size)
      end
    end

    # MEASURED on this box: `sort -S 1k --compress-program=./evil.sh big.txt`
    # ran `./evil.sh` once per temporary. The proposed starter table said
    # "`-o`, `--output`" and nothing else for sort.
    it "refuses the sort flag that runs a program of the model's choosing" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("sort --compress-program=./evil.sh big.txt", cwd: root))).to be_nil
        expect(rule.decide(call_of("sort --comp=./evil.sh big.txt", cwd: root))).to be_nil
      end
    end

    # MEASURED: `wc --files0-from=F` reads every file NAMED IN F, and
    # `--files0-from=-` takes those names from stdin -- the same promotion of
    # stdin to argv that keeps `xargs` off the list. The proposed starter table
    # said "none known" for wc.
    it "refuses a wc that reads the files named in another file" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("wc --files0-from=names.nul", cwd: root))).to be_nil
        expect(rule.decide(call_of("wc --files0-from=- lib", cwd: root))).to be_nil
        expect(rule.decide(call_of("wc --f=names.nul", cwd: root))).to be_nil
      end
    end

    # MEASURED: `timeout 2 tail -f FILE` exits 124. The read set is still its
    # arguments, so this refusal is a narrowing beyond predicate 5's letter --
    # an auto-approved call that never returns holds the tool for its whole
    # timeout with no human having chosen that.
    it "refuses a tail that never returns" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("tail -f app.log", cwd: root))).to be_nil
        expect(rule.decide(call_of("tail -F app.log", cwd: root))).to be_nil
      end
    end

    it "still approves the benign flags of the same programs" do
      in_tree do |root, home|
        rule = rule_for(home, root)
        benign = ["grep -n foo lib", "sort -u lib", "wc -l lib", "tail -n 5 lib", "cut -f 1 lib", "head -c 20 lib"]

        expect(benign.map { |command| rule.decide(call_of(command, cwd: root))&.verdict }).to eq([:allow] * 6)
      end
    end
  end

  # THE BLOCKER the review round found. `/proc/self/root` aliases `/` and
  # `/proc/self/cwd` aliases the process's working directory, so a path prefixed
  # by either reaches the same file under a spelling the LEXICAL classifier
  # cannot see through: the six `Rule.homed` entries stop matching, because
  # `descends?(path, home)` is false once the path is prefixed. Measured through
  # the real ladder, `cat /proc/self/root<HOME>/.kube/config` was APPROVED while
  # the plain absolute spelling denied at triage.
  #
  # It needs no attacker-planted file, it exists on every Linux box, and it is a
  # pure string the model emits. The refusal is over the WORD and never over a
  # resolved target, so nothing here touches the filesystem and there is no
  # TOCTOU window to reason about.
  describe "a word that traverses a path-aliasing pseudo-filesystem" do
    it "refuses a home-anchored denied path reached through /proc/self/root" do
      in_tree do |root, home|
        aliased = "cat /proc/self/root#{home}/.kube/config"
        expect_allowed_by_the_verdict(aliased)

        rule = rule_for(home, root)
        expect(rule.decide(call_of("cat #{home}/.kube/config", cwd: root))).to be_nil
        expect(rule.decide(call_of(aliased, cwd: root))).to be_nil
      end
    end

    it "refuses every home-anchored rule the alias defeats" do
      in_tree do |root, home|
        rule = rule_for(home, root)
        defeated = %w[.config/gh/hosts.yml Cookies key4.db .docker/config.json .kube/config]
                   .map { |name| "cat /proc/self/root#{home}/#{name}" }

        expect(defeated.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * 5)
      end
    end

    it "refuses the siblings that alias by a different route" do
      in_tree do |root, home|
        rule = rule_for(home, root)
        siblings = ["cat /proc/self/cwd/.env", "cat /proc/self/fd/3", "cat /proc/self/task/1/environ",
                    "cat /proc/1/root/etc/shadow", "cat /sys/kernel/notes", "cat /dev/fd/3"]

        expect(siblings.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * 6)
      end
    end

    # A SEGMENT match, not a prefix, so a relative spelling from a cwd at or
    # above the root is caught too -- `proc/self/root/...` never becomes a word
    # this rule reads as ordinary.
    it "refuses a relative and a doubled spelling of the same traversal" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat proc/self/root#{home}/.kube/config", cwd: "/"))).to be_nil
        expect(rule.decide(call_of("cat //proc/self/environ", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat ../proc/self/environ", cwd: root))).to be_nil
      end
    end

    # Over-broad, failing closed, costing one prompt -- the same bargain the
    # classifier's `within("proc")` entry already makes, and stated for the same
    # reason: contorting the pattern to spare a checkout directory would buy a
    # hole rather than a convenience.
    it "also refuses an unrelated proc or sys directory in a checkout, and that is the trade" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat vendor/proc/README", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat sys/boot.c", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat lib/dev/fd/x.rb", cwd: root))).to be_nil
      end
    end

    it "leaves an ordinary read alone, and matches a SEGMENT rather than a substring" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat README.md", cwd: root))).to be_allow
        expect(rule.decide(call_of("cat lib/process/runner.rb", cwd: root))).to be_allow
        expect(rule.decide(call_of("cat devfd/3", cwd: root))).to be_allow
      end
    end

    # `/dev` at large is not this predicate's: the pattern names `dev/fd` only.
    # `/dev/stdin` and `/dev/null` are refused now, but by the root predicate,
    # because they lie outside the project -- the read-surface question this
    # comment used to defer to a later rung is answered there.
    it "leaves /dev at large to the root predicate, which refuses it from outside the project" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(described_class::ALIASING.match?("/dev/stdin")).to be(false)
        expect(rule.decide(call_of("cat /dev/stdin", cwd: root))).to be_nil
        expect(rule.decide(call_of("cat /dev/null", cwd: root))).to be_nil
      end
    end
  end

  # Automatic approval is sized for a reader nobody watches, so what it may
  # read stops at the project. Every word and the call's own cwd resolve
  # LEXICALLY under the root, on {Approval::Root}'s terms -- no
  # stat, no realpath, and a leading `~` refused rather than expanded.
  describe "a home-relative word, expanded by the verdict" do
    def homed(home) = Lain::Shell::Verdict.new(home:)

    def with_epic(home)
      epics = File.join(home, ".local", "state", "lain", "epics", "k")
      on_disk(epics, "nyotes/epic.md", "Blocked: nothing\n")
      epics
    end

    def reading(home, root, reads)
      described_class.new(sensitivity: Lain::CLI::Wiring::BoardBuild::Classifiers.new(
        home:, cwd: root, root:, confinement: Lain::Approval::Root.new(root), reads:
      ))
    end

    it "approves a reader of a file under a read root, spelled from the HOME" do
      in_tree do |root, home|
        rule = reading(home, root, [with_epic(home)])
        call = call_of("grep -n Blocked ~/.local/state/lain/epics/k/nyotes/epic.md", cwd: root, verdict: homed(home))

        expect(rule.decide(call)).to be_allow
      end
    end

    it "refuses another user's home before any term exists" do
      in_tree do |root, home|
        rule = reading(home, root, [with_epic(home)])
        verdict = homed(home)
        commands = ["cat ~other/secret", "cat ~root/x"]

        expect(commands.map { verdict.call(_1).name }).to eq(%i[abstain abstain])
        expect(commands.map { rule.decide(call_of(_1, cwd: root, verdict:)) }).to eq([nil, nil])
      end
    end

    # The classifier passes every path here, because its outside-the-project
    # verdict would refuse both words first and hide a root predicate that let them through.
    it "refuses the HOME itself and a climb out of it at the root, whatever the classifier says" do
      in_tree do |root, home|
        factory = Lain::CLI::Wiring::BoardBuild::Classifiers.new(
          home:, cwd: root, root:, confinement: Lain::Approval::Root.new(root), reads: [with_epic(home)]
        )
        rule = described_class.new(sensitivity: ComposedTermSpecSupport::PassingClassifier.new(factory))
        verdict = homed(home)
        commands = ["cat ~", "cat ~/../../etc/passwd"]

        expect(commands.map { verdict.call(_1).name }).to eq(%i[allow allow])
        expect(rule.decide(call_of("cat ~/.local/state/lain/epics/k/nyotes/epic.md", cwd: root, verdict:))).to be_allow
        expect(commands.map { rule.decide(call_of(_1, cwd: root, verdict:)) }).to eq([nil, nil])
      end
    end

    it "refuses a write into a read root" do
      in_tree do |root, home|
        rule = reading(home, root, [with_epic(home)])
        epic = "~/.local/state/lain/epics/k/nyotes/epic.md"
        commands = ["sed -i s/a/b/ #{epic}", "sort -o #{epic} #{epic}"]

        expect(commands.map { homed(home).call(_1).name }).to eq(%i[abstain allow])
        expect(commands.map { rule.decide(call_of(_1, cwd: root, verdict: homed(home))) }).to eq([nil, nil])
      end
    end
  end

  describe "the project root" do
    it "refuses a reader of a path under home but outside the root" do
      in_tree do |root, home|
        outside = ["cat #{home}/notes.txt", "cat ../home/notes.txt", "head -5 README.md #{home}/notes.txt"]
        expect_allowed_by_the_verdict(*outside)

        rule = rule_for(home, root)
        expect(outside.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * outside.size)
      end
    end

    it "refuses a call whose own cwd escapes the root, however ordinary its words" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat README.md", cwd: "/"))).to be_nil
        expect(rule.decide(call_of("cat README.md", cwd: home))).to be_nil
        expect(rule.decide(call_of("cat README.md", cwd: ".."))).to be_nil
      end
    end

    it "still approves from a cwd below the root, and with no cwd named at all" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(root, "lib"))
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat ../README.md", cwd: "lib"))).to be_allow
        expect(rule.decide(call_of("cat README.md"))).to be_allow
      end
    end

    # A bare `..` carries no separator, so a shape test on "path-like" words
    # would wave it through. Every word is resolved instead.
    it "refuses a word that climbs out without a separator" do
      in_tree do |root, home|
        expect(rule_for(home, root).decide(call_of("wc -l ..", cwd: root))).to be_nil
      end
    end

    # The factory falls back to the SESSION's classifier for a cwd it cannot
    # resolve, which is right for a deny and wrong for an allow: a cwd nobody
    # could place is not evidence that the call stays inside the project.
    it "fails closed on a cwd the factory cannot resolve" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat README.md", cwd: "bad\0dir"))).to be_nil
      end
    end

    # Lexically inside, really outside: a symlink in the checkout. Measured
    # before the real-path half existed, `cat h/.config/gh/hosts.yml` was
    # approved while the direct spelling of the same file was DENIED.
    it "refuses a word that reaches outside the root through a symlink" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(home, ".config", "gh"))
        File.symlink(home, File.join(root, "h"))
        File.symlink("/", File.join(root, "link"))
        File.symlink(File.join(home, "absent"), File.join(root, "dangling"))
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.symlink("/usr", File.join(root, "lib", "up"))
        rule = rule_for(home, root)

        through = ["cat h/.config/gh/hosts.yml", "cat link/etc/shadow", "cat dangling", "cat dangling/x",
                   "cat lib/up/../etc/passwd", "cat #{root}/h/notes.txt"]
        expect(through.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * through.size)
      end
    end

    it "refuses a call whose cwd reaches outside the root through a symlink" do
      in_tree do |root, home|
        File.symlink(home, File.join(root, "h"))

        expect(rule_for(home, root).decide(call_of("cat notes.txt", cwd: "h"))).to be_nil
      end
    end

    # The command runs in the cwd `WorkerEnv#resolve` CLEANS, so `inner/../h`
    # runs in `h` -- `$HOME` -- whatever `inner` links to. Judging the uncleaned
    # spelling instead climbed out of `inner`'s real target and back into the
    # root, approving a read of home.
    it "judges a cwd the way the command will run in it, cleaned before it is resolved" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(root, "lib", "deep"))
        File.symlink(home, File.join(root, "h"))
        File.symlink(File.join(root, "lib", "deep"), File.join(root, "inner"))
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat notes.txt", cwd: "inner/../h"))).to be_nil
        expect(rule.decide(call_of("cat README.md", cwd: "inner/.."))).to be_allow
      end
    end

    # Resolution only ever REMOVES an approval: a link that stays inside the
    # root, and a path that does not exist yet, are approved as before.
    it "still approves a symlink that stays inside the root, and a path not yet on disk" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(root, "docs"))
        File.symlink(File.join(root, "docs"), File.join(root, "manual"))
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat manual/intro.md", cwd: root))).to be_allow
        expect(rule.decide(call_of("cat not/yet/here.md", cwd: root))).to be_allow
      end
    end

    # The root itself may be spelled through a link; what must hold is that the
    # path lands under the root's OWN real path.
    it "judges against the root's real path when the root is reached through a link" do
      in_tree do |root, home|
        linked = File.join(File.dirname(root), "repo-link")
        File.symlink(root, linked)

        expect(rule_for(home, linked).decide(call_of("cat README.md", cwd: linked))).to be_allow
      end
    end

    it "approves nothing when the session confines nothing" do
      in_tree do |root, home|
        rule = rule_for(home, root, confinement: Lain::Approval::Root::NOWHERE)

        expect(rule.decide(call_of("cat README.md | head -20", cwd: root))).to be_nil
      end
    end
  end

  # The GATED tier was sized for "a human is still asked". This rule asks
  # nobody, so a credential file the table did not name was released to the
  # model verbatim -- measured, with a fake token coming back intact.
  describe "a named credential file inside the root" do
    it "refuses every name the widened credential tier added" do
      in_tree do |root, home|
        named = ["cat config/master.key", "cat config/credentials.yml.enc", "cat .pgpass", "cat server.key",
                 "grep TOKEN .bash_history", "cat .gem/credentials", "cat .ssh/config", "cat rclone.conf",
                 "cat login.keyring", "cat keyrings/login", "cat id_rsa", "cat deploy/id_ed25519", "cat id_ecdsa"]
        expect_allowed_by_the_verdict(*named)

        rule = rule_for(home, root)
        expect(named.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * named.size)
      end
    end

    # Over the real file: its base64 blob is a high-entropy run, so the
    # approval holds only while the detector knows a public key is not a secret.
    it "still approves the public half of a key pair" do
      in_tree do |root, home|
        pub = on_disk(root, "id_ed25519.pub", public_key_line)
        expect(File.file?(pub)).to be(true)

        expect(rule_for(home, root).decide(call_of("cat id_ed25519.pub", cwd: root))).to be_allow
      end
    end
  end

  # The classifier judges a NAME, so a key under an ordinary one -- measured, a
  # 0600 `deploy_key` and a PKCS#8 block pasted into a notes file -- was
  # printed to the model with nobody asked, while `read_file` of the same bytes
  # masked it. The rule now asks the file itself.
  describe "a file whose name says nothing about what it holds" do
    # Literal and obviously fake, never sliced from the detector's tables.
    let(:pkcs8) do
      "-----BEGIN PRIVATE KEY-----\n" \
        "MIIBVgIBADANBgkqhkiG9w0BAQEFAASCAUAwggE8AgEAAkEAqwertyuiop\n" \
        "asdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM1234567890abcdef\n" \
        "-----END PRIVATE KEY-----\n"
    end

    def write_file(root, name, body, mode)
      File.join(root, name).tap do |path|
        File.write(path, body)
        File.chmod(mode, path)
      end
    end

    it "refuses a world-readable file under an unknown name that holds a netrc machine line" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        write_file(root, "notes.cfg", "machine h login u password hunter2hunter2\n", 0o644)
        expect_allowed_by_the_verdict("cat notes.cfg")

        expect(rule_for(home, root).decide(call_of("cat notes.cfg", cwd: root))).to be_nil
      end
    end

    it "refuses a file its owner closed to everyone else, whatever it is called" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        write_file(root, "deploy_key", "nothing that looks like a secret\n", 0o600)
        expect_allowed_by_the_verdict("cat deploy_key")

        expect(rule_for(home, root).decide(call_of("cat deploy_key", cwd: root))).to be_nil
      end
    end

    it "refuses a world-readable file whose bytes carry a private key" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        write_file(root, "notes.txt", "deploy notes\n#{pkcs8}", 0o644)
        expect_allowed_by_the_verdict("cat notes.txt")

        expect(rule_for(home, root).decide(call_of("cat notes.txt", cwd: root))).to be_nil
      end
    end

    it "still approves an ordinary world-readable file that exists" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        write_file(root, "README.md", "# A project\n\nNothing secret here.\n", 0o644)

        expect(rule_for(home, root).decide(call_of("cat README.md | head -20", cwd: root))).to be_allow
      end
    end

    # `tail` prints exactly the bytes a bounded scan never read, so a file
    # larger than the scan is not vouched for.
    it "refuses a tail of a file larger than the content scan, whose key lies past it" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        key_line = "API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n"
        write_file(root, "app.log", "#{"log line\n" * (80 * 1024 / 9)}#{key_line}", 0o644)
        expect_allowed_by_the_verdict("tail -n 1 app.log")

        expect(rule_for(home, root).decide(call_of("tail -n 1 app.log", cwd: root))).to be_nil
      end
    end

    it "asks through any stage of the pipeline, not only the first" do
      in_tree do |root, home|
        FileUtils.mkdir_p(root)
        write_file(root, "README.md", "# A project\n", 0o644)
        write_file(root, "deploy_key", "opaque\n", 0o600)

        expect(rule_for(home, root).decide(call_of("cat README.md | grep -n x deploy_key", cwd: root))).to be_nil
      end
    end
  end

  # Measured: `cat password.txt` holding a bare `hunter2` was approved, since
  # no region detector fires on a value with no assignment around it. The name
  # is the only signal, and on a source file it says nothing about the bytes.
  describe "a file or directory whose name names a secret" do
    it "abstains on a data file whose name, or a directory's below the root, names a secret" do
      in_tree do |root, home|
        names = %w[password.txt Password.TXT secret.txt token.txt api_key.txt credentials secrets/prod.yml
                   private/notes.txt vault-pass.txt]
        names.each { |name| on_disk(root, name, "hunter2\n") }
        commands = names.map { |name| "cat #{name}" }
        expect_allowed_by_the_verdict(*commands)

        rule = rule_for(home, root)
        expect(commands.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * names.size)
      end
    end

    it "abstains on an ordinary name that lands on a file whose name names a secret" do
      in_tree do |root, home|
        on_disk(root, "password.txt", "hunter2\n")
        File.symlink(File.join(root, "password.txt"), File.join(root, "readme.txt"))

        expect(rule_for(home, root).decide(call_of("cat readme.txt", cwd: root))).to be_nil
      end
    end

    it "still approves a source file whose name or directory names one" do
      in_tree do |root, home|
        names = %w[session.rb auth.py token.ts session.sh auth/token.rb]
        names.each { |name| on_disk(root, name, "x = 1\n") }

        rule = rule_for(home, root)
        expect(names.map { |name| rule.decide(call_of("cat #{name}", cwd: root)) }).to all(be_allow)
      end
    end

    it "approves a name the rule reads by substring no longer" do
      in_tree do |root, home|
        names = %w[AUTHORS tokenizer.json compass.yml]
        names.each { |name| on_disk(root, name, "plain\n") }

        rule = rule_for(home, root)
        expect(names.map { |name| rule.decide(call_of("cat #{name}", cwd: root)) }).to all(be_allow)
      end
    end

    # The classifier judges every word as a name, so a pattern spelled as a
    # secret word asks a human: one prompt, the gated tier's price.
    it "approves a pattern that is no secret word, and abstains on one that is" do
      in_tree do |root, home|
        on_disk(root, "lib/app.rb", "puts 1\n")
        commands = ["grep session lib/", "grep --regexp=token lib/"]
        expect_allowed_by_the_verdict(*commands)

        rule = rule_for(home, root)
        expect(commands.map { |command| rule.decide(call_of(command, cwd: root)) }).to match([be_allow, be_nil])
      end
    end
  end

  # The classifier reads the NAME it was given, by contract, and the root
  # predicate asks only WHERE a word lands -- so a link whose target is inside
  # the root satisfies both while pointing at a file the classifier would have
  # gated under its own name. MEASURED before this predicate existed, with a
  # `.env` and an `id_rsa` in the project: `cat notes.txt` and
  # `cat changelog.txt` were both APPROVED with nobody asked, the second one
  # from the DENIED tier, while the direct spelling of each refused.
  describe "a word whose name is ordinary and whose landing is not" do
    # Bytes no region detector would mask, so only the NAME the link points at
    # is what makes the file sensitive -- the content predicate admits these.
    let(:dotenv) { "API_BASE=https://example.test\nFEATURE_X=on\n" }

    it "refuses a gated file reached through an in-root link, in either spelling of the target" do
      in_tree do |root, home|
        on_disk(root, ".env", dotenv)
        File.symlink(".env", File.join(root, "notes.txt"))
        File.symlink(File.join(root, ".env"), File.join(root, "changelog.txt"))
        through = ["cat notes.txt", "cat changelog.txt", "cat notes.txt | head -20",
                   "grep -n API_BASE notes.txt"]
        expect_allowed_by_the_verdict(*through)

        rule = rule_for(home, root)
        expect(through.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * through.size)
      end
    end

    # Predicate 6 refuses `/proc` in a WORD, lexically, and a link's target is
    # not a word. So a link whose target re-enters the root through the alias
    # defeats predicate 6 and predicate 4 at once -- the word is `procenv.txt`,
    # which carries no `proc` segment and no gated name. MEASURED as an approval
    # before this predicate existed; the landing is what closes it, because
    # `File.realpath` resolves procfs like any other directory.
    it "refuses a gated file reached through a link that re-enters the root through /proc" do
      in_tree do |root, home|
        on_disk(root, ".env", dotenv)
        File.symlink("/proc/self/root#{root}/.env", File.join(root, "procenv.txt"))
        expect_allowed_by_the_verdict("cat procenv.txt")

        expect(rule_for(home, root).decide(call_of("cat procenv.txt", cwd: root))).to be_nil
      end
    end

    it "refuses a denied file reached the same way, which no human is asked about either" do
      in_tree do |root, home|
        on_disk(root, "id_rsa", "an opaque blob nothing detects\n")
        File.symlink("id_rsa", File.join(root, "readme.txt"))

        expect(rule_for(home, root).decide(call_of("cat readme.txt", cwd: root))).to be_nil
      end
    end

    # A directory link hides every name beneath it, and the word carries none
    # of them.
    it "refuses a gated file under an ordinary-named directory link" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_ed25519", "an opaque blob nothing detects\n")
        File.symlink(File.join(root, ".ssh"), File.join(root, "keys"))

        expect(rule_for(home, root).decide(call_of("cat keys/id_ed25519", cwd: root))).to be_nil
      end
    end

    # Resolution only ever REMOVES an approval.
    it "still approves an ordinary file that is not a link at all" do
      in_tree do |root, home|
        on_disk(root, "README.md", "# A project\n\nNothing secret here.\n")

        expect(rule_for(home, root).decide(call_of("cat README.md | head -20", cwd: root))).to be_allow
      end
    end

    it "still approves a link whose landing is as ordinary as its name" do
      in_tree do |root, home|
        on_disk(root, "docs/intro.md", "# Intro\n")
        File.symlink(File.join(root, "docs"), File.join(root, "manual"))

        expect(rule_for(home, root).decide(call_of("cat manual/intro.md", cwd: root))).to be_allow
      end
    end

    # A dangling link has no landing, so this predicate cannot classify one:
    # the answer is an abstention, and never a raise that would reach
    # the rules {Lain::Approval::Ladder} as a fault.
    it "abstains rather than raising on a word whose prefix resolves nowhere" do
      in_tree do |root, home|
        File.symlink(File.join(home, "absent"), File.join(root, "dangling"))
        rule = rule_for(home, root)

        nowhere = ["cat dangling", "cat dangling/x", "cat dangling/x/y"]
        expect(nowhere.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * nowhere.size)
      end
    end

    # A project checked out under a link has TWO spellings of every path it
    # holds, and a `/`-anchored config rule is written against the one the
    # session uses. An absolute landing matches no such rule, so the landing is
    # classified under both spellings -- as the kernel names it, and relative to
    # where the command will run, which the classifier resolves against the
    # session's own root.
    it "refuses a project-anchored file through a link when the root itself is spelled through one" do
      in_tree do |root, home|
        on_disk(root, "vault/secret.txt", "an ordinary looking line\n")
        on_disk(root, "README.md", "# A project\n")
        File.symlink("vault/secret.txt", File.join(root, "notes.txt"))
        linked = File.join(File.dirname(root), "repo-link")
        File.symlink(root, linked)
        rule = rule_for(home, linked, rules: Lain::Sensitivity::Rules.from({ "gated" => ["/vault/"] }),
                                      confinement: Lain::Approval::Root.new(linked))

        expect(rule.decide(call_of("cat vault/secret.txt", cwd: linked))).to be_nil
        expect(rule.decide(call_of("cat notes.txt", cwd: linked))).to be_nil
        expect(rule.decide(call_of("cat README.md", cwd: linked))).to be_allow
      end
    end

    # The other direction of the same two spellings: the cwd is reached through
    # a link, so the word's own spelling misses the rule and the kernel's
    # landing matches it.
    it "refuses a project-anchored file whose gated spelling is the one the kernel resolves" do
      in_tree do |root, home|
        on_disk(root, "vault/secret.txt", "an ordinary looking line\n")
        File.symlink(File.join(root, "vault"), File.join(root, "alias"))
        rule = rule_for(home, root, rules: Lain::Sensitivity::Rules.from({ "gated" => ["/vault/"] }))

        expect(rule.decide(call_of("cat secret.txt", cwd: "alias"))).to be_nil
        expect(rule.decide(call_of("cat alias/secret.txt", cwd: root))).to be_nil
      end
    end
  end

  describe "a program that is not on the allowlist" do
    it "refuses one that replaces its own input, and one that fetches" do
      in_tree do |root, home|
        unlisted = ["gzip important.log", "curl http://evil.sh | cat", "tee out.txt", "find . -exec rm {} ;"]
        rule = rule_for(home, root)

        expect(unlisted.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * unlisted.size)
      end
    end

    it "lets one unlisted stage sink the whole term" do
      in_tree do |root, home|
        expect_allowed_by_the_verdict("cat README.md | gzip")

        expect(rule_for(home, root).decide(call_of("cat README.md | gzip", cwd: root))).to be_nil
      end
    end

    # The list is the artifact a reviewer checks, so it is asserted as a list.
    it "carries no program that writes, deletes, fetches or executes when given argv" do
      absent = %w[gzip xz zstd tee dd xxd awk xargs curl wget sh bash python perl rm mv cp env]

      expect(described_class::PROGRAMS.keys & absent).to be_empty
    end

    # "None known" is a claim somebody made after reading the flags; a blank is
    # a claim nobody made. Every entry therefore HAS an entry, even an empty one.
    it "gives every allowlisted program a disqualifying-flag entry" do
      expect(described_class::PROGRAMS.values).to all(respond_to(:admits?))
    end
  end

  # The verdict here hands over one pipeline; a term of several is what `&&`
  # will carry, so it is built directly and handed over as an allow.
  def sequence_verdict(*pipelines)
    term = Lain::Shell::Term.new(pipelines: pipelines.map do |stages|
      Lain::Shell::Term::Pipeline.new(stages: stages.map { |argv| Lain::Shell::Term::Stage.new(argv:, discards: []) })
    end)
    ->(_command) { Lain::Shell::Verdict::Decision.new(name: :allow, reason: "sequence", term:) }
  end

  describe "lain's own read-only subcommands" do
    it "approves epic status and epic show with no model, and lain --version" do
      in_tree do |root, home|
        commands = ["lain epic status nyotes", "lain epic status", "lain epic status --mermaid nyotes",
                    "lain epic show research nyotes", "lain --version"]
        expect_allowed_by_the_verdict(*commands)

        rule = rule_for(home, root)
        expect(commands.map { |command| rule.decide(call_of(command, cwd: root)) }).to all(be_allow)
      end
    end

    it "leaves a writing subcommand, an unlisted one and a bare lain asking" do
      in_tree do |root, home|
        asking = ["lain epic submit nyotes", "lain epic add a title", "lain watch", "lain", "lain epic",
                  "lain --version extra", "lain status", "lain chat", "lain -V"]
        rule = rule_for(home, root)

        expect(asking.map { |command| rule.decide(call_of(command, cwd: root)) }).to all(be_nil)
      end
    end

    it "does not match a qualified lain" do
      in_tree do |root, home|
        expect(rule_for(home, root).decide(call_of("./lain epic status", cwd: root))).to be_nil
      end
    end
  end

  describe "a read-only probe of where the agent is and what is installed" do
    it "approves pwd, a long listing, which and a named program's --version" do
      in_tree do |root, home|
        probes = ["pwd", "ls -la", "ls", "which cargo", "which -a cargo ruby", "rustc --version"]
        expect_allowed_by_the_verdict(*probes)

        rule = rule_for(home, root)
        expect(probes.map { |command| rule.decide(call_of(command, cwd: root)) }).to all(be_allow)
      end
    end

    it "approves --version of every program in the probe table" do
      in_tree do |root, home|
        rule = rule_for(home, root)
        commands = %w[rustc cargo rustup dx adb go gcc clang cmake].map { |name| "#{name} --version" }

        expect(commands.map { |command| rule.decide(call_of(command, cwd: root)) }).to all(be_allow)
      end
    end

    # An interpreter runs what its arguments name, so the shell verdict refuses
    # it by name and no term reaches this rule.
    it "leaves an interpreter's --version asking, because the verdict refuses it" do
      in_tree do |root, home|
        expect(Lain::Shell::Verdict.new.call("ruby --version")).to be_abstain

        expect(rule_for(home, root).decide(call_of("ruby --version", cwd: root))).to be_nil
      end
    end

    it "judges every stage of every pipeline in a sequence" do
      in_tree do |root, home|
        rule = rule_for(home, root)
        safe = sequence_verdict([%w[pwd]], [%w[ls -la]])
        recursing = sequence_verdict([%w[pwd]], [%w[ls -R]])

        expect(rule.decide(call_of("pwd && ls -la", cwd: root, verdict: safe))).to be_allow
        expect(rule.decide(call_of("pwd && ls -R", cwd: root, verdict: recursing))).to be_nil
      end
    end

    it "refuses a listing that recurses or follows links" do
      in_tree do |root, home|
        hazards = ["ls -R", "ls -laR", "ls --recursive", "ls -L link", "ls -H link", "ls --dereference link",
                   "ls --dereference-command-line link", "ls --dereference-command-line-symlink-to-dir link"]
        expect_allowed_by_the_verdict(*hazards)

        rule = rule_for(home, root)
        expect(hazards.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * hazards.size)
      end
    end

    it "refuses a version probe that is not exactly a listed name and --version" do
      in_tree do |root, home|
        hazards = ["rustc -V", "rustc --version extra", "./x --version", "mytool --version", "rustc",
                   "cargo build", "cmake --version build"]
        expect_allowed_by_the_verdict(*hazards)

        rule = rule_for(home, root)
        expect(hazards.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * hazards.size)
      end
    end

    it "refuses which reading aliases or functions from stdin" do
      in_tree do |root, home|
        hazards = ["which -i cargo", "which --read-alias cargo", "which --read-functions cargo"]
        expect_allowed_by_the_verdict(*hazards)

        rule = rule_for(home, root)
        expect(hazards.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * hazards.size)
      end
    end

    # A rustup proxy reads `rust-toolchain.toml` from the cwd upward, and a
    # toolchain named by `path` there runs whatever binary that path holds.
    it "refuses a rustup proxy's --version under a pinned toolchain, in the cwd or any ancestor" do
      in_tree do |root, home|
        sub = File.join(root, "sub")
        FileUtils.mkdir_p(sub)
        rule = rule_for(home, root)
        proxies = ["rustc --version", "cargo --version", "rustup --version"]
        expect(proxies.map { |command| rule.decide(call_of(command, cwd: sub)) }).to all(be_allow)

        on_disk(root, "rust-toolchain.toml", "[toolchain]\npath = \"/proc/self/cwd/tc\"\n")
        expect(proxies.map { |command| rule.decide(call_of(command, cwd: sub)) }).to eq([nil] * 3)
        expect(rule.decide(call_of("gcc --version", cwd: sub))).to be_allow
      end
    end

    it "refuses a rustup proxy's --version under a legacy rust-toolchain file above the root" do
      in_tree do |root, home|
        on_disk(File.dirname(root), "rust-toolchain", "nightly\n")

        expect(rule_for(home, root).decide(call_of("cargo --version", cwd: root))).to be_nil
      end
    end

    # `ls` prints the names `list_files` withholds, so a listing is judged by
    # every entry of every directory it lists.
    it "refuses a listing of a directory holding an entry the classifier would not call ordinary" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_rsa", "opaque\n")
        on_disk(root, "plain/notes.txt", "hi\n")
        on_disk(root, "aliased/readme.txt", "hi\n")
        on_disk(root, ".env", "PLAIN=1\n")
        File.symlink(File.join(root, ".ssh"), File.join(root, "keys"))
        File.symlink(File.join(root, ".env"), File.join(root, "aliased", "settings"))
        listings = ["ls .ssh", "ls -la keys", "ls -la", "ls aliased", "ls -- aliased", "ls plain .ssh"]
        expect_allowed_by_the_verdict(*listings, "ls plain")

        rule = rule_for(home, root)
        expect(listings.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * listings.size)
        expect(rule.decide(call_of("ls -la plain", cwd: root))).to be_allow
        expect(rule.decide(call_of("ls", cwd: File.join(root, "plain")))).to be_allow
      end
    end

    # `ls` prints no dot entry unless it is asked to.
    it "judges a dot entry only for a listing that shows dot entries" do
      in_tree do |root, home|
        on_disk(root, "dotted/.env", "PLAIN=1\n")
        on_disk(root, "dotted/notes.txt", "hi\n")
        showing = ["ls -a dotted", "ls -lA dotted", "ls --all dotted", "ls --almost-all dotted", "ls --alm dotted"]
        expect_allowed_by_the_verdict("ls -l dotted", *showing)

        rule = rule_for(home, root)
        expect(rule.decide(call_of("ls -l dotted", cwd: root))).to be_allow
        expect(rule.decide(call_of("ls", cwd: File.join(root, "dotted")))).to be_allow
        expect(showing.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * showing.size)
      end
    end

    # An option's value is not a directory to list, so reading it as one let a
    # listing of the cwd through unjudged.
    it "refuses an ls option that takes a separate value, in any spelling" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_rsa", "opaque\n")
        valued = ["ls -w 80", "ls --width 80", "ls --wid 80", "ls -T 4", "ls --tabsize 4", "ls -I x", "ls --ignore x",
                  "ls --sort size", "ls --hide x", "ls --format long", "ls --time ctime", "ls --time-style iso",
                  "ls --quoting-style c", "ls --block-size K", "ls --indicator-style slash", "ls -lw 80"]
        expect_allowed_by_the_verdict(*valued)

        rule = rule_for(home, root)
        expect(valued.map { |command| rule.decide(call_of(command, cwd: File.join(root, ".ssh"))) })
          .to eq([nil] * valued.size)
      end
    end

    # The value names a real directory here, so the cwd fallback does not run
    # and the flag table alone refuses it.
    it "refuses an ls option whose value happens to name a directory" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_rsa", "opaque\n")
        FileUtils.mkdir_p(File.join(root, ".ssh", "plain"))
        valued = ["ls -I plain", "ls --ignore plain", "ls --hide plain", "ls --sort plain"]
        expect_allowed_by_the_verdict(*valued)

        rule = rule_for(home, root)
        expect(valued.map { |command| rule.decide(call_of(command, cwd: File.join(root, ".ssh"))) })
          .to eq([nil] * valued.size)
      end
    end

    it "refuses a width or tab-size value that happens to name a directory" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_rsa", "opaque\n")
        FileUtils.mkdir_p(File.join(root, ".ssh", "80"))
        valued = ["ls -w 80", "ls --width 80", "ls -T 80", "ls --tabsize 80"]
        expect_allowed_by_the_verdict(*valued)

        rule = rule_for(home, root)
        expect(valued.map { |command| rule.decide(call_of(command, cwd: File.join(root, ".ssh"))) })
          .to eq([nil] * valued.size)
      end
    end

    it "judges the cwd's entries when no operand of an ls is a directory" do
      in_tree do |root, home|
        on_disk(root, ".ssh/id_rsa", "opaque\n")
        on_disk(root, ".ssh/notes.txt", "hi\n")
        on_disk(root, "plain/notes.txt", "hi\n")
        expect_allowed_by_the_verdict("ls notes.txt")

        rule = rule_for(home, root)
        expect(rule.decide(call_of("ls notes.txt", cwd: File.join(root, ".ssh")))).to be_nil
        expect(rule.decide(call_of("ls notes.txt", cwd: File.join(root, "plain")))).to be_allow
      end
    end

    it "judges a dot entry by its own name, though it links to an ordinary file" do
      in_tree do |root, home|
        on_disk(root, "linked/notes.txt", "hi\n")
        File.symlink(File.join(root, "linked", "notes.txt"), File.join(root, "linked", ".env"))
        rule = rule_for(home, root)

        expect(rule.decide(call_of("ls -a linked", cwd: root))).to be_nil
        expect(rule.decide(call_of("ls linked", cwd: root))).to be_allow
      end
    end

    it "refuses a rustup proxy's --version under a dangling rust-toolchain.toml link" do
      in_tree do |root, home|
        File.symlink(File.join(root, "nowhere"), File.join(root, "rust-toolchain.toml"))

        expect(rule_for(home, root).decide(call_of("cargo --version", cwd: root))).to be_nil
      end
    end

    # The toolchain and listing predicates each resolve the cwd themselves, so
    # each must refuse, not approve, when that resolution fails.
    it "refuses a probe or a listing whose cwd cannot be resolved" do
      in_tree do |root, home|
        factory = factory_for(home, root)
        refusing = Class.new(SimpleDelegator) do
          def confinement(cwd)
            Class.new(SimpleDelegator) do
              def landing_of(word) = word == "." ? raise(Errno::ENOENT, word) : __getobj__.landing_of(word)
            end.new(__getobj__.confinement(cwd))
          end
        end.new(factory)
        commands = ["rustc --version", "ls"]

        real = described_class.new(sensitivity: factory)
        unresolved = described_class.new(sensitivity: refusing)
        expect(commands.map { |command| real.decide(call_of(command, cwd: root)) }).to all(be_allow)
        expect(commands.map { |command| unresolved.decide(call_of(command, cwd: root)) }).to eq([nil, nil])
      end
    end

    # `which` reads no file its arguments name: a bare word is a program name,
    # so a checkout entry of that name landing on a credential is not a read.
    it "skips the landing predicate for a bare name given to which, and for nothing else" do
      in_tree do |root, home|
        on_disk(root, ".env", "PLAIN=1\n")
        File.symlink(File.join(root, ".env"), File.join(root, "cargo"))
        commands = ["which cargo", "cat cargo", "which ./cargo", "ls cargo"]
        expect_allowed_by_the_verdict(*commands)

        rule = rule_for(home, root)
        expect(commands.map { |command| rule.decide(call_of(command, cwd: root))&.verdict })
          .to eq([:allow, nil, nil, nil])
      end
    end
  end

  describe "a qualified program name" do
    # The exclusion set matches by BASENAME, which is right for a denylist:
    # `/usr/bin/curl` must not evade an exclusion of `curl`. Run the same
    # matching the other way and `/tmp/evil/cat` basenames to an allowlist
    # entry and is auto-approved -- an attacker-planted binary, with no human.
    it "refuses it however it basenames, while the bare name is still approved" do
      in_tree do |root, home|
        qualified = ["/tmp/evil/cat README.md", "./cat README.md", "bin/cat README.md"]
        expect_allowed_by_the_verdict(*qualified)

        rule = rule_for(home, root)
        expect(qualified.map { |command| rule.decide(call_of(command, cwd: root)) }).to eq([nil] * qualified.size)
        expect(rule.decide(call_of("cat README.md", cwd: root))).to be_allow
      end
    end
  end

  describe "the cwd the classifier is anchored on" do
    # The CALL's own, never the session's. A classifier built once at wiring
    # time would resolve `config` under whatever directory the agent started in
    # and approve a read of a repository's credential-bearing `.git/config`.
    it "is the call's, so a relative word under a protected directory is refused" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("cat config", cwd: File.join(root, ".git")))).to be_nil
        expect(rule.decide(call_of("cat config", cwd: root))).to be_allow
      end
    end
  end

  describe "a command carrying no term" do
    it "abstains, because there is nothing to read" do
      in_tree do |root, home|
        rule = rule_for(home, root)

        expect(rule.decide(call_of("echo a > out.txt", cwd: root))).to be_nil
        expect(rule.decide(call_of("echo $HOME && echo c", cwd: root))).to be_nil
      end
    end

    it "abstains on a tool that runs no command at all" do
      in_tree do |root, home|
        call = Lain::Approval::Rule::Call.for(tool: Lain::Tools::ReadFile.new, input: { "path" => "README.md" })

        expect(rule_for(home, root).decide(call)).to be_nil
      end
    end
  end

  describe "a program this session excludes" do
    # An exclusion makes the verdict DENY, and a deny carries no term -- so
    # predicate 1 refuses it rather than the allowlist having to know. The
    # verdict here is the session's own, which is the object the production
    # wiring hands to both the bash tool and the board.
    it "outranks the allowlist, though the program is on it" do
      in_tree do |root, home|
        excluded = Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["cat"]))

        expect(excluded.call("cat README.md")).to be_deny
        expect(rule_for(home, root).decide(call_of("cat README.md", cwd: root, verdict: excluded))).to be_nil
      end
    end
  end

  # The real resolver over a PATH each example sets, so a stage resolves where
  # execvp would find it. Freshness is by ctime against the lineage's start.
  describe "ruled by the resolved class" do
    # By default the lineage starts in the future, so no file reads as fresh.
    def classed_rule(root, home, path:, classes: true, since: Time.now + 3600, **cargo)
      described_class.new(sensitivity: classifiers(root, home, path:, since:), classes:, **cargo)
    end

    def classifiers(root, home, path:, since: Time.now + 3600)
      fresh = Lain::Shell::Executable::Fresh.for_lineage([], clock: -> { since })
      resolver = Lain::Shell::Executable::Resolver.new(root:, fresh:)
      Lain::CLI::Wiring::BoardBuild::Classifiers.new(
        home:, cwd: root, root:, confinement: Lain::Approval::Root.new(root), resolver:,
        worker_env: Lain::WorkerEnv.new(cwd: root, env: { "PATH" => path })
      )
    end

    def planted_head(home)
      File.dirname(on_disk(File.join(home, "ubin"), "head", "#!/bin/sh\nexec /usr/bin/head \"$@\"\n", mode: 0o755))
    end

    def planted_cat(dir)
      on_disk(dir, "cat", "#!/bin/sh\nexec /usr/bin/cat \"$@\"\n", mode: 0o755)
      dir
    end

    def with_readme(root) = on_disk(root, "README.md", "# A project\n")

    it "allows a system stage, and its reason names the file that runs" do
      in_tree do |root, home|
        with_readme(root)

        decision = classed_rule(root, home, path: "/usr/bin").decide(call_of("cat README.md", cwd: root))

        expect(decision).to be_allow
        expect(decision.reason).to include("cat at /usr/bin/cat (system)")
      end
    end

    it "leaves an unchanged user shim that shadows a system binary to the judge" do
      in_tree do |root, home|
        with_readme(root)
        factory = classifiers(root, home, path: "#{planted_head(home)}:/usr/bin")
        call = call_of("head -1 README.md", cwd: root)

        expect(described_class.new(sensitivity: factory, classes: true).decide(call)).to be_nil
        expect(factory.executables(call.term, root).map(&:to_journal))
          .to contain_exactly(include("klass" => "user", "shadowed" => ["/usr/bin/head"]))
      end
    end

    it "allows a system binary that shadows a user one" do
      in_tree do |root, home|
        with_readme(root)
        shim = planted_head(home)
        factory = classifiers(root, home, path: "/usr/bin:#{shim}")
        call = call_of("head -1 README.md", cwd: root)

        expect(factory.executables(call.term, root).map(&:to_journal))
          .to contain_exactly(include("klass" => "system", "shadowed" => [File.join(shim, "head")]))
        expect(described_class.new(sensitivity: factory, classes: true).decide(call)).to be_allow
      end
    end

    it "allows an unchanged user binary that shadows nothing" do
      in_tree do |root, home|
        with_readme(root)
        bin = File.dirname(on_disk(File.join(home, "ubin"), "rev", "#!/bin/sh\nexec /usr/bin/rev \"$@\"\n",
                                   mode: 0o755))

        expect(classed_rule(root, home, path: bin).decide(call_of("rev README.md", cwd: root))).to be_allow
      end
    end

    it "leaves a fresh user file to the judge" do
      in_tree do |root, home|
        with_readme(root)
        since = Time.now - 60
        bin = planted_cat(File.join(home, ".local", "bin"))

        expect(classed_rule(root, home, path: "#{bin}:/usr/bin", since:).decide(call_of("cat README.md", cwd: root)))
          .to be_nil
      end
    end

    it "leaves a project file to the judge" do
      in_tree do |root, home|
        with_readme(root)
        bin = planted_cat(File.join(root, "bin"))

        expect(classed_rule(root, home, path: "#{bin}:/usr/bin").decide(call_of("cat README.md", cwd: root)))
          .to be_nil
      end
    end

    describe "why a call it leaves to the judge was left" do
      def note_for(rule, command, root) = rule.why_not(call_of(command, cwd: root))

      it "names a project binary and the system one it shadows" do
        in_tree do |root, home|
          with_readme(root)
          bin = planted_cat(File.join(root, "bin"))
          rule = classed_rule(root, home, path: "#{bin}:/usr/bin")

          expect(note_for(rule, "cat README.md", root))
            .to eq("cat resolved to #{bin}/cat (project), shadowing /usr/bin/cat")
        end
      end

      it "says a user file written this session is fresh" do
        in_tree do |root, home|
          with_readme(root)
          bin = planted_cat(File.join(home, ".local", "bin"))
          rule = classed_rule(root, home, path: "#{bin}:/usr/bin", since: Time.now - 60)

          expect(note_for(rule, "cat README.md", root)).to include("cat resolved to #{bin}/cat (user)")
            .and include("written this session")
        end
      end

      it "names the run file that stopped it, not only the binary" do
        in_tree do |root, home|
          outside = on_disk(File.join(File.dirname(root), "out"), "Cargo.toml", "[package]\nname = \"x\"\n")
          File.symlink(outside, File.join(root, "Cargo.toml"))
          bin = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))
          rule = classed_rule(root, home, path: bin)

          expect(note_for(rule, "cargo --version", root)).to include("runs #{root}/Cargo.toml (project)")
        end
      end

      it "says a path-named program written this session is fresh" do
        in_tree do |root, home|
          on_disk(root, "run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
          rule = classed_rule(root, home, path: "/usr/bin", since: Time.now - 60)

          expect(note_for(rule, "./run.sh", root)).to include("written this session")
        end
      end

      it "gives no note when a listed stage's flag refuses, whatever else the term holds" do
        in_tree do |root, home|
          with_readme(root)
          on_disk(root, "run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
          rule = classed_rule(root, home, path: "/usr/bin", since: Time.now - 60)

          expect(note_for(rule, "grep -f README.md README.md && ./run.sh", root)).to be_nil
        end
      end

      it "explains an unlisted bare program given a flag" do
        in_tree do |root, home|
          bin = File.dirname(on_disk(File.join(root, "bin"), "mytool", "#!/bin/sh\necho hi\n", mode: 0o755))
          rule = classed_rule(root, home, path: "#{bin}:/usr/bin")

          expect(note_for(rule, "mytool --verbose", root)).to include("mytool resolved to #{bin}/mytool (project)")
        end
      end

      it "gives no note when a predicate other than the class one refuses" do
        in_tree do |root, home|
          with_readme(root)
          bin = File.dirname(on_disk(File.join(root, "bin"), "grep", "#!/bin/sh\nexec /usr/bin/grep \"$@\"\n",
                                     mode: 0o755))
          rule = classed_rule(root, home, path: "#{bin}:/usr/bin")

          expect(note_for(rule, "grep -f README.md README.md", root)).to be_nil
        end
      end

      it "states the PATH anomaly when that, not the file, stopped the stage" do
        in_tree do |root, home|
          with_readme(root)
          bin = planted_cat(File.join(root, "bin"))
          rule = classed_rule(root, home, path: "#{bin}:/usr/bin")

          expect(note_for(rule, "head README.md && cat README.md", root))
            .to eq("head resolved to /usr/bin/head (system), with a project path entry")
        end
      end

      it "says a program that resolved to no file did not" do
        in_tree do |root, home|
          with_readme(root)

          expect(note_for(classed_rule(root, home, path: home), "cat README.md", root))
            .to eq("cat did not resolve to a file")
        end
      end

      it "gives no note for a call the rule allows" do
        in_tree do |root, home|
          with_readme(root)

          rule = classed_rule(root, home, path: "/usr/bin")
          expect(rule.decide(call_of("cat README.md", cwd: root))).to be_allow
          expect(note_for(rule, "cat README.md", root)).to be_nil
        end
      end

      it "gives no note when the rule is not ruled by class" do
        in_tree do |root, home|
          with_readme(root)
          bin = planted_cat(File.join(root, "bin"))

          expect(note_for(classed_rule(root, home, path: "#{bin}:/usr/bin", classes: false), "cat README.md", root))
            .to be_nil
        end
      end

      it "resolves the stages once for a call it decides and then explains" do
        in_tree do |root, home|
          with_readme(root)
          bin = planted_cat(File.join(root, "bin"))
          factory = classifiers(root, home, path: "#{bin}:/usr/bin")
          counted = ComposedTermSpecSupport::CountingFactory.new(factory)
          rule = described_class.new(sensitivity: counted, classes: true)
          call = call_of("cat README.md", cwd: root)

          rule.decide(call)
          rule.why_not(call)

          expect(counted.resolutions).to eq(1)
        end
      end
    end

    it "leaves an unresolved stage to the judge" do
      in_tree do |root, home|
        with_readme(root)

        expect(classed_rule(root, home, path: home).decide(call_of("cat README.md", cwd: root))).to be_nil
      end
    end

    it "leaves a PATH anomaly to the judge" do
      in_tree do |root, home|
        with_readme(root)

        expect(classed_rule(root, home, path: ":/usr/bin").decide(call_of("cat README.md", cwd: root))).to be_nil
      end
    end

    # cargo's --version is held to the same run files as its check: the
    # project's own, inside the root, wherever the call runs from.
    it "approves cargo --version over the project's own run files, in the root or a crate below it" do
      in_tree do |root, home|
        on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\n")
        on_disk(root, "crate/Cargo.toml", "[package]\nname = \"inner\"\n")
        bin = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))
        rule = classed_rule(root, home, path: bin)

        expect([root, "crate"].map { rule.decide(call_of("cargo --version", cwd: _1)) }).to all(be_allow)
      end
    end

    it "leaves cargo to the judge when its run file links out of the root" do
      in_tree do |root, home|
        outside = on_disk(File.join(File.dirname(root), "out"), "Cargo.toml", "[package]\nname = \"x\"\n")
        File.symlink(outside, File.join(root, "Cargo.toml"))
        bin = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))

        expect(classed_rule(root, home, path: bin).decide(call_of("cargo --version", cwd: root))).to be_nil
      end
    end

    # The project's own build files are what an admitted cargo run is for;
    # the cargo binary itself is still classed.
    it "approves a locked cargo check over the project's own build files, and still classes cargo" do
      in_tree do |root, home|
        %w[Cargo.toml Cargo.lock build.rs .cargo/config.toml].each { on_disk(root, _1, "\n") }
        user = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))
        planted = File.dirname(on_disk(File.join(root, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))
        rule = ->(bin) { classed_rule(root, home, path: bin, cargo_home: File.join(home, ".cargo")) }

        expect(rule.call(user).decide(call_of("cargo check --locked", cwd: root))).to be_allow
        expect(rule.call(planted).decide(call_of("cargo check --locked", cwd: root))).to be_nil
      end
    end

    # The link sits in a user directory with no anomaly on PATH, so only the
    # class of the file it lands on can refuse it.
    it "leaves a user link to a project file to the judge" do
      in_tree do |root, home|
        with_readme(root)
        bin = File.join(home, ".local", "bin")
        FileUtils.mkdir_p(bin)
        File.symlink(File.join(planted_cat(File.join(root, "bin")), "cat"), File.join(bin, "cat"))

        expect(classed_rule(root, home, path: "#{bin}:/usr/bin").decide(call_of("cat README.md", cwd: root)))
          .to be_nil
      end
    end

    # No allowlisted program is a wrapper, so a resolver that reports one is
    # stood in for; the rule must read what it is handed, not what it expects.
    describe "given stages no real cat resolves to" do
      def handing(root, home, answer)
        factory = classed_rule(root, home, path: "/usr/bin").instance_variable_get(:@sensitivity)
        stand_in = SimpleDelegator.new(factory)
        stand_in.define_singleton_method(:executables) { |term, cwd| answer.call(term, cwd) }
        described_class.new(sensitivity: stand_in, classes: true)
      end

      def system_cat(wrappers: [])
        Lain::Shell::Executable.new(
          name: "cat", resolved: "/usr/bin/cat", realpath: "/usr/bin/cat", chain: ["/usr/bin/cat"], shadowed: [],
          anomalies: [], klass: :system, fresh: false, run_files: [], wrappers:
        )
      end

      it "leaves a system stage under a project wrapper to the judge" do
        in_tree do |root, home|
          with_readme(root)
          wrapper = Lain::Shell::Executable.new(**system_cat.to_h, name: "nice", klass: :project)

          wrapped = ->(*) { [system_cat(wrappers: [wrapper])] }

          expect(handing(root, home, ->(*) { [system_cat] }).decide(call_of("cat README.md", cwd: root))).to be_allow
          expect(handing(root, home, wrapped).decide(call_of("cat README.md", cwd: root))).to be_nil
        end
      end

      it "abstains rather than raising when resolving fails" do
        in_tree do |root, home|
          with_readme(root)

          raising = ->(*) { raise Errno::EACCES }

          expect(handing(root, home, raising).decide(call_of("cat README.md", cwd: root))).to be_nil
        end
      end
    end

    it "changes nothing when the arm is off" do
      in_tree do |root, home|
        with_readme(root)
        bin = planted_cat(File.join(root, "bin"))

        expect(classed_rule(root, home, path: "#{bin}:/usr/bin", classes: false)
          .decide(call_of("cat README.md", cwd: root))).to be_allow
      end
    end
  end

  # The verdict abstains on every command below, for a `cd`, a quoted word or a
  # program that can run another; this rule reads those itself.
  describe "a command the verdict leaves to a shell" do
    def expect_left_to_a_shell(*commands)
      verdict = Lain::Shell::Verdict.new
      expect(commands.map { |command| verdict.call(command).name }).to eq([:abstain] * commands.size)
    end

    def views(root)
      on_disk(root, ".lain-views/a.md", "Given a tree\nWhen\n")
      on_disk(root, ".lain-views/b.md", "Given another\n")
    end

    it "approves the trial's grep after a cd, under this rule's name" do
      in_tree do |root, home|
        views(root)
        command = 'cd .lain-views && grep -c "Given" a.md b.md'
        expect_left_to_a_shell(command)

        decision = rule_for(home, root).decide(call_of(command, cwd: root))

        expect(decision).to have_attributes(verdict: :allow, rule: described_class.rule_name)
      end
    end

    # From the round 3 journal, where a person approved it by hand. Inside
    # double quotes bash keeps a backslash before `|`, so grep is given `\|`.
    it "approves the trial's alternation, whose backslashes a shell keeps inside double quotes" do
      in_tree do |root, home|
        views(root)
        command = 'cd .lain-views && grep -n "leak\\|iterations\\|ggml" a.md | head -20'
        expect_left_to_a_shell(command)

        rule = rule_for(home, root)
        expect(rule.decide(call_of(command, cwd: root))).to be_allow
        expect(rule.decide(call_of('cd .lain-views && grep -n "a\\$HOME" a.md', cwd: root))).to be_nil
        expect(rule.decide(call_of('cd .lain-views && grep -n "a\\"b" a.md', cwd: root))).to be_nil
      end
    end

    it "judges the words where the cd lands" do
      in_tree do |root, home|
        views(root)
        on_disk(root, ".lain-views/.env", "API_TOKEN=x\n")

        expect(rule_for(home, root).decide(call_of("cd .lain-views && cat .env", cwd: root))).to be_nil
      end
    end

    it "refuses a cd out of the root, as written or through a link" do
      in_tree do |root, home|
        views(root)
        outside = File.join(home, "elsewhere")
        on_disk(outside, "a.md", "Given\n")
        File.symlink(outside, File.join(root, "out"))
        commands = ["cd #{outside} && grep -c Given a.md", "cd .. && grep -c Given repo/a.md",
                    "cd out && grep -c Given a.md"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    it "stays refused where the session excludes a program, though the verdict denies before it reads" do
      in_tree do |root, home|
        views(root)
        excluded = Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["grep"]))
        command = "cd .lain-views && grep -c Given a.md"

        expect(excluded.call(command)).to be_deny
        expect(rule_for(home, root).decide(call_of(command, cwd: root, verdict: excluded))).to be_nil
      end
    end

    it "refuses a grep whose path lies outside the requester's reads, and approves one inside them" do
      in_tree do |root, home|
        reads = File.join(home, "reads")
        on_disk(reads, "a.md", "Given\n")
        on_disk(home, "other/a.md", "Given\n")
        rule = described_class.new(sensitivity: Lain::CLI::Wiring::BoardBuild::Classifiers.new(
          home:, cwd: root, root:, confinement: Lain::Approval::Root.new(root), reads: [reads]
        ))

        expect(rule.decide(call_of("grep -c 'Given' #{home}/other/a.md", cwd: root))).to be_nil
        expect(rule.decide(call_of("grep -c 'Given' #{reads}/a.md", cwd: root))).to be_allow
      end
    end
  end

  # A real repository, as `git init` writes it, so the config this rule reads
  # is the one git would.
  def git_repo(root, config: nil)
    _, status = Open3.capture2e(SeedRepo::SCRUB, "git", "init", "-q", root)
    raise "git init failed" unless status.success?

    File.write(File.join(root, ".git", "config"), config, mode: "a") if config
    root
  end

  def committed(root, message: "init", **files)
    git_repo(root)
    files.each { |name, body| on_disk(root, name, body) }
    SeedRepo.git(root, "add", "-A")
    SeedRepo.git(root, "-c", "user.name=dev", "-c", "user.email=dev@example.com", "commit", "-qm", message)
  end

  def with_env(values)
    saved = values.keys.to_h { [_1, ENV.fetch(_1, nil)] }
    ENV.update(values)
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  describe "git's read subcommands", :seam do
    it "approves a log with no body and a diff that prints only its stat" do
      in_tree do |root, home|
        git_repo(root)
        command = "git log --oneline -5 && git diff --stat"

        expect(rule_for(home, root).decide(call_of(command, cwd: root))).to be_allow
      end
    end

    it "approves the forms that print commit ids, subjects and counts" do
      in_tree do |root, home|
        git_repo(root)
        commands = ["git rev-parse HEAD", "git log --format='%h %s' -3", "git log --pretty=oneline",
                    "git log --oneline main..HEAD", "git log --oneline --shortstat", "git diff --shortstat HEAD~1"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    # A file name is held to the classifier wherever else this rule lets one
    # print -- `ls` entry by entry, `find` over its whole tree -- and a log's
    # names are those of every commit it walks, which nothing here reads.
    it "refuses the log and diff forms that list file names, which no name check holds" do
      in_tree do |root, home|
        git_repo(root)
        commands = ["git log --oneline --stat",
                    "git log --oneline --name-only", "git log --oneline --name-status", "git log --oneline --numstat",
                    "git log --oneline --raw", "git log --oneline --summary", "git log --oneline --dirstat",
                    "git diff --name-only", "git diff --name-status", "git diff --numstat"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    it "refuses every form that can print a file's bytes, a commit body, or reach another program" do
      in_tree do |root, home|
        git_repo(root)
        commands = ["git log", "git log -p --oneline", "git log --oneline --patch", "git log --format=%B",
                    "git log --oneline --format=medium", "git log --format='%h %b'", "git show HEAD",
                    "git show --stat", "git diff", "git diff --stat -p", "git diff --stat --check",
                    "git diff --stat --output=out.txt", "git diff --stat --ext-diff", "git diff --stat --textconv",
                    "git diff --stat --no-index a b", "git log -S secret --oneline",
                    "git log --oneline --show-signature", "git log --oneline --notes", "git log --format='%h %G?'",
                    "git -C . log --oneline", "git --no-pager log --oneline", "git -c core.pager=sh log --oneline",
                    "git branch -D main", "git commit -m x", "git log --oneline -- .env", "git blame README.md",
                    "git log --oneline -L1,2:README.md", "git diff --stat -O order.txt", "git log --oneline --dd",
                    "git log --oneline --diff-merges=on"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # The repository's own spec holds each config shape; this is the rule asking it.
    it "refuses where the repository's own config names a program git would run" do
      in_tree do |root, home|
        git_repo(root, config: "[core]\n\tfsmonitor = id\n")

        expect(rule_for(home, root).decide(call_of("git diff --stat", cwd: root))).to be_nil
      end
    end

    it "approves git status by rule" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        on_disk(root, "notes.md", "draft\n")

        expect(rule_for(home, root).decide(call_of("git status --short", cwd: root))).to be_allow
      end
    end

    it "approves status, ls-files and a branch listing whose printed names are ordinary" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", ".gitignore" => ".env\n")
        on_disk(root, ".env", "API_TOKEN=x\n")
        on_disk(root, "lib/a.rb", "2\n")
        commands = ["git status", "git status -s -b", "git status --porcelain -z -uall", "git status -- lib",
                    "git ls-files", "git ls-files -s lib", "git branch", "git branch -a -v",
                    "git branch --show-current"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "refuses a status or ls-files that would print a name the classifier withholds" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", "config/.env" => "API_TOKEN=x\n")
        on_disk(root, ".env.local", "API_TOKEN=y\n")
        commands = ["git status", "git status --short", "git ls-files", "git ls-files config"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
        expect(rule.decide(call_of("git ls-files lib", cwd: root))).to be_allow
      end
    end

    it "refuses the status, ls-files and branch forms that print more, write, or take a value" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        commands = ["git status --ignored", "git status -v", "git status --column=always", "git ls-files -o",
                    "git ls-files --others", "git ls-files -i", "git ls-files --recurse-submodules",
                    "git ls-files --format=%(path)", "git branch new", "git branch -D main", "git branch -d main",
                    "git branch -m main other", "git branch -c main other", "git branch -f main",
                    "git branch --list 'ma*'", "git branch --contains HEAD", "git -C . status",
                    "git -c core.fsmonitor=id status", "git --git-dir=/tmp/x status", "git --no-pager status"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    it "refuses a config override and a repository config that runs a program" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        expect(rule_for(home, root).decide(call_of("git -c core.fsmonitor=id status", cwd: root))).to be_nil

        File.write(File.join(root, ".git", "config"), "[core]\n\tfsmonitor = id\n", mode: "a")
        expect(rule_for(home, root).decide(call_of("git status", cwd: root))).to be_nil
      end
    end

    it "approves a show of an ordinary file, and has no opinion on a secret one" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", ".env" => "API_TOKEN=x\n")
        factory = factory_for(home, root)
        expect(factory.call(root).classify(".env")).to be_gated

        rule = described_class.new(sensitivity: factory)
        expect(rule.decide(call_of("git show HEAD:lib/a.rb", cwd: root))).to be_allow
        expect(rule.decide(call_of("git show HEAD:.env", cwd: root))).to be_nil
      end
    end

    it "reads a show's path from the tree's top, or from the cwd when it starts with ./" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", "lib/.env" => "API_TOKEN=x\n")
        lib = File.join(root, "lib")

        rule = rule_for(home, root)
        expect(rule.decide(call_of("git show HEAD:lib/a.rb", cwd: lib))).to be_allow
        expect(rule.decide(call_of("git show HEAD:./a.rb", cwd: lib))).to be_allow
        expect(rule.decide(call_of("git show HEAD:./.env", cwd: lib))).to be_nil
        expect(rule.decide(call_of("git show HEAD:lib/.env", cwd: lib))).to be_nil
      end
    end

    it "leaves a show whose paths cannot be named to the judge" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        commands = ["git show", "git show HEAD", "git show HEAD:lib", "git show HEAD:", "git show :lib/a.rb",
                    "git show HEAD:../x", "git show HEAD:/etc/passwd", "git show HEAD:lib/a.rb HEAD",
                    "git show --textconv HEAD:lib/a.rb", "git show HEAD:lib/*.rb", "git show HEAD:lib/a.rb -- lib"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    it "approves a log or diff that prints a patch when every path it names is an ordinary file" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", "Cargo.lock" => "x\n")
        on_disk(root, "lib/a.rb", "2\n")
        commands = ["git log -p --oneline -- lib/a.rb", "git log --format='%h %s' -u -3 -- lib/a.rb",
                    "git diff -- lib/a.rb", "git diff Cargo.lock", "git diff HEAD lib/a.rb",
                    "git diff -U1 HEAD -- lib/a.rb",
                    "git diff --cached -- lib/a.rb Cargo.lock"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "leaves a patch whose paths cannot be named, or that reaches past them, to the judge" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", ".env" => "API_TOKEN=x\n")
        commands = ["git log -p --oneline", "git log -p -- lib/a.rb", "git diff", "git diff HEAD", "git diff -- lib",
                    "git diff -- '*.rb'", "git diff -- .env", "git diff HEAD:lib/a.rb HEAD:.env",
                    "git diff -- gone.rb", "git log -p --oneline --full-diff -- lib/a.rb",
                    "git log -p --oneline --follow -- lib/a.rb", "git diff --ext-diff -- lib/a.rb",
                    "git diff --textconv -- lib/a.rb", "git diff --output=x -- lib/a.rb",
                    "git diff --no-index -- lib/a.rb .env", "git log -p --oneline -S x -- lib/a.rb",
                    "git log --oneline --show-signature -p -- lib/a.rb", "git diff -- :/lib/a.rb"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # --stdin reads more revs, `--` and pathspecs from the pipe, none of them a word here.
    it "refuses a log or diff that reads its pathspecs from stdin" do
      in_tree do |root, home|
        committed(root, "notes.txt" => "hello\n", ".env" => "API_TOKEN=x\n")
        on_disk(root, "notes.txt", "hello2\n")
        commands = ["printf -- '--\\n.env\\n' | git log -p --oneline --stdin -- notes.txt",
                    "printf -- '--\\n.env\\n' | git diff --stdin -- notes.txt"]

        rule = rule_for(home, root)
        expect(rule.decide(call_of("printf -- '--\\n.env\\n' | git diff -- notes.txt", cwd: root))).to be_allow
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # For ls-files `-u` is --unmerged, which prints stage lines rather than names.
    it "refuses an ls-files -u over a conflicted file the classifier withholds" do
      in_tree do |root, home|
        committed(root, "notes.txt" => "x\n", ".env" => "A=1\n")
        identity = %w[-c user.name=d -c user.email=d@e]
        commit = ->(message) { SeedRepo.git(root, *identity, "commit", "-qam", message) }
        SeedRepo.git(root, "checkout", "-qb", "other")
        on_disk(root, ".env", "A=2\n")
        commit.call("other")
        SeedRepo.git(root, "checkout", "-q", "-")
        on_disk(root, ".env", "A=3\n")
        commit.call("main")
        system(SeedRepo::SCRUB, "git", "-c", "user.name=d", "-c", "user.email=d@e", "merge", "-q", "other",
               chdir: root, out: File::NULL, err: File::NULL)
        commands = ["git ls-files -u", "git ls-files -us"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    it "counts a hook lookup git does not answer as a hook" do
      in_tree do |root, _home|
        expect(described_class::Listing.hooked?(root)).to be(true)
      end
    end

    # git refuses a blob end in a diff range itself; the rule does not lean on that refusal.
    it "refuses a range with an end that does not peel to a tree" do
      in_tree do |root, home|
        committed(root, "notes.txt" => "hello\n", ".env" => "API_TOKEN=x\n")
        blob = SeedRepo.git(root, "rev-parse", "HEAD:.env").stdout.strip
        SeedRepo.git(root, "tag", "envtag", blob)

        expect(rule_for(home, root).decide(call_of("git diff envtag..HEAD -- notes.txt", cwd: root))).to be_nil
      end
    end

    # rev-parse echoes an option-shaped word and exits 0 unless options end first.
    it "refuses a range end named like an option" do
      in_tree do |root, home|
        committed(root, "notes.txt" => "hello\n", ".env" => "API_TOKEN=x\n")
        blob = SeedRepo.git(root, "rev-parse", "HEAD:.env").stdout.strip
        SeedRepo.git(root, "update-ref", "refs/tags/-x", blob)

        expect(rule_for(home, root).decide(call_of("git diff HEAD..-x -- notes.txt", cwd: root))).to be_nil
      end
    end

    # A blob id is rev-shaped and names nothing on disk, and a diff against it
    # prints the blob; its id is itself approved, by `git rev-parse HEAD:.env`.
    it "refuses a rev that does not peel to a tree" do
      in_tree do |root, home|
        committed(root, "notes.txt" => "hello\n", ".env" => "API_TOKEN=x\n")
        blob = SeedRepo.git(root, "rev-parse", "HEAD:.env").stdout.strip
        SeedRepo.git(root, "tag", "envblob", blob)
        commands = ["git diff #{blob} -- notes.txt", "git diff #{blob} notes.txt", "git diff envblob -- notes.txt",
                    "git log -p --oneline #{blob} -- notes.txt", "git diff HEAD..#{blob} -- notes.txt"]

        rule = rule_for(home, root)
        expect(rule.decide(call_of("git diff HEAD -- notes.txt", cwd: root))).to be_allow
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # git splits `rev:path` at the first colon outside braces, so a rule that
    # split at the first colon would judge a decoy file in place of the path git reads.
    it "refuses a show whose rev:path holds more than 1 colon" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n", ".env" => "API_TOKEN=x\n", message: "fix:b release")
        on_disk(root, "b}:.env", "decoy\n")

        expect(rule_for(home, root).decide(call_of("git show 'HEAD^{/fix:b}:.env'", cwd: root))).to be_nil
      end
    end

    it "refuses a pathspec that git would read as a glob, though a file has that name" do
      in_tree do |root, home|
        committed(root, "*" => "1\n", ".env" => "API_TOKEN=x\n")
        on_disk(root, "*", "2\n")
        on_disk(root, ".env", "API_TOKEN=y\n")

        expect(rule_for(home, root).decide(call_of("git diff -- '*'", cwd: root))).to be_nil
      end
    end

    it "refuses a status that would print more names than a walk may judge" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        Lain::Approval::ComposedTerm::WALK_BOUND.succ.times { on_disk(root, "many/#{_1}.txt", "x\n") }

        rule = rule_for(home, root)
        expect(rule.decide(call_of("git status", cwd: root))).to be_allow
        expect(rule.decide(call_of("git status -uall", cwd: root))).to be_nil
      end
    end

    it "judges the name a renamed file had" do
      in_tree do |root, home|
        committed(root, ".env" => "API_TOKEN=x\n")
        SeedRepo.git(root, "mv", ".env", "settings.txt")

        expect(rule_for(home, root).decide(call_of("git status", cwd: root))).to be_nil
      end
    end

    it "refuses a status that prints a name outside the project root" do
      in_tree do |root, home|
        committed(root, "project/a.rb" => "1\n", "other/notes.txt" => "1\n")
        project = File.join(root, "project")
        rule = rule_for(home, project)
        expect(rule.decide(call_of("git status", cwd: project))).to be_allow

        on_disk(root, "other/notes.txt", "2\n")
        expect(rule.decide(call_of("git status", cwd: project))).to be_nil
      end
    end

    it "lists through git with this process's own git variables dropped" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")

        decision = with_env("GIT_DIR" => File.join(root, "nowhere")) do
          rule_for(home, root).decide(call_of("git status", cwd: root))
        end
        expect(decision).to be_allow
      end
    end

    # Refreshing the index runs post-index-change, which no config key names;
    # ls-files reads the index without refreshing it.
    it "refuses a status or diff where a post-index-change hook would run" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        commands = ["git status", "git diff --stat", "git diff -- lib/a.rb"]
        rule = rule_for(home, root)
        hook = on_disk(root, ".git/hooks/post-index-change", "#!/bin/sh\nid\n")
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)

        File.chmod(0o755, hook)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
        expect(["git log --oneline", "git ls-files"].map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "finds the hook where the user's own core.hooksPath puts it" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        hooks = File.join(home, "hooks")
        on_disk(hooks, "post-index-change", "#!/bin/sh\nid\n", mode: 0o755)
        config = on_disk(home, "gitconfig", "[core]\n\thooksPath = #{hooks}\n")

        decision = with_env("GIT_CONFIG_GLOBAL" => config) do
          rule_for(home, root).decide(call_of("git status", cwd: root))
        end
        expect(decision).to be_nil
      end
    end

    # A default status folds an untracked directory into its own name, which is
    # all it prints; the user's config can unfold it, so the mode is git's to pick.
    it "judges a folded untracked directory by its name, in the mode the stage asks for" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        on_disk(root, "drafts/.env", "API_TOKEN=x\n")
        rule = rule_for(home, root)
        expect(["git status", "git status --short"].map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
        expect(rule.decide(call_of("git status -uall", cwd: root))).to be_nil

        config = on_disk(home, "gitconfig", "[status]\n\tshowUntrackedFiles = all\n")
        decision = with_env("GIT_CONFIG_GLOBAL" => config) { rule.decide(call_of("git status", cwd: root)) }
        expect(decision).to be_nil
      end
    end

    it "asks git, and the disk, through what it is handed" do
      in_tree do |root, home|
        committed(root, "lib/a.rb" => "1\n")
        listing = Class.new do
          def initialize(names)
            @names = names
          end

          def names(*) = @names
          def trees?(*) = true
          def hooked?(*) = false
        end
        nothing = Class.new(SimpleDelegator) { def file?(_path) = false }.new(Lain::FileFacts::LIVE)
        build = ->(**rest) { described_class.new(sensitivity: factory_for(home, root), **rest) }

        expect(build.call(git: listing.new(["lib/a.rb"])).decide(call_of("git status", cwd: root))).to be_allow
        expect(build.call(git: listing.new([".env"])).decide(call_of("git status", cwd: root))).to be_nil
        expect(build.call(facts: nothing).decide(call_of("git show HEAD:lib/a.rb", cwd: root))).to be_nil
      end
    end
  end

  describe "cargo" do
    # cargo reads its own home's config, so each example names one it owns.
    around do |example|
      Dir.mktmpdir("lain-cargo-home") do |dir|
        @cargo_home = dir
        example.run
      end
    end

    attr_reader :cargo_home

    def rule_for(home, session_cwd, cargo_home: self.cargo_home, **rest)
      described_class.new(sensitivity: factory_for(home, session_cwd, **rest), cargo_home:)
    end

    def in_crate
      in_tree do |root, home|
        on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
        on_disk(root, "Cargo.lock", "version = 4\n")
        on_disk(root, "src/lib.rs", "pub fn demo() {}\n")
        yield root, home
      end
    end

    def decisions(root, home, commands)
      rule = rule_for(home, root)
      commands.map { rule.decide(call_of(_1, cwd: root)) }
    end

    it "approves a locked clippy run with merged stderr" do
      in_crate do |root, home|
        command = "cargo clippy --locked --workspace --all-targets -- -D warnings 2>&1 | tail -2"

        expect(rule_for(home, root).decide(call_of(command, cwd: root))).to be_allow
      end
    end

    it "approves fmt --check, and check, clippy, build and test pinned to the lockfile" do
      in_crate do |root, home|
        commands = ["cargo fmt --check", "cargo fmt --all --check", "cargo check --offline", "cargo build --frozen",
                    "cargo test --locked", "cargo +stable build --locked --release", "cargo +1.85.0 check --locked",
                    "cargo test --locked demo -- --nocapture", "cargo test --locked --workspace -- --test-threads=1",
                    "cargo clippy --locked --all-targets --all-features -- -D warnings -W clippy::pedantic",
                    "cargo build --locked -p demo --features serde/derive", "cargo build --locked --features=a,b",
                    "cargo check --locked --manifest-path Cargo.toml", "cargo --version"]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to all(be_allow)
      end
    end

    it "says an approved check, build, clippy or test builds, in a pipeline too" do
      in_crate do |root, home|
        commands = ["cargo check --locked", "cargo build --frozen", "cargo +stable clippy --locked -- -D warnings",
                    "cargo test --locked 2>&1 | tail -5", "cargo --version && cargo check --offline"]

        expect(decisions(root, home, commands).map(&:builds)).to all(be(true))
      end
    end

    it "says an approved version probe, fmt --check or git read builds nothing" do
      in_crate do |root, home|
        decided = decisions(root, home, ["cargo --version", "cargo fmt --check", "ls | head -1"])

        expect(decided).to all(be_allow)
        expect(decided.map(&:builds)).to all(be(false))
      end
    end

    it "leaves an unlocked run and a writing fmt to the judge" do
      in_crate do |root, home|
        commands = ["cargo build", "cargo test", "cargo clippy -- -D warnings", "cargo fmt", "cargo fmt --all",
                    "cargo build --locked=false", "cargo fmt --check -- --emit files"]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    # Each names a program, a file or a toolchain from the command line, and
    # none is code the project's own files control.
    it "refuses a config override, an unstable flag, a toolchain path and a manifest outside the root" do
      in_crate do |root, home|
        commands = [
          "cargo --config build.rustc=id build --locked", "cargo build --locked --config build.rustc=id",
          "cargo build --locked --config=build.rustc=id", "cargo build --locked --conf build.rustc=id",
          "cargo +stable --config build.rustc=id build --locked",
          "cargo -Z unstable-options test --locked", "cargo test --locked -Zunstable-options",
          "cargo test --locked -Z unstable-options", "cargo -C /tmp build --locked", "cargo build --locked -C /tmp",
          "cargo test --locked --manifest-path /tmp/x/Cargo.toml",
          "cargo test --locked --manifest-path=/tmp/x/Cargo.toml", "cargo test --locked --manifest-path ../Cargo.toml",
          "cargo +/tmp/tc build --locked", "cargo +../tc build --locked", "cargo +stable/x build --locked",
          "cargo build --locked --target-dir /tmp/t", "cargo build --locked --target-dir=/tmp/t",
          "cargo build --locked --target=/tmp/x.json", "cargo build --locked -p /tmp/x",
          "cargo build --locked --manifest-path -x"
        ]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    # The words after `--` go to rustc under clippy and to the test binaries
    # under test, and either can be told to open, write or run something.
    it "refuses a tail that is not a lint level or a test filter" do
      in_crate do |root, home|
        commands = ["cargo clippy --locked -- -C linker=id", "cargo clippy --locked -- --extern x=/tmp/y",
                    "cargo clippy --locked -- -L /tmp", "cargo clippy --locked -- -D warnings -o out",
                    "cargo test --locked -- --logfile=/tmp/x", "cargo test --locked -- --logfile x",
                    "cargo test --locked -- -Z unstable-options", "cargo build --locked -- x",
                    "cargo check --locked -- -D warnings", "cargo clippy --locked -- -D @args",
                    "cargo clippy --locked -- -Zself-profile"]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    it "refuses a subcommand that writes, installs, runs or fetches unpinned" do
      in_crate do |root, home|
        commands = ["cargo clippy --locked --fix", "cargo run --locked", "cargo install --locked demo",
                    "cargo update", "cargo publish --locked", "cargo fetch --locked", "cargo --locked build",
                    "cargo build --locked --timings", "cargo test --locked --no-run --bin"]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    # A program named in the environment is no word of the stage, so the
    # reading refuses the prefix rather than this table.
    it "refuses an environment prefix" do
      in_crate do |root, home|
        commands = ["RUSTC_WRAPPER=id cargo build --locked", "env RUSTC_WRAPPER=id cargo build --locked"]

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    # cargo-fmt takes none of the build options, and only test takes a filter.
    it "refuses an option or an operand its subcommand does not take" do
      in_crate do |root, home|
        commands = ["cargo fmt --check --features a", "cargo fmt --check -j 4", "cargo fmt --check --target t",
                    "cargo build --locked demo", "cargo check --locked demo"]
        expect_allowed_by_the_verdict(*commands)

        expect(decisions(root, home, commands)).to eq([nil] * commands.size)
      end
    end

    # cargo loads the first Cargo.toml above the cwd, then any workspace above
    # that, and every .cargo/config.toml from the cwd up to /.
    describe "the files cargo loads from above the root" do
      def above(root) = File.dirname(root)

      it "refuses a root holding no manifest under one that has a manifest" do
        in_tree do |root, home|
          on_disk(above(root), "Cargo.toml", "[package]\nname = \"outer\"\n")
          on_disk(above(root), "build.rs", "fn main() {}\n")

          expect(decisions(root, home, ["cargo build --locked", "cargo check --locked"])).to eq([nil, nil])
        end
      end

      it "refuses a crate that is a member of a workspace above the root" do
        in_crate do |root, home|
          on_disk(above(root), "Cargo.toml", "[workspace]\nmembers = [\"repo\", \"other\"]\n")
          on_disk(above(root), "other/build.rs", "fn main() {}\n")

          expect(decisions(root, home, ["cargo build --locked --workspace", "cargo test --locked"])).to eq([nil, nil])
        end
      end

      it "refuses a config above the root, which can name a rustc wrapper" do
        in_crate do |root, home|
          on_disk(above(root), ".cargo/config.toml", "[build]\nrustc-wrapper = \"/tmp/wrap.sh\"\n")

          expect(decisions(root, home, ["cargo check --locked", "cargo fmt --check"])).to eq([nil, nil])
        end
      end

      it "refuses an inert config above the root" do
        in_crate do |root, home|
          on_disk(above(root), ".cargo/config.toml", "[net]\nretry = 3\n")

          expect(decisions(root, home, ["cargo check --locked"])).to eq([nil])
        end
      end

      it "refuses a manifest named outside the root, or one whose workspace key points out of it" do
        in_crate do |root, home|
          on_disk(above(root), "elsewhere/Cargo.toml", "[package]\nname = \"x\"\n")
          on_disk(root, "sub/Cargo.toml", "[package]\nname = \"sub\"\nworkspace = \"../..\"\n")

          expect(decisions(root, home, ["cargo build --locked --manifest-path ../elsewhere/Cargo.toml",
                                        "cargo build --locked --manifest-path sub/Cargo.toml"])).to eq([nil, nil])
        end
      end

      it "approves a project config, and the user's own that runs nothing" do
        in_crate do |root, home|
          on_disk(root, ".cargo/config.toml", "[build]\nrustc-wrapper = \"sccache\"\n")
          on_disk(cargo_home, "config.toml", "[net]\nretry = 3\n")

          expect(decisions(root, home, ["cargo check --locked", "cargo fmt --check"])).to all(be_allow)
        end
      end

      it "refuses when the user's own config names something that runs" do
        in_crate do |root, home|
          configs = ["[build]\nrustc-wrapper = \"sccache\"\n", "[alias]\nb = \"build\"\n",
                     "[target.x86_64-unknown-linux-gnu]\nlinker = \"clang\"\n",
                     "[target.x86_64-unknown-linux-gnu]\nrunner = \"valgrind\"\n", "build.rustflags = [\"-Cx\"]\n"]

          answers = configs.map do |config|
            on_disk(cargo_home, "config.toml", config)
            rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))
          end
          expect(answers).to eq([nil] * configs.size)
        end
      end
    end

    # TOML reads a quoted key as the bare one and `\u` as any character, so a
    # key is judged by the name cargo's own parser reads, however it is spelled.
    describe "a manifest or config whose keys are quoted or escaped" do
      def quoted_aliases
        ["\"fmt\" = [\"run\", \"--\"]\n\"clippy\" = [\"run\", \"--\"]\n",
         "'fmt' = [\"run\", \"--\"]\n'clippy' = [\"run\", \"--\"]\n",
         "alias.\"fmt\" = [\"run\"]\nalias.\"clippy\" = [\"run\"]\n",
         "\"alias\".fmt = [\"run\"]\n\"alias\".clippy = [\"run\"]\n",
         "[alias]\n\"f\\u006dt\" = [\"run\"]\n\"cl\\u0069ppy\" = [\"run\"]\n"]
      end

      it "refuses fmt and clippy under an alias spelled with a quoted or escaped key" do
        in_crate do |root, home|
          answers = quoted_aliases.map do |config|
            on_disk(root, ".cargo/config.toml", config.start_with?("[") ? config : "[alias]\n#{config}")
            decisions(root, home, ["cargo fmt --check", "cargo clippy --locked -- -D warnings"])
          end

          expect(answers).to eq([[nil, nil]] * quoted_aliases.size)
        end
      end

      it "refuses a manifest whose workspace key is quoted, and approves a quoted header or an escaped value" do
        in_crate do |root, home|
          manifests = ["[package]\nname = \"demo\"\n\"workspace\" = \"../../w\"\n",
                       "[package]\nname = \"demo\"\n'workspace' = \"../../w\"\n",
                       "[\"package\"]\nname = \"demo\"\n",
                       "[package]\nname = \"d\\u0065mo\"\n"]

          answers = manifests.map do |manifest|
            on_disk(root, "Cargo.toml", manifest)
            rule_for(home, root).decide(call_of("cargo build --locked --workspace", cwd: root))&.verdict
          end

          expect(answers).to eq([nil, nil, :allow, :allow])
        end
      end

      it "still approves a manifest whose quotes are all values" do
        in_crate do |root, home|
          on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\nauthors = [\"a <a@b>\", \"c\"]\n\n" \
                                      "[dependencies]\nx = { version = \"=2.3.2\", features = [\"a\", \"b\"] }\n")

          expect(rule_for(home, root).decide(call_of("cargo build --locked", cwd: root))).to be_allow
        end
      end
    end

    # A key counts at any depth of the parsed tree, as cargo reads it, however it is spelled.
    describe "a manifest or config read as parsed TOML" do
      def check(root, home) = rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))

      it "approves a workspace root whose fields are inherited" do
        in_crate do |root, home|
          on_disk(root, "Cargo.toml", "[workspace]\nmembers = []\n\n[workspace.package]\nversion = \"0.1.0\"\n\n" \
                                      "[package]\nname = \"demo\"\nversion.workspace = true\n" \
                                      "edition = { workspace = true }\n")

          expect(check(root, home)).to be_allow
        end
      end

      it "approves a quoted table header" do
        in_crate do |root, home|
          on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\n\n[target.'cfg(unix)'.dependencies]\n" \
                                      "libc = \"0.2\"\n\n[dependencies.\"foo\"]\nversion = \"1\"\n")

          expect(check(root, home)).to be_allow
        end
      end

      it "refuses fmt and clippy aliased plain, quoted, escaped, dotted or as an inline table" do
        in_crate do |root, home|
          configs = ["[alias]\nfmt = [\"run\"]\nclippy = [\"run\"]\n",
                     "[alias]\n\"fmt\" = [\"run\"]\n'clippy' = [\"run\"]\n",
                     "[alias]\n\"f\\u006dt\" = [\"run\"]\n\"cl\\u0069ppy\" = [\"run\"]\n",
                     "alias.fmt = [\"run\"]\n\"alias\".'clippy' = [\"run\"]\n",
                     "alias = { fmt = [\"run\"], \"clippy\" = [\"run\"] }\n",
                     "[target.x86_64-unknown-linux-gnu.alias]\nfmt = [\"run\"]\nclippy = [\"run\"]\n"]

          answers = configs.map do |config|
            on_disk(root, ".cargo/config.toml", config)
            decisions(root, home, ["cargo fmt --check", "cargo clippy --locked -- -D warnings"])
          end

          expect(answers).to eq([[nil, nil]] * configs.size)
        end
      end

      it "refuses a workspace key pointing out of the root, however it is spelled" do
        in_crate do |root, home|
          manifests = ["[package]\nname = \"demo\"\nworkspace = \"../..\"\n",
                       "[package]\nname = \"demo\"\n\"workspace\" = \"../..\"\n",
                       "[package]\nname = \"demo\"\n\"work\\u0073pace\" = \"../..\"\n",
                       "package.name = \"demo\"\npackage.workspace = \"../..\"\n",
                       "package = { name = \"demo\", 'workspace' = \"../..\" }\n"]

          answers = manifests.map do |manifest|
            on_disk(root, "Cargo.toml", manifest)
            check(root, home)
          end

          expect(answers).to eq([nil] * manifests.size)
        end
      end

      it "refuses an include in the project's config or the user's own" do
        in_crate do |root, home|
          on_disk(root, ".cargo/extra.toml", "[net]\nretry = 3\n")
          include = "include = [{ path = \"extra.toml\" }]\n"

          on_disk(root, ".cargo/config.toml", include)
          project = check(root, home)
          on_disk(root, ".cargo/config.toml", "[net]\nretry = 3\n")
          on_disk(cargo_home, "config.toml", include)

          expect([project, check(root, home)]).to eq([nil, nil])
        end
      end

      it "refuses every key the user's own config can run something by, however spelled or nested" do
        in_crate do |root, home|
          keys = %w[alias rustc rustdoc rustc-wrapper rustc-workspace-wrapper runner linker rustflags rustdocflags
                    include env credential-provider global-credential-providers]
          spellings = keys.flat_map do |key|
            ["[build]\n#{key} = \"x\"\n", "[build]\n\"#{key}\" = \"x\"\n", "build.#{key} = \"x\"\n",
             "[target.x86_64-unknown-linux-gnu]\n#{key} = \"x\"\n", "[[build]]\n#{key} = \"x\"\n"]
          end

          answers = spellings.map do |config|
            on_disk(cargo_home, "config.toml", config)
            check(root, home)
          end

          expect(answers).to eq([nil] * spellings.size)
        end
      end

      it "refuses a manifest that does not parse" do
        in_crate do |root, home|
          on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\nname = \"again\"\n")

          expect(check(root, home)).to be_nil
        end
      end
    end

    # A path dependency, a build script, a target's source and a workspace
    # member are all code cargo builds and runs, so each must lie inside the root.
    describe "the paths a manifest names" do
      def check(root, home) = rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))

      def package = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n"

      def answers_for(root, home, manifests)
        manifests.map do |manifest|
          on_disk(root, "Cargo.toml", manifest)
          check(root, home)
        end
      end

      it "refuses a path dependency outside the root, inline, under a quoted header or in a target table" do
        in_crate do |root, home|
          manifests = ["#{package}\n[dependencies]\nevil = { path = \"../evil\" }\n",
                       "#{package}\n[dependencies.\"evil\"]\npath = \"../evil\"\n",
                       "#{package}\n[target.'cfg(unix)'.build-dependencies]\nevil = { path = \"../evil\" }\n",
                       "#{package}\n[workspace.dependencies]\nevil = { path = \"../evil\" }\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a build script, a patch, a replacement or a target source outside the root" do
        in_crate do |root, home|
          manifests = ["#{package}build = \"../evil/build.rs\"\n",
                       "#{package}\n[patch.crates-io]\nserde = { path = \"../evil\" }\n",
                       "#{package}\n[replace]\n\"serde:1.0.0\" = { path = \"../evil\" }\n",
                       "#{package}\n[lib]\npath = \"../evil/lib.rs\"\n",
                       "#{package}\n[[bin]]\nname = \"x\"\npath = \"../evil/main.rs\"\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a workspace member outside the root, by name or by a glob that climbs out" do
        in_crate do |root, home|
          manifests = ["#{package}\n[workspace]\nmembers = [\"../evil\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"crates/*/../../../*\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"../*\"]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a path that is not a string" do
        in_crate do |root, home|
          manifests = ["#{package}\n[lib]\npath = [\"../evil/lib.rs\"]\n",
                       "#{package}\n[workspace]\nmembers = \"../evil\"\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a path dependency inside the root whose own manifest names one outside it" do
        in_crate do |root, home|
          on_disk(root, "inner/Cargo.toml",
                  "[package]\nname = \"inner\"\n\n[dependencies]\nevil = { path = \"../../evil\" }\n")

          expect(answers_for(root, home, ["#{package}\n[dependencies]\ninner = { path = \"inner\" }\n"])).to eq([nil])
        end
      end

      it "approves path dependencies, members, a build script and a target source inside the root" do
        in_crate do |root, home|
          on_disk(root, "crates/a/Cargo.toml", "[package]\nname = \"a\"\n\n[dependencies]\nb = { path = \"../b\" }\n")
          on_disk(root, "crates/b/Cargo.toml", "[package]\nname = \"b\"\nbuild = false\n")
          manifest = "#{package}build = \"build.rs\"\n\n[lib]\npath = \"src/lib.rs\"\n\n[workspace]\n" \
                     "members = [\"crates/*\"]\n\n[dependencies]\na = { path = \"crates/a\" }\n"

          expect(answers_for(root, home, [manifest])).to all(be_allow)
        end
      end

      it "refuses a build script list naming one outside the root, or holding anything but a path" do
        in_crate do |root, home|
          manifests = ["#{package}build = [\"build.rs\", \"../evil/build.rs\"]\n",
                       "#{package}build = [\"build.rs\", 3]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      # cargo clones a `file:` or schemeless git source and reads a local index
      # off disk, so either names code outside the root with no network.
      it "refuses a git source or a registry index read from local disk" do
        in_crate do |root, home|
          manifests = ["#{package}\n[dependencies]\nevil = { git = \"file:///tmp/evilgit\" }\n",
                       "#{package}\n[dependencies]\nevil = { git = \"/tmp/evilgit\" }\n",
                       "#{package}\n[dependencies]\nevil = { git = \"../evilgit\" }\n",
                       "#{package}\n[dependencies]\nevil = { version = \"1\", registry-index = \"file:///tmp/idx\" }\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "approves a git source or a registry index fetched over the network" do
        in_crate do |root, home|
          manifests = ["#{package}\n[dependencies]\na = { git = \"https://example.com/a.git\" }\n" \
                       "b = { git = \"ssh://git@example.com/b.git\" }\nc = { git = \"git://example.com/c.git\" }\n" \
                       "d = { version = \"1\", registry-index = \"sparse+https://example.com/index/\" }\n"]

          expect(answers_for(root, home, manifests)).to all(be_allow)
        end
      end

      it "refuses a chain of path dependencies longer than the walk reads, without exhausting the stack" do
        in_crate do |root, home|
          depth = 5000
          depth.times do |n|
            on_disk(root, "c#{n}/Cargo.toml",
                    "[package]\nname = \"c#{n}\"\n\n[dependencies]\nc#{n + 1} = { path = \"../c#{n + 1}\" }\n")
          end
          on_disk(root, "c#{depth}/Cargo.toml", "[package]\nname = \"c#{depth}\"\n")

          expect(answers_for(root, home, ["#{package}\n[dependencies]\nc0 = { path = \"c0\" }\n"])).to eq([nil])
        end
      end

      it "approves path dependencies that name each other in a cycle" do
        in_crate do |root, home|
          on_disk(root, "a/Cargo.toml", "[package]\nname = \"a\"\n\n[dependencies]\nb = { path = \"../b\" }\n")
          on_disk(root, "b/Cargo.toml", "[package]\nname = \"b\"\n\n[dependencies]\na = { path = \"../a\" }\n")

          expect(answers_for(root, home, ["#{package}\n[dependencies]\na = { path = \"a\" }\n"])).to all(be_allow)
        end
      end

      it "refuses a member a glob finds, hidden or not, whose manifest names a path outside the root" do
        in_crate do |root, home|
          answers = %w[a .m].map do |member|
            FileUtils.rm_rf(File.join(root, "crates"))
            on_disk(root, "crates/#{member}/Cargo.toml",
                    "[package]\nname = \"m\"\n\n[dependencies]\nevil = { path = \"../../../evil\" }\n")
            answers_for(root, home, ["#{package}\n[workspace]\nmembers = [\"crates/*\"]\n"]).first
          end

          expect(answers).to eq([nil, nil])
        end
      end

      # A recursive glob walks a whole tree before cargo would build a thing.
      it "refuses a recursive member glob" do
        in_crate do |root, home|
          manifests = ["#{package}\n[workspace]\nmembers = [\"crates/**\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"**/*\"]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a member glob that reads more entries than its bound, matching or not" do
        in_crate do |root, home|
          FileUtils.mkdir_p(Array.new(2049) { File.join(root, "crates", "c#{_1}") })
          manifests = ["#{package}\n[workspace]\nmembers = [\"crates/*\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"crates/*/nomatch\"]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "refuses a member glob that is absolute, or whose literal prefix leads out of the root" do
        in_crate do |root, home|
          on_disk(File.dirname(root), "outside/m/Cargo.toml", "[package]\nname = \"m\"\n")
          File.symlink(File.join(File.dirname(root), "outside"), File.join(root, "link"))
          FileUtils.mkdir_p(File.join(File.dirname(root), "empty"))
          File.symlink(File.join(File.dirname(root), "empty"), File.join(root, "empty"))
          manifests = ["#{package}\n[workspace]\nmembers = [\"#{root}/crates/*\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"link/*\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"empty/*\"]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      # A `..` after a glob climbs out of whatever the glob matched, a symlink
      # included, which a lexical check reads as staying put. cargo reads a
      # brace literally, so a directory so named is walked, not expanded.
      it "refuses a member glob that climbs after matching, and walks a brace as a literal name" do
        in_crate do |root, home|
          on_disk(File.dirname(root), "outside/sub/.keep", "")
          on_disk(File.dirname(root), "outside/m/Cargo.toml", "[package]\nname = \"m\"\nbuild = \"../../evil.rs\"\n")
          on_disk(root, "crates/m/Cargo.toml", "[package]\nname = \"m\"\n")
          on_disk(root, "crates/{a,m}/x/Cargo.toml", "[package]\nname = \"x\"\nbuild = \"../../../../evil.rs\"\n")
          File.symlink(File.join(File.dirname(root), "outside/sub"), File.join(root, "crates/link"))
          manifests = ["#{package}\n[workspace]\nmembers = [\"crates/*/../m\"]\n",
                       "#{package}\n[workspace]\nmembers = [\"crates/{a,m}/*\"]\n"]

          expect(answers_for(root, home, manifests)).to eq([nil] * manifests.size)
        end
      end

      it "spends one entry budget across every manifest a call walks" do
        in_crate do |root, home|
          FileUtils.mkdir_p(Array.new(800) { File.join(root, "crates", "c#{_1}") })
          %w[c0 c1].each do |name|
            on_disk(root, "crates/#{name}/Cargo.toml",
                    "[package]\nname = \"#{name}\"\n\n[workspace]\nmembers = [\"../*\"]\n")
          end

          expect(answers_for(root, home, ["#{package}\n[workspace]\nmembers = [\"crates/*\"]\n"])).to eq([nil])
        end
      end

      it "refuses a call whose manifests together hold more bytes than it reads" do
        in_crate do |root, home|
          padding = "# #{"x" * 77}\n" * 750
          75.times do |n|
            on_disk(root, "c#{n}/Cargo.toml",
                    "[package]\nname = \"c#{n}\"\n#{padding}\n" \
                    "[dependencies]\nc#{n + 1} = { path = \"../c#{n + 1}\" }\n")
          end
          on_disk(root, "c75/Cargo.toml", "[package]\nname = \"c75\"\n")

          expect(answers_for(root, home, ["#{package}\n[dependencies]\nc0 = { path = \"c0\" }\n"])).to eq([nil])
        end
      end

      # cargo reads `~` as a directory name, not as anyone's home.
      it "reads a path starting with ~ as a name inside the root" do
        in_crate do |root, home|
          on_disk(root, "~/inner/Cargo.toml", "[package]\nname = \"inner\"\n")

          manifest = "#{package}\n[dependencies]\ninner = { path = \"~/inner\" }\n"

          expect(answers_for(root, home, [manifest])).to all(be_allow)
        end
      end
    end

    # A project config may hold only keys known to be inert, so a key this rule
    # has never read, a source, a patch, a target dir or a credential program,
    # is the judge's to weigh rather than a path to chase.
    describe "a project config's allowlist" do
      def check(root, home, command = "cargo check --locked")
        rule_for(home, root).decide(call_of(command, cwd: root))
      end

      def answers_for(root, home, configs)
        configs.map do |config|
          on_disk(root, ".cargo/config.toml", config)
          check(root, home)
        end
      end

      it "approves the inert tables and keys real crates hold" do
        in_crate do |root, home|
          configs = ["[alias]\nb = \"build\"\nxtask = \"run -p xtask --\"\n",
                     "[term]\nverbose = true\ncolor = \"always\"\n",
                     "[net]\nretry = 3\ngit-fetch-with-cli = true\noffline = true\n",
                     "[http]\ntimeout = 30\nlow-speed-limit = 10\n",
                     "[build]\njobs = 4\nincremental = false\ntarget = \"wasm32-unknown-unknown\"\n",
                     "[build]\ntarget = [\"x86_64-unknown-linux-musl\", \"wasm32-wasip1\"]\n",
                     "[cargo-new]\nvcs = \"none\"\n", "[future-incompat-report]\nfrequency = \"never\"\n"]

          expect(answers_for(root, home, configs)).to all(be_allow)
        end
      end

      it "approves a bare program, plain arguments and the flag shapes real crates use" do
        in_crate do |root, home|
          configs = ["[build]\nrustc-wrapper = \"sccache\"\nrustc-workspace-wrapper = \"sccache\"\n",
                     "[target.x86_64-unknown-linux-gnu]\nlinker = \"clang\"\n" \
                     "rustflags = [\"-C\", \"link-arg=-fuse-ld=mold\"]\n",
                     "[target.'cfg(all())']\nrunner = \"wasmtime run --wasm-features all --dir .\"\n",
                     "[target.wasm32-unknown-unknown]\nrunner = [\"wasm-bindgen-test-runner\"]\n" \
                     "rustflags = ['--cfg', 'getrandom_backend=\"wasm_js\"']\n",
                     "[build]\nrustflags = \"-C target-cpu=native\"\nrustdocflags = [\"--cfg\", \"docsrs\"]\n",
                     "[build]\nrustflags = [\"-Dunsafe_code\", \"-Wclippy::all\", \"-A\", \"dead_code\", " \
                     "\"-Fwarnings\", " \
                     "\"--cfg=web_sys_unstable_apis\"]\n",
                     "[build]\nrustflags = [\"-C\", \"target-feature=+crt-static,-x\", " \
                     "\"-Cforce-frame-pointers=true\", " \
                     "\"-Copt-level=3\", \"-C\", \"debuginfo=2\", \"-C\", \"link-dead-code=on\"]\n"]

          expect(answers_for(root, home, configs)).to all(be_allow)
        end
      end

      # Each holds no slash, yet names the root's parent or a file in the
      # directory cargo runs the child in, or unlocks a flag that can.
      it "refuses the slash-free routes out of the root" do
        in_crate do |root, home|
          configs = ["[env]\nLD_LIBRARY_PATH = { value = \"..\", force = true }\nLD_PRELOAD = \"libevil.so\"\n",
                     "[build]\nrustflags = [\"-Clink-arg=-L..\", " \
                     "\"-Clink-arg=-Wl,--push-state,--no-as-needed,-levil,--pop-state\", " \
                     "\"-Clink-arg=-Wl,-rpath,..\"]\n",
                     "[target.'cfg(all())']\nrunner = [\"env\", \"LD_LIBRARY_PATH=..\", \"LD_PRELOAD=libevil.so\"]\n",
                     "[build]\nrustflags = [\"-Zcodegen-backend=libevil.so\"]\n",
                     "[env]\nRUSTC_BOOTSTRAP = { value = \"1\", force = true }\n",
                     "[build]\nrustflags = [\"-Cincremental=..\"]\n",
                     "[env]\nRUST_TARGET_PATH = \"..\"\n" \
                     "[build]\ntarget = \"evil\"\nrustflags = [\"-Zunstable-options\"]\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "refuses a flag outside the known shapes, or one cut short" do
        in_crate do |root, home|
          flags = ["\"-Zthreads=0\"", "\"-L\", \"native\"", "\"-lfoo\"", "\"-Clink-arg=-lgcc\"", "\"-Clink-args=-x\"",
                   "\"-Cprofile-generate=x\"", "\"-C\", \"incremental=x\"", "\"-Clink-arg=-fuse-ld=..\"",
                   "\"-C\"", "\"-D\"", "\"-D\", \"-Wx\"", "\"--cfg\", \"a=b\"", "\"-Cprefer-dynamic\""]
          configs = flags.map { "[build]\nrustflags = [#{_1}]\n" }

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "refuses a runner argument with an equals sign, dots, a library flag or shell text" do
        in_crate do |root, home|
          runners = ["[\"wasmtime\", \"--dir\", \"..\"]", "[\"wasmtime\", \"--dir\", \"...\"]",
                     "\"valgrind --log-file=x\"", "[\"sh\", \"-c\", \"cd;evil\"]", "[\"wasmtime\", \"-Lx\"]",
                     "[\"wasmtime\", \"-Zx\"]", "[\"..\"]", "[\"$HOME\"]"]
          configs = runners.map { "[target.'cfg(all())']\nrunner = #{_1}\n" }

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "refuses any environment table" do
        in_crate do |root, home|
          configs = ["[env]\nRUST_LOG = \"debug\"\n", "[env]\nX = { value = \"1\", force = true }\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "refuses a key it does not know, at any table" do
        in_crate do |root, home|
          configs = ["[build]\ntarget-dir = \"t\"\n", "[build]\nbuild-dir = \"b\"\n", "[build]\nrustc = \"rustc\"\n",
                     "[build]\nrustdoc = \"rustdoc\"\n", "[http]\ncainfo = \"c.pem\"\n", "[http]\nproxy = \"p:1\"\n",
                     "[registries.loop]\nindex = \"sparse+http://127.0.0.1:1/\"\ncredential-provider = [\"prov\"]\n",
                     "[registry]\nglobal-credential-providers = [\"prov\"]\n", "[credential-alias]\nx = [\"prov\"]\n",
                     "[profile.dev]\ncodegen-backend = \"cranelift\"\n", "[doc]\nbrowser = \"firefox\"\n",
                     "[unstable]\nbuild-std = [\"core\"]\n", "[source.crates-io]\nreplace-with = \"v\"\n",
                     "[patch.crates-io]\nitoa = { path = \"patched/itoa\" }\n", "paths = [\"x\"]\n",
                     "[target.x86_64-unknown-linux-gnu.foo]\nrustc-link-lib = [\"m\"]\n",
                     "[target.x86_64-unknown-linux-gnu]\nar = \"ar\"\n", "[net]\nssh = { known-hosts = [] }\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      # A slash makes a word a path, which a symlink inside the root or the
      # directory cargo runs the child in can carry anywhere; an `@` reads a file.
      it "refuses a program, a flag or an argument holding a slash or reading a file" do
        in_crate do |root, home|
          configs = ["[build]\nrustc-wrapper = \"tools/wrap.sh\"\n", "[build]\nrustc-wrapper = \"/tmp/wrap.sh\"\n",
                     "[target.x86_64-unknown-linux-gnu]\nlinker = \"lnk/run.sh\"\n",
                     "[target.'cfg(all())']\nrunner = [\"valgrind\", \"--log-file=out/v.log\"]\n",
                     "[target.'cfg(all())']\nrunner = \"valgrind @args\"\n",
                     "[build]\nrustflags = [\"-Clinker=lnk/run.sh\"]\n", "[build]\nrustflags = \"-L vendor/lib\"\n",
                     "[build]\nrustflags = [\"@flags.txt\"]\n", "[build]\nrustdocflags = [\"--sysroot=s/x\"]\n",
                     "[target.x86_64-unknown-linux-gnu]\nrustflags = [\"-C\", \"linker=../run.sh\"]\n",
                     "[target.'cfg(all())']\nrunner = [3]\n", "[build]\nrustflags = [\"-C\", 3]\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "refuses a target that names a file rather than a triple" do
        in_crate do |root, home|
          configs = ["[build]\ntarget = \"t.json\"\n", "[build]\ntarget = \"specs/t.json\"\n",
                     "[build]\ntarget = [\"x86_64-unknown-linux-gnu\", \"t.json\"]\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      # `relative` makes even a bare value a path under the config's directory.
      it "refuses an environment value holding a slash, read relative to the config, or not text" do
        in_crate do |root, home|
          configs = ["[env]\nLD_PRELOAD = \"lnk/p.so\"\n", "[env]\nLD_PRELOAD = \"/tmp/p.so\"\n",
                     "[env]\nLD_PRELOAD = { value = \"p.so\", relative = true }\n",
                     "[env]\nX = { value = 3 }\n", "[env]\nX = { value = \"1\", other = true }\n", "env = 3\n"]

          expect(answers_for(root, home, configs)).to eq([nil] * configs.size)
        end
      end

      it "holds a config below the root's own, read from a deeper cwd, to the same list" do
        in_crate do |root, home|
          on_disk(root, "src/.cargo/config.toml", "[build]\nrustflags = [\"-Clinker=../run.sh\"]\n")

          expect(rule_for(home, root).decide(call_of("cargo check --locked", cwd: File.join(root, "src")))).to be_nil
        end
      end
    end

    describe "a manifest's unstable features and flags" do
      def check(root, home) = rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))

      def package = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n"

      # None of the crates on this box name one, and each can load code or
      # change how the build reads its files.
      it "refuses any cargo feature" do
        in_crate do |root, home|
          manifests = ["cargo-features = [\"codegen-backend\"]\n#{package}\n[profile.dev]\n" \
                       "codegen-backend = \"cranelift\"\n",
                       "cargo-features = [\"profile-rustflags\"]\n#{package}\n[profile.dev]\n" \
                       "rustflags = [\"-Dwarnings\"]\n",
                       "cargo-features = []\n#{package}"]
          answers = manifests.map do |manifest|
            on_disk(root, "Cargo.toml", manifest)
            check(root, home)&.verdict
          end

          expect(answers).to eq([nil, nil, :allow])
        end
      end

      it "refuses flags at any depth that hold a slash or read a file, and approves plain ones" do
        in_crate do |root, home|
          answers = ["[\"-Clinker=x/run.sh\"]", "[\"@args\"]", "\"-L vendor/lib\"", "[\"-Dwarnings\"]"].map do |flags|
            on_disk(root, "Cargo.toml", "#{package}\n[profile.dev]\nrustflags = #{flags}\n")
            check(root, home)&.verdict
          end

          expect(answers).to eq([nil, nil, nil, :allow])
        end
      end
    end

    it "refuses a user config that sets the environment or a credential program" do
      in_crate do |root, home|
        configs = ["[env]\nLD_PRELOAD = \"/tmp/evil.so\"\n", "[registry]\ncredential-provider = \"x\"\n",
                   "[registry]\nglobal-credential-providers = [\"x\"]\n"]

        answers = configs.map do |config|
          on_disk(cargo_home, "config.toml", config)
          rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))
        end
        expect(answers).to eq([nil] * configs.size)
      end
    end

    # Only a regular file is read, so a FIFO cannot hold the ladder open.
    it "refuses a manifest or a config that is a FIFO, without blocking" do
      in_crate do |root, home|
        File.delete(File.join(root, "Cargo.toml"))
        File.mkfifo(File.join(root, "Cargo.toml"))
        manifest = Timeout.timeout(5) { rule_for(home, root).decide(call_of("cargo build --locked", cwd: root)) }

        File.delete(File.join(root, "Cargo.toml"))
        on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\n")
        FileUtils.mkdir_p(File.join(root, ".cargo"))
        File.mkfifo(File.join(root, ".cargo", "config.toml"))
        config = Timeout.timeout(5) { rule_for(home, root).decide(call_of("cargo build --locked", cwd: root)) }

        expect([manifest, config]).to eq([nil, nil])
      end
    end

    it "refuses a config past the bound it reads" do
      in_crate do |root, home|
        on_disk(root, ".cargo/config.toml", "#{"# padding\n" * 7000}[net]\nretry = 3\n")

        expect(rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))).to be_nil
      end
    end

    # The usual layout: the project under HOME, so the ascent reaches the
    # user's own config, which is judged as the user's and not as an outsider's.
    it "approves a project under the home whose cargo home holds a quiet config" do
      in_tree do |_root, home|
        project = File.join(home, "proj")
        on_disk(project, "Cargo.toml", "[package]\nname = \"demo\"\n")
        on_disk(File.join(home, ".cargo"), "config.toml", "[net]\nretry = 3\n")
        rule = rule_for(home, project, cargo_home: File.join(home, ".cargo"))

        expect(rule.decide(call_of("cargo check --locked", cwd: project))).to be_allow
      end
    end

    # cargo loads a config's array-form `include` with no flag, so a config
    # naming another is left to the judge rather than followed.
    it "refuses a config that includes another, inside the root or out of it" do
      in_crate do |root, home|
        outside = on_disk(File.join(File.dirname(root), "out"), "extra.toml", "[alias]\nfmt = [\"run\"]\n")
        on_disk(root, ".cargo/extra.toml", "[alias]\nfmt = [\"run\", \"--offline\", \"--\"]\n")
        includes = ["include = [{ path = \"extra.toml\" }]\n", "include = [{ path = \"#{outside}\" }]\n"]

        answers = includes.map do |config|
          on_disk(root, ".cargo/config.toml", config)
          decisions(root, home, ["cargo fmt --check", "cargo check --locked"])
        end
        expect(answers).to eq([[nil, nil]] * includes.size)
      end
    end

    # fmt and clippy are external subcommands, so an alias replaces them where
    # cargo ignores one for check, build and test.
    it "refuses fmt and clippy when a config cargo reads aliases them" do
      in_crate do |root, home|
        on_disk(root, ".cargo/config.toml", "[alias]\nfmt = [\"run\", \"--offline\", \"--\"]\n" \
                                            "clippy = [\"run\", \"--offline\", \"--\"]\n")

        expect(decisions(root, home, ["cargo fmt --check", "cargo clippy --locked -- -D warnings"])).to eq([nil, nil])
        expect(rule_for(home, root).decide(call_of("cargo check --locked", cwd: root))).to be_allow
      end
    end

    it "refuses a locked build under a pinned toolchain" do
      in_crate do |root, home|
        on_disk(root, "rust-toolchain.toml", "[toolchain]\npath = \"/proc/self/cwd/tc\"\n")

        expect(rule_for(home, root).decide(call_of("cargo build --locked", cwd: root))).to be_nil
      end
    end
  end

  describe "rg" do
    it "approves a search of named files, under options known to take no value" do
      in_tree do |root, home|
        on_disk(root, "a.md", "foo\n")
        on_disk(root, "b.md", "foo\n")
        commands = ["rg -n foo a.md", "rg -c foo a.md b.md", "rg -niw foo a.md", "rg --count --no-heading foo a.md"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "refuses a search of a directory, of the cwd, and of nothing it names" do
      in_tree do |root, home|
        on_disk(root, "a.md", "foo\n")
        on_disk(root, "lib/b.md", "foo\n")
        commands = ["rg foo", "rg foo lib", "rg foo a.md lib", "rg foo missing.md"]
        expect_allowed_by_the_verdict(*commands)

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # MEASURED in review: each of these was approved and walked the cwd,
    # printing a key. An option that takes a value moves the pattern and file
    # slots, so a word read as the file may be a second pattern or a value, and
    # the real operand a directory.
    it "refuses a pattern or a value given by option, which leaves the file slots uncertain" do
      in_tree do |root, home|
        on_disk(root, "a.md", "foo\n")
        on_disk(root, "id_rsa", "-----BEGIN OPENSSH PRIVATE KEY-----\nAAA\n")
        commands = ["rg --regexp=. . a.md", "rg -e . -e a.md", "rg -T md a.md", "rg -e. . a.md", "rg -t md foo a.md",
                    "rg -m 1 foo a.md", "rg --max-count=1 foo a.md", "rg -A2 foo a.md",
                    "git log --oneline -1 && rg --regexp=. . a.md", "git status && rg --regexp=. . a.md"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end

    # Each names a real file after its pattern, so the operand predicate holds
    # and only the flag table stands between the hazard and an approval.
    it "refuses every flag that runs a program, unpacks, follows, unhides or lists, over a named file" do
      in_tree do |root, home|
        on_disk(root, "a.md", "foo\n")
        commands = ["rg --pre=cat foo a.md", "rg --pre-glob=x foo a.md", "rg -z foo a.md",
                    "rg --search-zip foo a.md", "rg -L foo a.md", "rg --follow foo a.md", "rg --hidden foo a.md",
                    "rg -. foo a.md", "rg -u foo a.md", "rg --unrestricted foo a.md", "rg --no-ignore foo a.md",
                    "rg --no-ignore-vcs foo a.md", "rg -f a.md a.md", "rg --file=a.md foo a.md",
                    "rg --files foo a.md", "rg --ignore-file=a.md foo a.md", "rg --hostname-bin=id foo a.md"]
        rule = rule_for(home, root)
        expect(rule.decide(call_of("rg foo a.md", cwd: root))).to be_allow

        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end
  end

  describe "find" do
    it "approves a listing of a small tree whose every entry is ordinary" do
      in_tree do |root, home|
        on_disk(root, "docs/a.md", "x\n")
        on_disk(root, "docs/b.rb", "x\n")

        rule = rule_for(home, root)
        expect(["find docs -name '*.md'", "find . -maxdepth 1 -type f", "find docs"]
          .map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "refuses a tree holding an entry it would print that is not ordinary, at any depth" do
      in_tree do |root, home|
        on_disk(root, "docs/a.md", "x\n")
        on_disk(root, "docs/deep/er/.env", "A=1\n")

        rule = rule_for(home, root)
        expect(rule.decide(call_of("find docs -name '*.md'", cwd: root))).to be_nil
        expect(rule.decide(call_of("find docs -maxdepth 1", cwd: root))).to be_allow
      end
    end

    # The landing pair is asked only of a link, so this is the case it is for.
    it "refuses a tree holding an ordinary name that links to a secret" do
      in_tree do |root, home|
        on_disk(root, "docs/a.md", "x\n")
        on_disk(root, ".env", "A=1\n")
        File.symlink(File.join(root, ".env"), File.join(root, "docs", "notes.txt"))

        expect(rule_for(home, root).decide(call_of("find docs", cwd: root))).to be_nil
      end
    end

    # GNU find warns and obeys the LAST -maxdepth, so reading any one of them is a guess.
    it "refuses more than one -maxdepth" do
      in_tree do |root, home|
        on_disk(root, "docs/a.md", "x\n")

        expect(rule_for(home, root).decide(call_of("find docs -maxdepth 1 -maxdepth 9", cwd: root))).to be_nil
      end
    end

    # 1001 entries, one past the bound of 1000, written out so a raised bound shows here.
    it "refuses a tree too large to walk, and a link it would follow" do
      in_tree do |root, home|
        FileUtils.mkdir_p(File.join(root, "big"))
        1001.times { File.write(File.join(root, "big", "f#{_1}"), "") }
        on_disk(root, "docs/a.md", "x\n")

        rule = rule_for(home, root)
        expect(rule.decide(call_of("find big -name f1", cwd: root))).to be_nil
        expect(["find -L docs", "find docs -follow", "find -H docs"].map { rule.decide(call_of(_1, cwd: root)) })
          .to eq([nil] * 3)
      end
    end

    it "refuses every action that runs, deletes or writes, and every start point outside the root" do
      in_tree do |root, home|
        on_disk(root, "docs/a.md", "x\n")
        commands = ["find docs -delete", "find docs -fprint out.txt", "find docs -fprint0 out.txt",
                    "find docs -fprintf out.txt %p", "find docs -fls out.txt", "find docs -files0-from list",
                    "find docs -okdir cat", "find #{home}", "find .."]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end
  end

  describe "sed -n" do
    it "approves a print of a line range, chained into head or tail" do
      in_tree do |root, home|
        on_disk(root, "a.md", "one\ntwo\n")
        commands = ["sed -n '1,20p' a.md | head -5", "sed -n 5p a.md", "sed -n '10,$p' a.md | tail -3",
                    "sed -n -e 1p -e 2p a.md", "sed -nE '1p;3p' a.md", "cat a.md | sed -n 1p"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to all(be_allow)
      end
    end

    it "refuses a script that writes, reads, runs or substitutes, and a sed with no -n" do
      in_tree do |root, home|
        on_disk(root, "a.md", "one\n")
        commands = ["sed -n 'w out.txt' a.md", "sed -n '1w out.txt' a.md", "sed -n 'r /etc/passwd' a.md",
                    "sed -n 1e a.md", "sed -n 's/a/b/w out' a.md", "sed -n 's/a/b/p' a.md", "sed 1p a.md",
                    "sed -n -i 1p a.md", "sed -ni 1p a.md", "sed -n -f s.sed a.md", "sed -n --debug 1p a.md",
                    "sed -n --in-place 1p a.md", "sed -n 1p .env", "sed -n '1p;w x' a.md"]

        rule = rule_for(home, root)
        expect(commands.map { rule.decide(call_of(_1, cwd: root)) }).to eq([nil] * commands.size)
      end
    end
  end

  describe "the hazard corpus the approval replay scores a table against", :seam do
    let(:hazards) do
      File.foreach(File.expand_path("../../fixtures/approval_replay/hazards.ndjson", __dir__)).map { JSON.parse(_1) }
    end

    # Each context the corpus names, rebuilt, so a hazard that needs one is
    # judged where it is one.
    def rebuilt(root, context)
      case context
      when nil then nil
      when "repo config sets core.pager" then git_repo(root, config: "[core]\n\tpager = sh\n")
      when "repo config sets core.fsmonitor" then git_repo(root, config: "[core]\n\tfsmonitor = id\n")
      when "repo config sets diff.external" then git_repo(root, config: "[diff]\n\texternal = id\n")
      when "linked is a link out of the root" then File.symlink("/etc", File.join(root, "linked"))
      else raise "no rebuild for #{context}"
      end
    end

    it "leaves every hazard to a person, each in the context it names" do
      hazards.each do |hazard|
        in_tree do |root, home|
          on_disk(root, "notes.md", "a note\n")
          rebuilt(root, hazard["context"])

          verdict = Lain::Shell::Verdict.new(home:)
          decision = rule_for(home, root).decide(call_of(hazard.fetch("command"), cwd: root, verdict:))
          expect(decision).to be_nil, hazard.fetch("hazard")
        end
      end
    end
  end

  describe "the programs a stage may run" do
    it "gives rg, git, find and sed a table of their own" do
      expect(described_class::PROGRAMS.values_at("rg", "git", "find", "sed")).to all(respond_to(:admits?))
    end
  end

  describe "the classifier factory" do
    # No Null default, on the `faults:` keyword's precedent in the ladder's
    # rules rung: a rule that APPROVES and was wired with a classifier
    # protecting nothing is silently lenient forever, and this is the third
    # mechanism in this codebase to have shipped that way.
    it "is required, so the rule cannot be built without one" do
      expect { described_class.new }.to raise_error(ArgumentError, /sensitivity/)
    end
  end
end
