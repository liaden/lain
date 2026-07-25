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

  it "has a model-facing name and description" do
    expect(tool.name).to eq("file_symbols")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
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
end
