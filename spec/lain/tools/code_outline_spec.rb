# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::CodeOutline do
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

  it "lists a file's classes/modules/methods with line numbers, ordered by position, " \
     "ignoring identifiers in comments or strings" do
    # Method defs are written WITH parens deliberately: the shared catalog's
    # `:method_def` templates are "def $NAME($$$A)" / "def self.$NAME($$$A)",
    # which -- like ast-grep generally -- match the concrete parenthesized
    # node only; a paren-less `def total` is a distinct CST shape the current
    # catalog does not cover. That is a pre-existing T2 catalog limitation,
    # not something this tool works around.
    path = write("outline_me.rb", <<~RUBY)
      module Outer
        # class NotReal
        class Inner
          def total()
            "def not_real"
          end

          def self.build()
            new
          end
        end
      end
    RUBY

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    lines = result.content.lines.map(&:chomp)
    expect(lines).to eq(
      [
        "L1  module Outer",
        "L3  class Inner",
        "L4  def total",
        "L8  def self.build"
      ]
    )
    expect(result.content).not_to include("NotReal")
    expect(result.content).not_to include("not_real")
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

  it "reports an unsupported language as an error Result rather than raising" do
    path = write("thing.cob", "IDENTIFICATION DIVISION.")

    result = tool.call(path:, language: "cobol")

    expect(result).to have_attributes(is_error: true, content: /cobol/)
  end

  it "returns an ok, empty result for a file with no classes/modules/methods" do
    path = write("empty.rb", "x = 1\ny = 2\n")

    result = tool.call(path:, language: "ruby")

    expect(result.ok?).to be(true)
    expect(result.content).to eq("")
  end

  # The ext refuses a source whose bytes are not valid UTF-8 rather than
  # transcoding it (ext/lain/src/read_text.rs), because byte offsets into a
  # transcoded copy are worse than no answer. The tool's job is to turn that
  # into an error Result the model can act on, not to let an EncodingError
  # escape #call -- every other unreadable-file case here already does.
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
    it "outlines an ordinary UTF-8 file even when the default external encoding is US-ASCII" do
      path = write("accented.rb", "# a café comment\nclass Thing\nend\n")
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      begin
        result = tool.call(path:, language: "ruby")
      ensure
        Encoding.default_external = previous
      end

      expect(result).to have_attributes(ok?: true, content: "L2  class Thing")
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
      # Parens deliberately: the `:method_def` catalog templates match the
      # parenthesized node only -- see the pre-existing T2 note above.
      write("thing.rb", "class Thing\n  def call()\n  end\nend\n")

      result = tool.call({ path: "thing.rb", language: "ruby" }, invocation_with(session_at(tmpdir)))

      expect(result.content).to eq("L1  class Thing\nL2  def call")
    end

    it "honors an absolute path as given, whatever the WorkerEnv cwd" do
      path = write("thing.rb", "class Thing\nend\n")

      Dir.mktmpdir do |elsewhere|
        result = tool.call({ path:, language: "ruby" }, invocation_with(session_at(elsewhere)))

        expect(result.content).to eq("L1  class Thing")
      end
    end

    it "resolves a relative path against the process cwd under the default WorkerEnv" do
      write("thing.rb", "class Thing\nend\n")

      Dir.chdir(tmpdir) do
        result = tool.call({ path: "thing.rb", language: "ruby" }, invocation_with(Lain::Session.new))

        expect(result.content).to eq("L1  class Thing")
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
end
