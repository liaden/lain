# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::FileSymbols do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  it "lists module/class/method definitions with roles and lines, plus references" do
    path = write("shapes.rb", <<~RUBY)
      module Geometry
        # class NotReal
        class Circle
          def area
            compute("class AlsoNotReal")
          end
        end
      end
    RUBY

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    content = result.content
    expect(content).to include("DEFINITIONS")
    expect(content).to match(/namespace\s+Geometry/)
    expect(content).to match(/class\s+Circle/)
    expect(content).to match(/method\s+area/)
    expect(content).to include("REFERENCES")
    expect(content).to match(/call\s+compute/)
    # Structural, not textual: a name only in a comment or string is never listed.
    expect(content).not_to include("NotReal")
    expect(content).not_to include("AlsoNotReal")
    # Lines are 1-based and reported.
    expect(content).to match(/L1\b.*Geometry/)
  end

  it "supports rust: a fn and a struct as definitions, a call as a reference (owner priority)" do
    path = write("geo.rs", <<~RUST)
      struct Point { x: i32 }

      fn origin() -> Point {
          make_point()
      }
    RUST

    result = tool.call(path:, language: "rust")

    expect(result.ok?).to be(true)
    content = result.content
    expect(content).to match(/class\s+Point/)
    expect(content).to match(/function\s+origin/)
    expect(content).to match(/call\s+make_point/)
  end

  it "supports typescript" do
    path = write("widget.ts", <<~TS)
      class Widget {
        render() { return build(); }
      }
    TS

    result = tool.call(path:, language: "typescript")

    expect(result.ok?).to be(true)
    expect(result.content).to match(/class\s+Widget/)
    expect(result.content).to match(/method\s+render/)
    expect(result.content).to match(/call\s+build/)
  end

  it "returns an error Result naming python as unsupported (python is deferred)" do
    path = write("thing.py", "def f():\n    pass\n")

    result = tool.call(path:, language: "python")

    expect(result).to have_attributes(is_error: true, content: /python/)
  end

  # lain ships a markdown query, but a SECTIONS query -- so the symbols tool
  # must still refuse markdown as a user error naming the language, not as the
  # packaging bug Missing reports. A flat language allowlist could not say this.
  it "returns an error Result naming markdown as unsupported, not a packaging bug" do
    path = write("readme.md", "# Title\n\nbody\n")

    result = tool.call(path:, language: "markdown")

    expect(result).to have_attributes(is_error: true, content: /markdown/)
    expect(result.content).not_to include("missing")
  end

  it "reports a missing file as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope.rb")

    result = tool.call(path: missing, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: "no such file: #{missing}")
  end

  it "reports a directory as an error Result rather than raising" do
    result = tool.call(path: tmpdir, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: "is a directory, not a file: #{tmpdir}")
  end

  it "reports an unreadable file as an error Result rather than raising" do
    path = write("secret.rb", "class A; end")
    File.chmod(0o000, path)

    result = tool.call(path:, language: "ruby")

    expect(result).to have_attributes(is_error: true, content: "file is not readable: #{path}")
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  it "returns an ok result for a file with no symbols" do
    path = write("empty.rb", "x = 1\ny = 2\n")

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    expect(result.content).to be_a(String)
  end

  # The ext refuses a source whose bytes are not valid UTF-8 rather than
  # transcoding it (ext/lain/src/read_text.rs), because the byte offsets this
  # tool turns into line numbers would otherwise index a copy the caller never
  # sees. The tool's job is to turn that into an error Result the model can act
  # on, not to let an EncodingError escape #call.
  describe "a source file whose bytes are not valid UTF-8" do
    it "reports the encoding problem as an error Result naming the file" do
      path = File.join(tmpdir, "bad.rb")
      File.binwrite(path, "# caf\xe9 \xff\xfe\nclass Thing\nend\n")

      result = tool.call(path:, language: "ruby")

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include(path).and include("not valid UTF-8")
    end

    # The refusal above is only useful if it is TRUE. A bare File.read tags its
    # result with Encoding.default_external, which a C locale makes US-ASCII --
    # so under `LC_ALL=C` every ordinary UTF-8 source file would be refused with
    # a message saying it is not UTF-8, which it is. A model given that has no
    # move. This pins the mechanism (the read names its encoding) rather than
    # the locale, which is the part the tool actually controls.
    it "reads an ordinary UTF-8 file even when the default external encoding is US-ASCII" do
      path = write("accented.rb", "# a café comment\nclass Thing\nend\n")
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      begin
        result = tool.call(path:, language: "ruby")
      ensure
        Encoding.default_external = previous
      end

      expect(result).to have_attributes(ok?: true)
      expect(result.content).to match(/class\s+Thing/)
    end
  end

  describe "resolving paths against the session WorkerEnv" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    def session_at(cwd)
      Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: ENV.to_h))
    end

    it "resolves a relative path under the injected WorkerEnv cwd" do
      write("thing.rb", "class Thing\nend\n")

      result = tool.call({ path: "thing.rb", language: "ruby" }, invocation_with(session_at(tmpdir)))

      expect(result.ok?).to be(true)
      expect(result.content).to match(/class\s+Thing/)
    end

    it "honors an absolute path as given, whatever the WorkerEnv cwd" do
      path = write("thing.rb", "class Thing\nend\n")

      Dir.mktmpdir do |elsewhere|
        result = tool.call({ path:, language: "ruby" }, invocation_with(session_at(elsewhere)))

        expect(result.ok?).to be(true)
        expect(result.content).to match(/class\s+Thing/)
      end
    end

    it "resolves a relative path against the process cwd under the default WorkerEnv" do
      write("thing.rb", "class Thing\nend\n")

      Dir.chdir(tmpdir) do
        result = tool.call({ path: "thing.rb", language: "ruby" }, invocation_with(Lain::Session.new))

        expect(result.ok?).to be(true)
        expect(result.content).to match(/class\s+Thing/)
      end
    end

    # An ERROR names the RESOLVED path: "where did it actually look" is the
    # whole content of that message, and under a worktree-isolated worker the
    # given spelling does not answer it. An exact string, because a loose
    # /no such file/ passes against either spelling -- which is exactly how
    # this could drift back.
    it "names the resolved path in an error Result" do
      result = tool.call({ path: "nope.rb", language: "ruby" }, invocation_with(session_at(tmpdir)))

      expect(result).to have_attributes(is_error: true, content: "no such file: #{tmpdir}/nope.rb")
    end
  end

  # A symbol table is an ENUMERATION under {Lain::Tool::Bounds}' stated
  # boundary, and it is the only one of the six with TWO of them: definitions
  # and references are separate sections with separate true counts, so they
  # carry separate bounds. Capping the occurrences before the partition would
  # let a definition-heavy file consume the whole budget and return an empty
  # REFERENCES section -- a partial answer that reads like a complete one,
  # which is the failure the boundary exists to prevent.
  describe "the enumeration bounds" do
    let(:definitions) { described_class::DEFINITIONS_BOUND }
    let(:references) { described_class::REFERENCES_BOUND }
    let(:overflow) { 5 }

    # One method per call site, so a single fixture overflows BOTH sections and
    # the two caps are observed against the same run.
    def many_methods(count)
      write("many.rb", Array.new(count) { |i| "def m#{format("%05d", i)}\n  c#{format("%05d", i)}()\nend\n" }.join)
    end

    def sections_for(total)
      tool.call(path: many_methods(total), language: "ruby").content.split("\n\n")
    end

    it "caps each section against its own bound and discloses both true counts in band" do
      total = references.limit + overflow

      definitions_section, references_section = sections_for(total)

      expect(definitions_section.lines.map(&:chomp).last)
        .to eq("... capped at #{definitions.limit} of #{total} definitions")
      expect(references_section.lines.map(&:chomp).last)
        .to eq("... capped at #{references.limit} of #{total} references")
    end

    it "keeps both sections present when only one of them overflows" do
      total = definitions.limit + overflow

      definitions_section, references_section = sections_for(total)

      expect(definitions_section).to include("... capped at #{definitions.limit} of #{total} definitions")
      expect(references_section).to start_with("REFERENCES")
      expect(references_section).not_to include("capped at")
      expect(references_section.lines.length).to eq(total + 1)
    end

    it "caps after the by-line ordering, so the survivors are the first symbols in the file" do
      definitions_section, = sections_for(definitions.limit + overflow)

      rows = definitions_section.lines.map(&:chomp)
      expect(rows[1]).to eq("  L1  method  m00000")
      expect(rows[definitions.limit]).to eq("  L#{(3 * definitions.limit) - 2}  method  " \
                                            "m#{format("%05d", definitions.limit - 1)}")
    end

    # The same instability {Lain::Tools::CodeOutline}'s tie example pins, on the
    # tool where ties are the COMMON case rather than the odd one: several
    # references share a line whenever a method chains calls. `sort_by` is not
    # stable in CRuby, so under a cap an unstable tie decides which occurrences
    # exist at all.
    #
    # Recorded honestly: unlike the outline's, these two fixtures came out in
    # source order BEFORE the tiebreak as well, so they went green in the red
    # run -- and a review sweep of 23,988 collections (12 tie widths x 1999 line
    # counts, up to 24,000 rows) found ZERO flips. That is structural, not a
    # fixture nobody looked hard enough for: `ruby_qsort` leaves an
    # already-ordered partition undisturbed, and `occurrences` cannot hand it a
    # disordered one, since `line_for` is monotone in the byte offset and
    # tree-sitter emits captures in byte order. The outline's shape, whose ties
    # sit ~300 apart across the class/method blocks, flips at 592 of 599 sizes.
    #
    # So be exact about what these two guard, or the next reader will assume the
    # tiebreak is covered on both tools and delete it from one. They do NOT
    # guard the tiebreak -- removing it from `ordered` leaves them green. They
    # guard `occurrences`' DOCUMENT ORDER: they fail if a second query is merged
    # in, if a partition by role lands before the sort, or if the capture walk
    # stops being byte-ordered -- which is precisely the change that would make
    # the tiebreak start mattering here. The tiebreak's own guard is
    # {Lain::Tools::CodeOutline}'s tie example, which does red without it.
    it "breaks a within-line tie among definitions by collection order" do
      path = write("tied.rb", (1..300).map { |i| "class K#{i}; def m#{i}; end; end\n" }.join)

      rows = tool.call(path:, language: "ruby").content.split("\n\n").first.lines.map(&:chomp).drop(1)

      expect(rows.first(4)).to eq(["  L1  class  K1", "  L1  method  m1",
                                   "  L2  class  K2", "  L2  method  m2"])
      expect(rows.take(definitions.limit)
                 .each_slice(2).map { |a, b| [a[/class|method/], b[/class|method/]] }.tally)
        .to eq({ %w[class method] => definitions.limit / 2 })
    end

    it "breaks a within-line tie among references by collection order" do
      path = write("calls.rb", (1..300).map { |i| "def m#{i}; a#{i}(); b#{i}(); c#{i}(); d#{i}(); end\n" }.join)

      rows = tool.call(path:, language: "ruby").content.split("\n\n").last.lines.map(&:chomp).drop(1)

      expect(rows.take(references.limit)
                 .each_slice(4).map { |group| group.map { _1[/\s(\w)\d+\z/, 1] } }.tally)
        .to eq({ %w[a b c d] => references.limit / 4 })
    end

    it "leaves a symbol table within the caps byte-identical" do
      path = write("thing.rb", "class Thing\nend\n")

      expect(tool.call(path:, language: "ruby").content)
        .to eq("DEFINITIONS\n  L1  class  Thing\n\nREFERENCES\n  (none)")
    end
  end
end
