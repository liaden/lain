# frozen_string_literal: true

require "shellwords"

RSpec.describe Lain::Shell::Verdict do
  subject(:verdict) { described_class.new }

  let(:parse) { Lain::Shell::Parse.new }

  def decide(command) = verdict.call(command)

  def reason_for(command) = decide(command).reason

  describe "a fully literal command" do
    let(:decision) { decide("ls -la") }

    it "is allowed" do
      expect(decision).to be_allow
      expect(decision).not_to be_abstain
      expect(decision).not_to be_deny
    end

    it "carries the reconstructed term" do
      expect(decision.term).to eq([%w[ls -la]])
    end

    it "allows the plain literal commands a session really runs" do
      ["printf hi", "cargo test", "head -20 file", "rm -rf tmp/build", "sort -u"].each do |command|
        expect(decide(command)).to be_allow, "#{command.inspect}: #{reason_for(command)}"
      end
    end

    it "allows a pipeline, whose term is the stages in order" do
      expect(decide("grep -r foo . | wc -l").term).to eq([%w[grep -r foo .], %w[wc -l]])
    end
  end

  # Tier one: a node kind says what it is, so an allowlist over kinds sees it.
  describe "a structurally tagged construct" do
    {
      "echo $(id)" => "command_substitution",
      "echo `id`" => "command_substitution",
      "echo ${FOO}" => "expansion",
      "echo $FOO" => "simple_expansion",
      "diff <(a) <(b)" => "process_substitution",
      "echo $((1 + 1))" => "arithmetic_expansion",
      "cat < f" => "file_redirect",
      "FOO=1 ls" => "variable_assignment",
      "ls # comment" => "comment",
      "echo 'a b'" => "raw_string",
      %(echo "a b") => "string"
    }.each do |command, kind|
      it "abstains on #{command.inspect}, naming #{kind}" do
        decision = decide(command)
        expect(decision).to be_abstain
        expect(decision.reason).to include(kind)
      end
    end

    # An allowlist, not a metacharacter denylist: every construct the grammar
    # tags is outside it, and so is every kind the grammar grows next.
    it "leaves every structurally tagged kind outside the literal set" do
      %w[command_substitution expansion process_substitution heredoc_redirect file_redirect
         variable_assignment subshell function_definition arithmetic_expansion].each do |kind|
        expect(described_class::LITERAL_KINDS).not_to include(kind)
      end
    end

    it "names only kinds the parser can actually report, so a typo cannot hide in the allowlist" do
      expect(described_class::LITERAL_KINDS - Lain::Shell::Parse::KINDS).to be_empty
    end

    it "abstains on compound forms whose own kind is a container" do
      ["(cd /tmp && ls)", "f() { ls; }", "cat <<EOF\nhi\nEOF", "if true; then ls; fi", "! ls"]
        .each { |command| expect(decide(command)).to be_abstain, command.inspect }
    end

    it "abstains on a quoted argument, because the parse does NOT strip the quotes" do
      expect(parse.call("echo 'a b'").stages.map(&:argv)).to eq([["echo", "'a b'"]])
      expect(decide("echo 'a b'")).to be_abstain
    end
  end

  # Tier three: no node kind exists for these at all -- the parse reports the
  # blandest possible kind set, so only the word's TEXT gives them away.
  describe "a word a shell would expand" do
    ["rm *", "ls ~/secret", "ls ~", "echo {a,b}", "ls file[1].txt", "ls ?"].each do |command|
      it "abstains on #{command.inspect}" do
        expect(decide(command)).to be_abstain
      end

      it "has nothing but bland kinds to go on for #{command.inspect}, so the text check is the only signal" do
        result = parse.call(command)
        expect(result).to be_covered
        expect(result).not_to be_broken
        expect(result.kinds - described_class::LITERAL_KINDS).to be_empty
      end
    end
  end

  # The third quoting form, and the only one with no node kind: a backslash
  # survives into the term exactly as the two quote kinds do, so allowing it
  # would exec literal quoting characters and diverge from what bash runs.
  describe "a word carrying a backslash escape" do
    ["echo foo\\ bar", "rm \\-rf /", "echo \\$HOME", "cp a\\ b c"].each do |command|
      it "abstains on #{command.inspect}" do
        expect(decide(command)).to be_abstain
      end
    end

    it "is invisible to every other tier, and diverges from what bash would run" do
      result = parse.call("echo foo\\ bar")
      expect(result).to be_covered
      expect(result).not_to be_broken
      expect(result.kinds - described_class::LITERAL_KINDS).to be_empty
      expect(result.stages.map(&:argv)).to eq([["echo", "foo\\ bar"]])
      expect(Shellwords.split("echo foo\\ bar")).to eq(["echo", "foo bar"])
    end
  end

  describe "the program-name list" do
    it "abstains on find, which runs what its arguments name" do
      decision = decide("find . -exec rm {} +")
      expect(decision).to be_abstain
      expect(decision.reason).to include("find")
    end

    it "keeps git on the list, because -c core.fsmonitor=id executes id" do
      expect(described_class::PROGRAM_RUNNERS).to include("git")
      expect(decide("git status --short")).to be_abstain
      expect(decide("git -c core.fsmonitor=id status --short")).to be_abstain
    end

    # The repro the card pins: structurally this command is indistinguishable
    # from `ls -la`, so nothing but the name list can catch it.
    it "has no structural signal at all on the fsmonitor repro" do
      result = parse.call("git -c core.fsmonitor=id status --short")
      expect(result).to be_covered
      expect(result).not_to be_broken
      expect(result.kinds - described_class::LITERAL_KINDS).to be_empty
    end

    it "carries every name the card lists" do
      expect(described_class::PROGRAM_RUNNERS).to include(
        "eval", "source", ".", "alias", "xargs", "sh", "bash", "env", "sudo", "find", "nice",
        "timeout", "nohup", "setsid", "stdbuf", "watch", "awk", "sed", "tar", "rsync", "less",
        "git", "time", "coproc"
      )
    end

    # A list of bare names that an absolute path walks around is not a check.
    it "reads the last path segment, so a path cannot walk around it" do
      ["/bin/sh -c id", "/usr/bin/env id", "./sh -c id"].each do |command|
        expect(decide(command)).to be_abstain, command
      end
    end

    # A synonym of a name already carried for a stated reason is not the
    # incompleteness the card licenses: `sh -c <model string>` is closed and
    # `dash -c <model string>` is the same door. Every one of these is on PATH
    # on the box this was measured on.
    it "carries the synonyms of the names it already carries" do
      {
        "a shell" => ["dash -c id", "zsh -c id", "ksh -c id", "busybox sh -c id", "rbash -c id"],
        "a privilege wrapper" => ["su -c id root", "runuser -u root id", "doas id", "pkexec id", "setpriv id"],
        "an interpreter" => ["perl -e print", "python3 -c pass", "ruby -e puts", "node -e x", "lua -e x"],
        "a runner" => ["strace -f rm x", "script -c id out", "systemd-run rm x", "npx rm", "ssh host rm -rf x"],
        "a nice-alike" => ["ionice rm x", "taskset 1 rm x", "flock f rm x", "chroot / rm x", "unshare rm x"],
        "a pager or editor" => ["vim file", "man ls", "ed file", "less file"]
      }.each do |family, commands|
        commands.each { |command| expect(decide(command)).to be_abstain, "#{family}: #{command}" }
      end
    end

    it "has no structural signal on the synonyms either, so only the name catches them" do
      ["dash -c id", "pkexec id", "python3 -c pass", "strace -f rm x"].each do |command|
        result = parse.call(command)
        expect(result).to be_covered, command
        expect(result).not_to be_broken, command
        expect(result.kinds - described_class::LITERAL_KINDS).to be_empty, command
      end
    end

    # Not programs at all: the string was a syntax error bash would have
    # rejected, so ENOENT is luck rather than a check, and "fully understood"
    # must not be claimed about it.
    it "abstains on a bash reserved word as the program" do
      ["do rm x", "done", "elif rm x", "else rm x", "esac", "fi", "in rm x", "then ls"].each do |command|
        expect(decide(command)).to be_abstain, command
      end
    end

    it "abstains on the builtins that dispatch a command" do
      ["command time rm x", "builtin time rm x", "exec rm x"].each do |command|
        expect(decide(command)).to be_abstain, command
      end
    end

    # `bundle exec <program>` names the program in the ARGUMENT, which is the
    # rule exactly -- the same shape as `env` and `nice`, both already listed.
    # It is the command this repo runs most, and it abstains anyway, because a
    # rule that exempts the convenient case is not a rule.
    it "abstains on bundle exec, the wrapper this repo lives on" do
      ["bundle exec rspec", "bundle exec id", "bundle exec rm -rf x"].each do |command|
        expect(decide(command)).to be_abstain, command
      end
    end

    # The other side of the boundary, kept where it is deliberately: what these
    # run comes from a build file in the workspace, which this layer does not
    # model. Pinned so that moving the line has to be a decision.
    it "allows the build wrappers whose program comes from a workspace file" do
      ["make all", "cargo test", "rake foo", "gradle run"].each do |command|
        expect(decide(command)).to be_allow, command
      end
    end

    # The known exceptions, pinned as they BEHAVE rather than as one would wish:
    # `make -f -` really does read a makefile from stdin and `make --eval=`
    # takes one inline, and both ALLOW today -- the algebra doc's pipe trap in
    # its literal form. What makes that tolerable is not this layer: a working
    # recipe needs a newline or quoting to carry its TAB-indented line, and both
    # of those abstain. That is a fact about today's tiers and not a guarantee,
    # which is exactly why the code names these two rather than claiming no flag
    # of make's can name a program.
    it "allows make's stdin and inline-recipe flags, which are the known exceptions" do
      expect(decide("printf x | make -f -")).to be_allow
      expect(decide("make --eval=x")).to be_allow
    end

    it "abstains as soon as one of those carries a recipe, which needs a newline or quoting" do
      ["printf 'all:\n\techo hi\n' | make -f -", "make --eval=$(cat evil)", "make -f -\nall:"]
        .each { |command| expect(decide(command)).to be_abstain, command.inspect }
    end
  end

  # tree-sitter-bash does not model `time` as a keyword, so a `time` prefix
  # degrades its whole tail to plain `word` nodes in an ordinary `command`:
  # not broken, fully covered, blandest possible kinds. NEITHER the kind tier
  # nor the coverage backstop says anything about these. The name list is the
  # only thing that makes them abstain -- which is why the brace-free case is
  # asserted alongside the brace one.
  describe "a literal command behind a program-runner prefix" do
    ["time { echo PWNED; }", "time rm -rf /tmp/x", "time if true; then ls; fi", "coproc rm x"].each do |command|
      it "abstains on #{command.inspect}, naming the prefix" do
        decision = decide(command)
        expect(decision).to be_abstain
        expect(decision.reason).to include(command.split.first)
      end
    end

    it "abstains on `time rm -rf /tmp/x`, which contains no brace at all" do
      command = "time rm -rf /tmp/x"
      result = parse.call(command)
      expect(result).not_to be_broken
      expect(result).to be_covered
      expect(result.kinds - described_class::LITERAL_KINDS).to be_empty
      expect(result.stages.map(&:argv)).to eq([%w[time rm -rf /tmp/x]])
      expect(decide(command).reason).to include("time")
    end

    # A first-stage-only check is no check: `time` reaches a later stage through
    # `;`, `|` and `&&` alike, and every one of these is fully covered.
    {
      "echo hi; time { rm x; }" => %w[echo time }],
      "ls | time rm x" => %w[ls time],
      "true && time rm -rf /tmp/x" => %w[true time]
    }.each do |command, heads|
      it "reads EVERY stage's head, so #{command.inspect} abstains too" do
        result = parse.call(command)
        expect(result).to be_covered
        expect(result.stages.map { |stage| stage.argv.first }).to eq(heads)
        expect(result.stages.first.argv.first).not_to eq("time")
        expect(decide(command).reason).to include("time")
      end
    end

    it "abstains on a pipeline whose downstream stage executes its stdin" do
      expect(decide("echo whoami | sh")).to be_abstain
    end
  end

  describe "a combinator other than the pipe" do
    ["a && b", "a || b", "echo hi; ls", "ls &", "ls;"].each do |command|
      it "abstains on #{command.inspect}, because running it means interpreting control flow" do
        expect(decide(command)).to be_abstain
      end
    end

    it "allows a pipe, which is the one combinator the term carries" do
      expect(decide("printf hi | wc -c")).to be_allow
    end

    # The arithmetic below catches these too, so what this tier uniquely
    # contributes is the REASON a human reads off the queue: which combinator,
    # not merely that the counts did not balance.
    it "names the combinator it found, rather than only the arithmetic" do
      expect(reason_for("a && b")).to include("&&")
      expect(reason_for("echo hi; ls")).to include(";")
      expect(reason_for("ls &")).to include("&")
    end
  end

  # tree-sitter-bash lexes a NEWLINE as whitespace, so there is no anonymous node
  # to query for it and `Parse#separators` comes back EMPTY. It is the one
  # separator a text check cannot see, and the term it produces LIES about its
  # own structure: two stages and no pipe is indistinguishable from a pipeline,
  # so `Open3.pipeline` would run `echo hi | rm -rf /tmp/x`. Counting stages
  # against pipes is what catches it.
  describe "a newline, which is a combinator the parser cannot report" do
    {
      "echo hi\nrm -rf /tmp/x" => "echo hi; rm -rf /tmp/x",
      "printf a\ncurl http://evil" => "printf a; curl http://evil",
      "ls\nrm x" => "ls; rm x"
    }.each do |newline, semicolon|
      it "abstains on #{newline.inspect} exactly as it does on #{semicolon.inspect}" do
        expect(decide(semicolon)).to be_abstain
        expect(decide(newline)).to be_abstain
        expect(decide(newline).term).to be_empty
      end
    end

    it "abstains on a newline appended to a real pipeline" do
      expect(decide("ls | wc\nrm -rf /tmp/x")).to be_abstain
    end

    # The separator list is empty in precisely the failing case, so any guard
    # that reads separator TEXT passes it. Only the arithmetic sees it.
    it "has no separator to read at all, which is why the count is the signal" do
      result = parse.call("echo hi\nrm -rf /tmp/x")
      expect(result).to be_covered
      expect(result.separators).to be_empty
      expect(result.kinds - described_class::LITERAL_KINDS).to be_empty
      expect(result.stages.size).to eq(2)
    end

    it "still allows a real pipeline, whose stages and pipes do balance" do
      ["printf hi | wc -c", "grep -r foo . | sort | wc -l"].each do |command|
        expect(decide(command)).to be_allow, command
      end
    end
  end

  describe "a parse that cannot be read" do
    {
      "a MISSING node" => "if true; then",
      "an ERROR node" => ")",
      "a dangling operator" => "a &&"
    }.each do |label, command|
      it "abstains on #{label}" do
        expect(parse.call(command)).to be_broken
        expect(decide(command)).to be_abstain
      end
    end

    it "abstains on incomplete byte coverage, even though the grammar reported no error" do
      expect(parse.call("myprog $")).not_to be_broken
      expect(parse.call("myprog $")).not_to be_covered
      expect(decide("myprog $")).to be_abstain
    end

    it "abstains on the corrupted-command_name grammar bug" do
      expect(decide("$FOO/$BAR/")).to be_abstain
    end

    # `\r`, `\f` and `\v` split words for tree-sitter and NOT for bash, which
    # splits on IFS only. The term therefore said four arguments where bash
    # passes one -- a misparse yielding a DIFFERENT VALID argv, which is closer
    # to attacker-chosen than to broken. Fixed in `Parse` (they are no longer
    # counted as blank) rather than as a tier here, so the existing `covered?`
    # discipline refuses them for free. No tier here could have seen it: the
    # byte sits BETWEEN terms, where neither the word text nor the arithmetic
    # over stages looks.
    ["rm tmp/build\f-rf\f/home/joel", "ls\frm x", "echo a\vb", "echo a\rb", "ls\vrm x"].each do |command|
      it "abstains on #{command.inspect}, a word bash would not split" do
        expect(decide(command)).to be_abstain
        expect(parse.call(command)).not_to be_covered
      end
    end

    # The boundary of that fix, so it is not mistaken for "any odd byte
    # abstains": NBSP, U+2028, U+0085, BEL and ESC stay INSIDE the word for the
    # grammar exactly as they do for bash, so the term agrees with what the
    # shell would pass and there is nothing to refuse.
    ["ls rm x", "ls rm x", "lsrm x", "ls\arm x", "ls\erm x"].each do |command|
      it "still allows #{command.inspect}, where the byte stays inside one word" do
        decision = decide(command)
        expect(decision).to be_allow
        expect(decision.term.first.first).to include(command[2])
      end
    end

    it "abstains over the length cap and on invalid encoding" do
      expect(decide("echo #{"a" * Lain::Shell::Parse::MAX_BYTES}")).to be_abstain
      expect(decide((+"echo \xff\xfe").force_encoding(Encoding::UTF_8))).to be_abstain
    end

    it "abstains rather than raising, for any argument at all" do
      [nil, 42, :ls, [], { a: 1 }].each do |argument|
        decision = nil
        expect { decision = verdict.call(argument) }.not_to raise_error
        expect(decision).to be_abstain, argument.inspect
      end
    end

    # A hostile STRING, which the non-String cases never exercised. A NUL parses
    # CLEAN into an ordinary word, reaches the argv, and `File.basename` raises
    # `ArgumentError` on it -- so the name check has to read the path segment
    # itself. `{"command":"ls  -la"}` is valid JSON and `Tool::Input` checks
    # shape, not bytes, so this arrives from an ordinary tool call.
    it "abstains rather than raising on a hostile String" do
      ["ls \0-la", "echo \0 hi", "\0", "echo hi | \0rm x", "\0 | ls", "ls \0", "\0sh -c id"].each do |command|
        decision = nil
        expect { decision = verdict.call(command) }.not_to raise_error, command.inspect
        expect(decision).to be_abstain, command.inspect
      end
    end

    it "abstains rather than raising when the capability set is consulted too" do
      excluding = described_class.new(capability_set: instance_double(described_class::AnyProgram, permits?: false))
      expect { excluding.call("ls \0-la") }.not_to raise_error
    end

    # `echo hi &&` reconstructs `[["echo", "hi"], [""]]` -- an argv whose element
    # is the empty string execs nothing, so it must never reach an allow.
    it "abstains when a stage's argv carries an empty term" do
      expect(parse.call("echo hi &&").stages.map(&:argv)).to eq([%w[echo hi], [""]])
      expect(decide("echo hi &&")).to be_abstain
      expect(decide("echo hi |")).to be_abstain
    end

    # Today every command that produces one is ALSO broken, so the guard above
    # is reached through a defect rather than through the shape it guards. This
    # builds the shape directly: a clean, covered parse whose argv carries an
    # empty term must still abstain, because `exec ""` is not a command and T17
    # is promised it can never be handed one.
    it "abstains on an empty term even from a parse that reported nothing wrong" do
      empty_term = Lain::Shell::Parse::Result.new(
        source: "echo", stages: [Lain::Shell::Parse::Stage.new(argv: ["echo", ""].freeze, byte_range: 0...4)].freeze,
        kinds: %w[command command_name program word].freeze, separators: [].freeze,
        uncovered: [].freeze, breakages: [].freeze
      )
      expect(empty_term).to be_covered
      clean = described_class.new(parse: instance_double(Lain::Shell::Parse, call: empty_term))
      expect(clean.call("echo")).to be_abstain
    end

    it "abstains on an empty command, so an allow term is never empty" do
      expect(decide("")).to be_abstain
      expect(decide("  ")).to be_abstain
    end
  end

  # `covered?` is a NECESSARY condition and never a sufficient one, and it is
  # the predicate to ask: the refusal path has no source, so its `uncovered`
  # field is `[]` while `covered?` is correctly false. A verdict that read the
  # field directly would allow a refusal.
  describe "the coverage predicate, not the coverage field" do
    let(:refusal) do
      Lain::Shell::Parse::Result.new(
        source: "", stages: [stage].freeze, kinds: %w[command command_name word].freeze,
        separators: [].freeze, uncovered: [].freeze, breakages: [breakage].freeze
      )
    end
    let(:stage) { Lain::Shell::Parse::Stage.new(argv: %w[ls].freeze, byte_range: 0...2) }
    let(:breakage) { Lain::Shell::Parse::Breakage.new(kind: :unparseable, detail: "RuntimeError: abi drift") }
    let(:verdict) { described_class.new(parse: instance_double(Lain::Shell::Parse, call: refusal)) }

    it "abstains on a result whose uncovered field is empty but whose covered? is false" do
      expect(refusal.uncovered).to be_empty
      expect(refusal).not_to be_covered
      expect(verdict.call("ls")).to be_abstain
    end

    it "reports the real refusal shape, so this is not a fabricated case" do
      real = Lain::Shell::Parse.new.call(nil)
      expect(real.uncovered).to be_empty
      expect(real).not_to be_covered
    end

    # `covered?` happens to be a conjunction over the breakages today, so a
    # verdict could ride on it and never ask `broken?` at all. That is a claim
    # about another object's internals; this asks both, and a Result that
    # answered `broken?` while claiming coverage would still abstain.
    it "asks broken? itself, rather than inferring it from covered?" do
      expect(judging(broken?: true, covered?: true, breakages: [breakage].freeze).call("ls")).to be_abstain
    end

    # The other half of the same discipline. This state is DELIBERATELY
    # unreachable -- no real Result can report `broken?` false, `covered?` false
    # and an empty `uncovered`, and that is the point: it pins "believe the
    # message, do not recompute it from the fields", which is the house rule
    # about depending on messages rather than on types. Its neighbour above does
    # the reachability work, showing the real refusal has exactly this shape.
    it "believes covered?, rather than recomputing it from the uncovered field" do
      expect(judging(broken?: false, covered?: false, uncovered: [].freeze).call("ls")).to be_abstain
    end

    def judging(**overrides)
      shape = { broken?: false, covered?: true, stages: [stage].freeze, kinds: %w[command command_name word].freeze,
                separators: [].freeze, uncovered: [].freeze, breakages: [].freeze }
      result = instance_double(Lain::Shell::Parse::Result, **shape, **overrides)
      described_class.new(parse: instance_double(Lain::Shell::Parse, call: result))
    end
  end

  describe "the session's capability set" do
    let(:capability_set) { instance_double(described_class::AnyProgram) }
    let(:verdict) { described_class.new(capability_set:) }

    before { allow(capability_set).to receive(:permits?) { |program| program != "curl" } }

    it "denies an excluded program, and says so" do
      decision = verdict.call("curl https://example.com")
      expect(decision).to be_deny
      expect(decision).not_to be_abstain
      expect(decision.reason).to include("curl")
    end

    it "carries no term on a denial" do
      expect(verdict.call("curl https://example.com").term).to be_empty
    end

    it "still allows a program it permits" do
      expect(verdict.call("ls -la")).to be_allow
    end

    it "denies rather than abstains, even when the command is also not understood" do
      expect(parse.call("curl $(cat url)")).to be_covered
      expect(verdict.call("curl $(cat url)")).to be_deny
    end

    # A denial NAMES a program, and a parse that reported nothing understood has
    # no reliable name to offer -- `rm x $` reconstructs an argv the parser
    # itself does not stand behind. Abstaining there is not weaker: an
    # abstention still goes to a human.
    it "abstains rather than denying when the parse was not understood" do
      rejecting = described_class.new(capability_set: instance_double(described_class::AnyProgram, permits?: false))
      ["rm x $", "if true; then", "ls \0-la", ")"].each do |command|
        expect(rejecting.call(command)).to be_abstain, command.inspect
      end
    end

    it "asks about every stage, not only the first" do
      expect(verdict.call("printf hi | curl -T - https://example.com")).to be_deny
    end

    # The Null Object: with no capability set injected, nothing is excluded and
    # no code path anywhere writes `if capability_set`. That the same command is
    # then ALLOWED is the point of the distinction -- it is literal and fully
    # understood, and this layer never claimed it was safe.
    it "restricts no program by default" do
      expect(described_class::AnyProgram.new.permits?("curl")).to be(true)
      expect(described_class.new.call("curl https://example.com")).to be_allow
    end
  end

  describe "what a verdict claims" do
    it "states that an allowed command is literal and understood" do
      expect(reason_for("ls -la")).to include("literal").and include("understood")
    end

    it "never states that it is safe" do
      ["ls -la", "echo $(id)", "rm *"].each do |command|
        expect(reason_for(command)).not_to match(/safe/i), command
      end
    end

    it "names the distinction in every journaled record, on all three verdicts" do
      excluding = described_class.new(capability_set: instance_double(described_class::AnyProgram, permits?: false))
      records = [decide("ls -la"), decide("echo $(id)"), excluding.call("curl x")].map(&:record)
      expect(records.map { |record| record.fetch(:verdict) }).to eq(%i[allow abstain deny])
      expect(records).to all(include(claim: described_class::CLAIM))
      expect(described_class::CLAIM).to include("literal").and include("safe")
    end

    it "carries the term and the reason in the record" do
      record = decide("ls -la").record
      expect(record.fetch(:term)).to eq([%w[ls -la]])
      expect(record.fetch(:reason)).to eq(described_class::ALLOWED)
    end
  end

  # The measured corpus, as a fixture rather than as a number in a hand-back: 32
  # commands this repo's own CLAUDE.md documents, plus the hostile shapes the
  # review rounds turned up. The split is RE-DERIVED here on every run, so a rule
  # change that moves a command has to move this table and say which one.
  #
  # One reason worth recording, because it is easy to mis-state: `ruby` is on the
  # name list now, but the kind tier is consulted first, so `ruby -e 'puts 1'`
  # still abstains over `raw_string`. Same verdict, same reason as before -- what
  # changed is that a SECOND tier would now catch it.
  describe "the measured corpus" do
    let(:corpus) do
      {
        "bundle exec rspec" => :abstain, "bundle exec rubocop -a" => :abstain,
        "bundle exec rake compile" => :abstain, "git status --short" => :abstain,
        "git diff --stat" => :abstain, "ls -la" => :allow, "cat README.md" => :allow,
        "rm -rf tmp/build" => :allow, "mkdir -p tmp/x" => :allow, "grep -rn foo lib" => :allow,
        "grep -r foo . | wc -l" => :allow, "head -20 file" => :allow, "wc -l lib/lain.rb" => :allow,
        "cargo test" => :allow, "cargo clippy --all-targets -- -D warnings" => :allow,
        "ruby -e 'puts 1'" => :abstain, "pre-commit run --all-files" => :allow, "echo hi" => :allow,
        "printf hi" => :allow, "sort -u" => :allow, "find . -name '*.rb'" => :abstain,
        "ls *.rb" => :abstain, "cat ~/.gitconfig" => :abstain, "echo $(id)" => :abstain,
        "echo $HOME" => :abstain, "FOO=1 ls" => :abstain, "ls > out" => :abstain,
        "make && make install" => :abstain, "cd /tmp; ls" => :abstain, "sleep 1 &" => :abstain,
        "time rm -rf /tmp/x" => :abstain, "time { echo PWNED; }" => :abstain
      }
    end

    it "verdicts every one of the 32 as measured" do
      expect(corpus.size).to eq(32)
      expect(corpus.keys.to_h { |command| [command, decide(command).name] }).to eq(corpus)
    end

    it "splits 14 allow to 18 abstain" do
      expect(corpus.values.tally).to eq({ allow: 14, abstain: 18 })
    end

    it "denies nothing, because the default capability set excludes nothing" do
      expect(corpus.keys.map { |command| decide(command).name }).not_to include(:deny)
    end
  end

  describe "the decision value" do
    ["ls -la", "echo $(id)", "if true; then", "", nil].each do |command|
      it "is deeply frozen after #{command.inspect}" do
        expect(verdict.call(command)).to be_deeply_frozen
      end
    end

    it "is frozen after a denial" do
      excluding = described_class.new(capability_set: instance_double(described_class::AnyProgram, permits?: false))
      expect(excluding.call("curl x")).to be_deeply_frozen
    end

    it "is itself frozen, so one verdict is safe to share" do
      expect(verdict).to be_frozen
    end
  end

  # What T17 may rely on: an allowed term is a non-empty list of non-empty
  # argvs, joined by the pipe and nothing else. Open3 raises on an empty argv,
  # so this is the property that keeps a term runnable.
  describe "the term an allow hands over" do
    let(:corpus) do
      [
        "ls -la", "printf hi", "grep -r foo . | wc -l", "echo $(id)", "rm *", "ls ~/secret",
        "find . -exec rm {} +", "time { echo PWNED; }", "time rm -rf /tmp/x", "git status",
        "FOO=$(id)", "cat < $(id)", "FOO=1", "> out", "f() { ls; }", "(cd /tmp && ls)",
        "time { echo a; } | wc", "! ls", "", "cat <<EOF\nhi\nEOF", "echo a >b c", "$FOO/$BAR/",
        "ls &", "a && b", "echo hi; ls", "echo 'a b'", "/bin/sh -c id", nil, 42,
        "echo hi\nrm -rf /tmp/x", "ls | wc\nrm -rf /tmp/x", "ls\n\n", "echo hi &&", "echo hi |",
        "echo foo\\ bar", "dash -c id", "ls \0-la", "printf a\ncurl http://evil", "then ls"
      ]
    end

    it "is empty on every verdict that is not an allow" do
      corpus.reject { |command| verdict.call(command).allow? }
            .each { |command| expect(verdict.call(command).term).to be_empty, command.inspect }
    end

    it "is a non-empty list of non-empty argvs, none of them an empty term, on every allow" do
      corpus.map { |command| verdict.call(command) }.select(&:allow?).each do |decision|
        expect(decision.term).not_to be_empty
        expect(decision.term).to all(satisfy { |argv| !argv.empty? && argv.none?(&:empty?) })
      end
    end

    # Asked as arithmetic, not as separator text. A guard that reads the
    # separators passes the newline case, because there the separator list is
    # empty -- which is the whole reason the newline case existed.
    it "never allows a term whose stages are joined by anything but N-1 pipes" do
      corpus.select { |command| verdict.call(command).allow? }.each do |command|
        result = parse.call(command)
        pipes = result.separators.count { |separator| separator.text == "|" }
        expect(result.stages.size).to eq(pipes + 1), command.inspect
        expect(result.separators.size).to eq(pipes), command.inspect
      end
    end

    it "abstains on every one of the sequencing forms in the corpus" do
      ["echo hi\nrm -rf /tmp/x", "ls | wc\nrm -rf /tmp/x", "echo hi; ls", "a && b", "ls &"]
        .each { |command| expect(verdict.call(command)).to be_abstain, command.inspect }
    end
  end
end
