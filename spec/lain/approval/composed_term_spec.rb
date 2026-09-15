# frozen_string_literal: true

require "fileutils"
require "tmpdir"

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
  def factory_for(home, session_cwd, confinement: Lain::Approval::Risk::Root.new(session_cwd),
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
  # LEXICALLY under the root, on {Approval::Risk::OutsideRoot}'s terms -- no
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
        rule = rule_for(home, root, confinement: Lain::Approval::Risk::Root::NOWHERE)

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
