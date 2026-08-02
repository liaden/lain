# frozen_string_literal: true

require "shellwords"

RSpec.describe Lain::Shell::Parse do
  subject(:parse) { described_class.new }

  def result_for(command) = parse.call(command)

  describe "a clean literal command" do
    let(:result) { result_for("git status --short") }

    it "reconstructs its argv" do
      expect(result.stages.map(&:argv)).to eq([%w[git status --short]])
    end

    it "reports nothing broken" do
      expect(result).not_to be_broken
      expect(result.breakages).to be_empty
    end

    it "accounts for every non-whitespace byte" do
      expect(result).to be_covered
      expect(result.uncovered).to be_empty
    end
  end

  describe "a pipeline" do
    let(:result) { result_for("grep -r foo . | wc -l") }

    it "reports its stages in source order" do
      expect(result.stages.map(&:argv)).to eq([%w[grep -r foo .], %w[wc -l]])
    end

    it "orders the stages by their byte ranges" do
      expect(result.stages.map { |stage| stage.byte_range.begin }).to eq([0, 16])
    end

    it "reports the pipe as a separator it understands, so the byte is covered" do
      expect(result.separators.map(&:text)).to eq(["|"])
      expect(result).to be_covered
    end
  end

  describe "an incomplete command" do
    let(:result) { result_for("if true; then") }

    it "is reported broken" do
      expect(result).to be_broken
    end

    # The specific signal, not merely a falsy answer: tree-sitter reports a
    # zero-width MISSING node here and NO ERROR node, which is exactly the case
    # `has_error()` alone lets through.
    it "names a MISSING node, and no ERROR node" do
      expect(result.breakages.map(&:kind)).to eq([:missing_node])
    end

    it "sees a MISSING node where the raw query does" do
      raw = Lain::Ext::TreeSitter.query("if true; then", "bash", "[(ERROR) @error (MISSING) @missing]")
      expect(raw.map { |capture| capture.fetch("name") }).to eq(["missing"])
    end
  end

  describe "a dangling operator" do
    let(:result) { result_for("a &&") }

    it "is reported broken by a MISSING node, not an ERROR node" do
      expect(result).to be_broken
      expect(result.breakages.map(&:kind)).to eq([:missing_node])
    end
  end

  describe "a genuinely malformed command" do
    let(:result) { result_for(")") }

    it "is reported broken by an ERROR node" do
      expect(result.breakages.map(&:kind)).to eq([:error_node])
    end
  end

  describe "a bare dollar" do
    let(:result) { result_for("myprog $") }

    it "is not reported broken -- the grammar accepts it" do
      expect(result).not_to be_broken
    end

    # The dollar is an anonymous token, so no named node covers it. Naming the
    # exact byte is what proves the coverage check ran, rather than something
    # unrelated returning false.
    it "reports the dollar's byte as uncovered" do
      expect(result).not_to be_covered
      expect(result.uncovered).to eq([7...8])
      expect(result.source.byteslice(7, 1)).to eq("$")
    end
  end

  # The grammar splits words on `\r`, `\f` and `\v`; bash does not, because they
  # are not in its default IFS. Counting them as blank therefore reconstructed a
  # DIFFERENT VALID argv rather than a broken one -- `rm tmp/build\f-rf\f/home`
  # came back as four terms where bash passes ONE. Reporting them as uncovered is
  # what keeps the two readings from silently disagreeing.
  describe "a whitespace byte bash does not split on" do
    { "\r" => "carriage return", "\f" => "form feed", "\v" => "vertical tab" }.each do |byte, name|
      it "reports the #{name} as uncovered, since only IFS separates words" do
        result = result_for("echo a#{byte}b")
        expect(result).not_to be_broken
        expect(result).not_to be_covered
        expect(result.uncovered).to eq([6...7])
        expect(result.source.byteslice(6, 1)).to eq(byte)
      end
    end

    # bash passes this as ONE argument, `tmp/build\f-rf\f/home/joel`. Note that
    # `Shellwords` is NOT the oracle here -- it splits on Ruby's `\s`, so it
    # agrees with tree-sitter and not with the shell.
    it "reports the argument-splitting case, where the two readings disagree outright" do
      result = result_for("rm tmp/build\f-rf\f/home/joel")
      expect(result).not_to be_covered
      expect(result.stages.map(&:argv)).to eq([["rm", "tmp/build", "-rf", "/home/joel"]])
      expect(result.uncovered.size).to eq(2)
    end

    it "keeps the IFS bytes blank, so an ordinary command still covers" do
      expect(result_for("echo\ta \nb")).to be_covered
    end
  end

  # tree-sitter-bash#315: `$FOO/$BAR/` yields a corrupted `command_name`
  # ("$FOO/$") with ZERO ERROR and ZERO MISSING nodes. Byte coverage is the only
  # thing that catches it, which is why no container kind may count as coverage.
  describe "the corrupted-command_name grammar bug" do
    let(:result) { result_for("$FOO/$BAR/") }

    it "is not reported broken, because the grammar reports no error at all" do
      expect(result).not_to be_broken
    end

    it "still reports the swallowed dollar as uncovered" do
      expect(result).not_to be_covered
      expect(result.uncovered).to eq([5...6])
      expect(result.source.byteslice(5, 1)).to eq("$")
    end
  end

  describe "a numeric argument" do
    let(:result) { result_for("head -20 file") }

    it "is not silently dropped, even though it is a `number` node and not a `word`" do
      expect(result.stages.map(&:argv)).to eq([%w[head -20 file]])
    end

    it "is covered" do
      expect(result).to be_covered
    end
  end

  describe "the length cap" do
    let(:command) { "echo #{"a" * described_class::MAX_BYTES}" }
    let(:result) { result_for(command) }

    it "refuses rather than truncates" do
      expect(command.bytesize).to be > described_class::MAX_BYTES
      expect(result.breakages.map(&:kind)).to eq([:too_long])
    end

    it "issues no query at all" do
      allow(Lain::Ext::TreeSitter).to receive(:query).and_call_original
      result
      expect(Lain::Ext::TreeSitter).not_to have_received(:query)
    end

    it "claims no coverage, since nothing was parsed" do
      expect(result).not_to be_covered
      expect(result.stages).to be_empty
    end

    # The byte facts, not just the predicate: a refusal reports the WHOLE command
    # as unaccounted for, so `uncovered` stays honest even read on its own.
    it "reports every byte as unaccounted for" do
      expect(result.uncovered).to eq([0...command.bytesize])
    end

    it "accepts a command exactly at the cap" do
      exact = "echo #{"a" * (described_class::MAX_BYTES - 5)}"
      expect(exact.bytesize).to eq(described_class::MAX_BYTES)
      expect(result_for(exact)).not_to be_broken
    end
  end

  describe "invalid encoding" do
    let(:command) { (+"echo \xff\xfe").force_encoding(Encoding::UTF_8) }
    let(:result) { result_for(command) }

    it "is reported broken rather than raising" do
      expect { result }.not_to raise_error
      expect(result).to be_broken
    end

    it "names the encoding, and does not claim coverage" do
      expect(result.breakages.map(&:kind)).to eq([:unparseable])
      expect(result).not_to be_covered
    end

    # A parse that got as far as the query keeps the command it was given, so a
    # journal line can still say WHAT was refused. Only an argument that was
    # never usable as a source loses it.
    it "keeps the source it was handed" do
      expect(result.source).to eq(command)
      expect(result.uncovered).to eq([0...command.bytesize])
    end

    # A raise escaping this object becomes an agent-visible crash, so anything
    # the ext throws -- anticipated or not -- has to land as a breakage.
    it "reports an unanticipated ext failure as broken too" do
      allow(Lain::Ext::TreeSitter).to receive(:query).and_raise(RuntimeError, "abi drift")
      broken = result_for("ls")
      expect(broken.breakages.map(&:kind)).to eq([:unparseable])
      expect(broken).not_to be_covered
    end
  end

  # `#dup` and `#bytesize` are messages a non-String does not answer, and they
  # run before the query does -- so the rescue has to sit outside them too.
  describe "an argument that is not a String" do
    [nil, 42, :ls, [], { a: 1 }].each do |argument|
      it "refuses #{argument.inspect} rather than raising" do
        result = nil
        expect { result = parse.call(argument) }.not_to raise_error
        expect(result.breakages.map(&:kind)).to eq([:unparseable])
        expect(result).not_to be_covered
        expect(result.stages).to be_empty
      end
    end

    # The one path where `uncovered` alone lies: there is no source, so there
    # are no bytes to report, and `uncovered.empty?` reads as "all accounted
    # for". `covered?` is the question to ask -- it consults the breakages.
    it "reports an EMPTY uncovered, which is why covered? is the predicate to trust" do
      result = parse.call(nil)
      expect(result.source).to eq("")
      expect(result.uncovered).to be_empty
      expect(result).not_to be_covered
    end
  end

  # Honest for a mechanism -- the grammar really does lex it as an ordinary word
  # -- and a hazard for whoever execs the result, since exec refuses a NUL.
  describe "a NUL byte" do
    it "parses clean into an ordinary argv term" do
      result = result_for("echo a\0b")
      expect(result).not_to be_broken
      expect(result).to be_covered
      expect(result.stages.map(&:argv)).to eq([["echo", "a\0b"]])
    end
  end

  describe "structural node kinds" do
    it "reports command substitution by kind, and covers its bytes" do
      result = result_for("echo $(id)")
      expect(result.kinds).to include("command_substitution")
      expect(result).to be_covered
    end

    it "reconstructs the substitution as ONE term, not its inner words" do
      expect(result_for("echo $(id)").stages.map(&:argv)).to eq([["echo", "$(id)"]])
    end

    it "reports expansion, redirection and assignment by kind" do
      expect(result_for("echo ${FOO}").kinds).to include("expansion")
      expect(result_for("cat < f").kinds).to include("file_redirect")
      expect(result_for("FOO=1 ls").kinds).to include("variable_assignment")
      expect(result_for("diff <(a) <(b)").kinds).to include("process_substitution")
    end

    it "reports the plain kinds a literal command is made of" do
      expect(result_for("ls -la").kinds).to include("command", "command_name", "word")
    end
  end

  # These keywords are anonymous tokens WHEN THEY LEAD, so a compound statement
  # written plainly cannot reach full coverage. That is the whole of the claim --
  # it is not a guarantee that compound syntax can never hide, and the kind
  # allowlist is NOT total. See `describe "the coverage signal's limit"` below:
  # a leading word the grammar does not model as a keyword degrades its tail to
  # ordinary `word` nodes, and `time if true; then ls; fi` is fully covered.
  describe "compound syntax, written plainly" do
    {
      "if true; then ls; fi" => "if",
      "while true; do ls; done" => "while",
      "for f in a b; do echo x; done" => "for",
      "f() { ls; }" => "(",
      "(cd /tmp && ls)" => "(",
      "! ls" => "!"
    }.each do |command, keyword|
      it "leaves #{keyword.inspect} of #{command.inspect} uncovered" do
        result = result_for(command)
        expect(result).not_to be_covered
        uncovered_text = result.uncovered.map { |span| result.source.byteslice(span.begin, span.size) }
        expect(uncovered_text.join).to include(keyword)
      end
    end
  end

  # What the argv IS and is NOT, pinned so the object that runs it cannot be
  # surprised. Reconstruction is faithful to the tree, not to a shell: it does
  # the word splitting a shell does, and none of the interpretation.
  describe "argv reconstruction" do
    it "joins a concatenation into one term, as a shell passes it" do
      expect(result_for("find . -exec rm {} +").stages.map(&:argv))
        .to eq([["find", ".", "-exec", "rm", "{}", "+"]])
    end

    it "joins mixed quoting into one term rather than three" do
      expect(result_for(%(echo a"b"c)).stages.map(&:argv)).to eq([["echo", %(a"b"c)]])
    end

    it "does NOT strip quotes -- the term carries them exactly as written" do
      expect(result_for("echo 'a b'").stages.map(&:argv)).to eq([["echo", "'a b'"]])
      expect(result_for(%(echo "a b")).stages.map(&:argv)).to eq([["echo", %("a b")]])
    end

    # A redirection is a term when the command node encloses it and is dropped
    # when it does not -- and in the dropping case an ordinary WORD goes with it.
    # No reading of the argv alone recovers that; `kinds` is the only tell.
    it "keeps a leading redirection as a term" do
      result = result_for("> out echo hi")
      expect(result.stages.map(&:argv)).to eq([["> out", "echo", "hi"]])
      expect(result.kinds).to include("file_redirect")
    end

    it "silently drops the word after a trailing redirection" do
      result = result_for("echo a >b c")
      expect(result.stages.map(&:argv)).to eq([%w[echo a]])
      expect(result.kinds).to include("file_redirect", "redirected_statement")
    end

    it "drops both sides of a surrounding redirection" do
      result = result_for("cat < in > out")
      expect(result.stages.map(&:argv)).to eq([["cat"]])
      expect(result.kinds).to include("file_redirect")
    end

    # An empty argv is an ArgumentError in Open3, so it must not be reachable:
    # the `id` of `FOO=$(id)` is a command node nested in a terminal, which makes
    # it that terminal's innards rather than a stage of this command line.
    describe "a command swallowed by a terminal" do
      it "is not reported as a stage with an empty argv" do
        expect(result_for("FOO=$(id)").stages).to be_empty
        expect(result_for("cat < $(id)").stages.map(&:argv)).to eq([["cat"]])
      end

      it "still reports the kinds that say what happened" do
        expect(result_for("FOO=$(id)").kinds).to include("command_substitution", "variable_assignment")
      end
    end

    it "never yields an empty argv, across a hostile corpus" do
      [
        "FOO=$(id)", "cat < $(id)", "FOO=1", "echo $(id)", "diff <(a) <(b)",
        "echo ${FOO:-$(id)}", "echo $((1+1))", "cat <<EOF\nhi\nEOF", "> out",
        "f() { ls; }", "(cd /tmp && ls)", "time { echo a; } | wc", "! ls", ""
      ].each do |command|
        argvs = result_for(command).stages.map(&:argv)
        expect(argvs).to all(satisfy { |argv| !argv.empty? }), "#{command.inspect} gave #{argvs.inspect}"
      end
    end

    it "matches Shellwords on the plain literal commands, where both apply" do
      ["git status --short", "ls -la", "head -20 file", "bundle exec rspec", "rm -rf tmp/build"].each do |command|
        expect(result_for(command).stages.map(&:argv)).to eq([Shellwords.split(command)]), command
      end
    end
  end

  # tree-sitter's own docs state that an `(ERROR)` query does not match MISSING
  # nodes, and `has_error()` alone was already measured letting `")"`, `"def"`,
  # `"1 +"` and `"[1,"` through as silent zero-matches. Both node types, one
  # query -- pinned here so a simplification has to break a spec.
  describe "the query" do
    it "asks for ERROR and MISSING together" do
      expect(described_class::QUERY).to include("(ERROR)").and include("(MISSING)")
    end

    it "binds one capture per reported kind, so a capture name IS the node kind" do
      described_class::KINDS.each { |kind| expect(described_class::QUERY).to include("(#{kind}) @#{kind}") }
    end
  end

  # The limit of the coverage signal, pinned so nobody re-derives a guarantee
  # from the code's silence. tree-sitter-bash does not model `time` as a keyword,
  # so a leading word the grammar does not know degrades its whole tail to plain
  # `word` nodes in an ordinary `command` -- full coverage, no breakage, and the
  # blandest kind set the grammar can produce. `time { echo PWNED; }` is the
  # command the plan singled out, and this object carries NO signal for it. The
  # answer is a name denylist one layer up, not a heuristic in here.
  describe "the coverage signal's limit -- a leading word the grammar does not model" do
    {
      "time { echo PWNED; }" => [["time", "{", "echo", "PWNED"], ["}"]],
      "time rm -rf /tmp/x" => [%w[time rm -rf /tmp/x]],
      "time if true; then ls; fi" => [%w[time if true], %w[then ls], %w[fi]]
    }.each do |command, argv|
      it "reports #{command.inspect} as neither broken nor uncovered" do
        result = result_for(command)
        expect(result).not_to be_broken
        expect(result).to be_covered
        expect(result.stages.map(&:argv)).to eq(argv)
      end

      it "reports only the blandest kinds for #{command.inspect}, so a kind allowlist cannot catch it" do
        expect(result_for(command).kinds - %w[program list pipeline command command_name word]).to be_empty
      end
    end

    it "catches a subshell only because its parentheses are still anonymous" do
      expect(result_for("time (echo hi)")).not_to be_covered
    end

    # `time` is not special; it is one of twelve reserved words that reach a
    # clean report as a leading token. `coproc` is the other one that matters,
    # because bash really does run its argument -- benign here only because no
    # `coproc` binary exists, unlike `/usr/bin/time`.
    it "reports the same clean result for every reserved word that leads" do
      ["}", "coproc", "do", "done", "elif", "else", "esac", "fi", "in", "then", "time", "]]"].each do |word|
        result = result_for("#{word} rm x")
        expect(result).not_to be_broken, word
        expect(result).to be_covered, word
      end
    end

    # The check a verdict builds on top of this MUST read every stage's head.
    # `time` reaches a later stage through `;`, `|` and `&&` alike, and reading
    # only `stages.first` misses all three.
    {
      "echo hi; time { rm x; }" => %w[echo time }],
      "ls | time rm x" => %w[ls time],
      "true && time rm -rf /tmp/x" => %w[true time]
    }.each do |command, heads|
      it "puts `time` in a NON-leading stage for #{command.inspect}" do
        result = result_for(command)
        expect(result).to be_covered
        expect(result.stages.map { |stage| stage.argv.first }).to eq(heads)
        expect(result.stages.first.argv.first).not_to eq("time")
      end
    end
  end

  describe "the reported kinds" do
    it "never leak the parser's own bookkeeping captures" do
      kinds = result_for("ls | wc; if true; then ls; fi").kinds
      expect(kinds).not_to include("error", "missing", "separator")
      expect(kinds - described_class::KINDS).to be_empty
    end
  end

  describe "the reported separators" do
    it "collects every operator it understands, in source order" do
      expect(result_for("a && b || c; d & e | f").separators.map(&:text)).to eq(["&&", "||", ";", "&", "|"])
    end

    # Counting cannot tell a caller which stage is downstream of a pipe: `ls &`
    # is one stage and one separator, and `time { echo a; } | wc` is THREE stages
    # against `[";", "|"]`. Only the byte ranges order the two lists.
    it "carries a byte range, so a caller can interleave them with the stages" do
      result = result_for("time { echo a; } | wc")
      expect(result.stages.size).to eq(3)
      expect(result.separators.map(&:text)).to eq([";", "|"])
      expect(result.separators.map { |sep| result.source.byteslice(sep.byte_range.begin, sep.byte_range.size) })
        .to eq([";", "|"])
    end

    it "places the pipe between the stages it joins" do
      result = result_for("grep foo . | wc -l")
      pipe = result.separators.first.byte_range.begin
      expect(result.stages.first.byte_range.end).to be <= pipe
      expect(result.stages.last.byte_range.begin).to be >= pipe
    end
  end

  describe "the result value" do
    # Every path, not just the two that used to be asserted -- the over-cap
    # Breakage is a shared CONSTANT, so an unfrozen detail on it is one `<<`
    # away from poisoning every later parse in the process.
    {
      "a clean parse" => "git status --short",
      "a MISSING node" => "if true; then",
      "an ERROR node" => ")",
      "incomplete coverage" => "myprog $",
      "an unparseable command" => (+"echo \xff\xfe").force_encoding(Encoding::UTF_8),
      "a non-String argument" => nil
    }.each do |label, command|
      it "is deeply frozen after #{label}" do
        expect(Ractor.shareable?(parse.call(command))).to be(true)
      end
    end

    it "is deeply frozen after an over-cap refusal" do
      expect(Ractor.shareable?(result_for("echo #{"a" * described_class::MAX_BYTES}"))).to be(true)
    end

    it "freezes every breakage detail, including the shared over-cap constant" do
      expect(described_class::TOO_LONG.detail).to be_frozen
      ["if true; then", ")", "echo #{"a" * described_class::MAX_BYTES}"].each do |command|
        expect(result_for(command).breakages.map(&:detail)).to all(be_frozen)
      end
    end
  end

  describe "an empty command" do
    it "is not broken and has no stages" do
      result = result_for("")
      expect(result).not_to be_broken
      expect(result).to be_covered
      expect(result.stages).to be_empty
    end
  end
end
