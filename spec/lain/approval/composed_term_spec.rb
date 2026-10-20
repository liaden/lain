# frozen_string_literal: true

require "fileutils"
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
      absent = %w[gzip xz zstd tee dd xxd find awk sed xargs curl wget git sh bash python perl rm mv cp]

      expect(described_class::PROGRAMS.keys & absent).to be_empty
    end

    # "None known" is a claim somebody made after reading the flags; a blank is
    # a claim nobody made. Every entry therefore HAS an entry, even an empty one.
    it "gives every allowlisted program a disqualifying-flag entry" do
      expect(described_class::PROGRAMS.values).to all(be_a(described_class::Flags))
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

        expect(rule.decide(call_of("echo a && echo b", cwd: root))).to be_nil
        expect(rule.decide(call_of("git log --oneline -5", cwd: root))).to be_nil
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
    def classed_rule(root, home, path:, classes: true, since: Time.now + 3600)
      described_class.new(sensitivity: classifiers(root, home, path:, since:), classes:)
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

    it "leaves a build tool whose run file is the project's to the judge" do
      in_tree do |root, home|
        on_disk(root, "Cargo.toml", "[package]\nname = \"demo\"\n")
        bin = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))

        expect(classed_rule(root, home, path: bin).decide(call_of("cargo --version", cwd: root))).to be_nil
      end
    end

    it "leaves a build tool to the judge when the directory the call runs in holds its run file" do
      in_tree do |root, home|
        on_disk(root, "crate/Cargo.toml", "[package]\nname = \"demo\"\n")
        bin = File.dirname(on_disk(File.join(home, "bin"), "cargo", "#!/bin/sh\n", mode: 0o755))

        expect(classed_rule(root, home, path: bin).decide(call_of("cargo --version", cwd: "crate"))).to be_nil
        expect(classed_rule(root, home, path: bin).decide(call_of("cargo --version", cwd: root))).to be_allow
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
