# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::ReadFile do
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

  it "reads a file's full contents" do
    path = write("hello.txt", "hello\nworld\n")
    expect(tool.call(path:)).to eq(Lain::Tool::Result.ok("hello\nworld\n"))
  end

  it "reports a missing file as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope.txt")
    result = tool.call(path: missing)
    expect(result).to have_attributes(is_error: true)
    expect(result.content).to include("no such file")
  end

  it "reports a directory as an error Result rather than raising" do
    result = tool.call(path: tmpdir)
    expect(result).to have_attributes(is_error: true, content: /is a directory/)
  end

  it "reports an unreadable file as an error Result rather than raising" do
    path = write("secret.txt", "shh")
    File.chmod(0o000, path)
    result = tool.call(path:)
    expect(result).to have_attributes(is_error: true, content: /not readable/)
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  it "does not care about the invocation it is handed" do
    path = write("a.txt", "a")
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect(tool.call({ path: }, invocation)).to eq(Lain::Tool::Result.ok("a"))
  end

  describe "recording reads on the session (invocation.context)" do
    let(:session) { Lain::Session.new }

    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    it "records a successful read on the threaded session" do
      path = write("read.txt", "contents")

      tool.call({ path: }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "does not record a path it never read" do
      path = write("read.txt", "contents")
      tool.call({ path: }, invocation_with(session))

      expect(session.read?(File.join(tmpdir, "never.txt"))).to be(false)
    end

    it "does not record a failed read" do
      missing = File.join(tmpdir, "nope.txt")

      tool.call({ path: missing }, invocation_with(session))

      expect(session.read?(missing)).to be(false)
    end

    # AC3: a Session::Null context keeps the tool working with nothing recorded.
    it "records into a Session::Null context without raising" do
      path = write("read.txt", "contents")
      invocation = invocation_with(Lain::Session::Null.instance)

      result = tool.call({ path: }, invocation)

      expect(result).to eq(Lain::Tool::Result.ok("contents"))
    end
  end

  describe "resolving relative paths against the session WorkerEnv" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    it "resolves a relative path against Dir.pwd under the default WorkerEnv" do
      write("rel.txt", "relative-default")
      Dir.chdir(tmpdir) do
        result = tool.call({ path: "rel.txt" }, invocation_with(Lain::Session.new))
        expect(result).to eq(Lain::Tool::Result.ok("relative-default"))
      end
    end

    it "resolves a relative path under an injected WorkerEnv cwd" do
      write("rel.txt", "under-sandbox")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: ENV.to_h))

      result = tool.call({ path: "rel.txt" }, invocation_with(session))

      expect(result).to eq(Lain::Tool::Result.ok("under-sandbox"))
    end

    it "records the RESOLVED path so a later read-before-write contract still matches" do
      write("rel.txt", "x")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: ENV.to_h))

      tool.call({ path: "rel.txt" }, invocation_with(session))

      expect(session.read?(File.join(tmpdir, "rel.txt"))).to be(true)
    end
  end

  # T3: a window is what makes a file too large to read whole still reachable.
  # The three facts that matter are the BYTES returned, the COMPLETENESS the
  # read-set records, and that neither moves when no window is asked for.
  describe "reading a window of a file" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    def numbered(count) = (1..count).map { |n| "line #{n}\n" }.join

    def span(from, to) = (from..to).map { |n| "line #{n}\n" }.join

    # The in-band disclosure a SHORT window carries, in grep's register: it
    # names the window and the fact of partialness, never a total the tool
    # would have to read the whole file to know.
    def notice(described)
      "... window only: #{described}; the rest of the file " \
        "was not read, so edit_file will refuse it"
    end

    it "returns only the requested window, and one line saying it is a window" do
      path = write("big.txt", numbered(5000))

      result = tool.call(path:, offset: 2001, limit: 2000)

      expect(result).to eq(Lain::Tool::Result.ok(span(2001, 4000) + notice("lines 2001-4000")))
    end

    it "takes an offset alone as 'from here to the end'" do
      path = write("big.txt", numbered(10))

      expect(tool.call(path:, offset: 8))
        .to eq(Lain::Tool::Result.ok(span(8, 10) + notice("lines 8-10")))
    end

    it "takes a limit alone as 'the first n lines'" do
      path = write("big.txt", numbered(10))

      expect(tool.call(path:, limit: 3))
        .to eq(Lain::Tool::Result.ok(span(1, 3) + notice("lines 1-3")))
    end

    it "keeps a final line that has no newline of its own, and separates the notice from it" do
      path = write("ragged.txt", "a\nb\nc")

      expect(tool.call(path:, offset: 2, limit: 2))
        .to eq(Lain::Tool::Result.ok("b\nc\n#{notice("lines 2-3")}"))
    end

    # A COMPLETE window withholds nothing, so a notice on it would be noise --
    # and it must stay byte-identical to the unwindowed read, because AC 3 and
    # the Whole-routing of `offset: 1` both rest on the full-cover case being
    # indistinguishable from a whole read.
    it "adds no notice when the window reaches both ends of the file" do
      path = write("small.txt", numbered(100))

      expect(tool.call(path:, offset: 1, limit: 100)).to eq(Lain::Tool::Result.ok(numbered(100)))
    end

    it "adds no notice when the limit overshoots the end from line one" do
      path = write("small.txt", numbered(100))

      expect(tool.call(path:, offset: 1, limit: 10_000)).to eq(Lain::Tool::Result.ok(numbered(100)))
    end

    it "says so plainly when the window lands past the end of the file" do
      path = write("small.txt", numbered(10))

      expect(tool.call(path:, offset: 500, limit: 10))
        .to eq(Lain::Tool::Result.ok(notice("no lines at or after line 500")))
    end

    it "records a PARTIAL read when the window leaves lines unseen" do
      path = write("big.txt", numbered(5000))
      session = Lain::Session.new

      tool.call({ path:, offset: 2001, limit: 2000 }, invocation_with(session))

      expect(session.read?(path)).to be(false)
      expect(session.partially_read?(path)).to be(true)
    end

    it "records a partial read when the window starts past the first line, even to EOF" do
      path = write("big.txt", numbered(10))
      session = Lain::Session.new

      tool.call({ path:, offset: 2 }, invocation_with(session))

      expect(session.read?(path)).to be(false)
      expect(session.partially_read?(path)).to be(true)
    end

    # AC3, and the deadlock this card exists to prevent: without it, a file too
    # big to read unwindowed would be permanently uneditable.
    it "records a COMPLETE read when the window covers the whole file" do
      path = write("small.txt", numbered(100))
      session = Lain::Session.new

      tool.call({ path:, offset: 1, limit: 100 }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "counts a window whose limit overshoots the end as complete" do
      path = write("small.txt", numbered(100))
      session = Lain::Session.new

      tool.call({ path:, offset: 1, limit: 10_000 }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "counts an offset of 1 with no limit as complete" do
      path = write("small.txt", numbered(100))
      session = Lain::Session.new

      tool.call({ path:, offset: 1 }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "counts an empty file covered by a window as completely read" do
      path = write("empty.txt", "")
      session = Lain::Session.new

      result = tool.call({ path:, offset: 1, limit: 10 }, invocation_with(session))

      expect(result).to eq(Lain::Tool::Result.ok(""))
      expect(session.read?(path)).to be(true)
    end

    # AC4: the unwindowed path is the one every other caller in the repo takes,
    # and its bytes are pinned above ("reads a file's full contents").
    it "leaves the unwindowed read complete and byte-identical" do
      path = write("small.txt", numbered(100))
      session = Lain::Session.new

      result = tool.call({ path: }, invocation_with(session))

      expect(result).to eq(Lain::Tool::Result.ok(numbered(100)))
      expect(session.read?(path)).to be(true)
    end

    it "refuses a zero or negative offset as malformed input" do
      path = write("small.txt", numbered(10))

      expect { tool.call(path:, offset: 0) }
        .to raise_error(Lain::Tool::InvalidInput, /Offset must be greater than or equal to 1/)
    end

    it "refuses a zero or negative limit as malformed input" do
      path = write("small.txt", numbered(10))

      expect { tool.call(path:, limit: 0) }
        .to raise_error(Lain::Tool::InvalidInput, /Limit must be greater than or equal to 1/)
    end

    it "records nothing when a windowed read fails" do
      missing = File.join(tmpdir, "nope.txt")
      session = Lain::Session.new

      tool.call({ path: missing, offset: 1, limit: 10 }, invocation_with(session))

      expect(session.read?(missing)).to be(false)
      expect(session.partially_read?(missing)).to be(false)
    end

    it "advertises offset and limit in the schema the model sees" do
      properties = described_class.new.input_schema.fetch("properties")

      expect(properties.keys).to include("offset", "limit")
    end

    # Fix 1: `offset` and `limit` are the only inputs here that reach Ruby's own
    # allocator, and a number past what a JSON integer carries exactly used to
    # arrive as a bare `RangeError: bignum too big to convert into 'long'` --
    # naming neither parameter nor remedy, beside the clean message `offset: 0`
    # already produced.
    describe "a line number too large to mean anything" do
      it "refuses a limit past the exact-JSON-integer ceiling by name" do
        path = write("small.txt", numbered(10))

        expect { tool.call(path:, limit: 10**20) }
          .to raise_error(Lain::Tool::InvalidInput, /Limit must be less than or equal to/)
      end

      it "refuses an oversized offset by name, for the same reason" do
        path = write("small.txt", numbered(10))

        expect { tool.call(path:, offset: 10**20) }
          .to raise_error(Lain::Tool::InvalidInput, /Offset must be less than or equal to/)
      end

      it "publishes both ceilings in the schema the model sees" do
        properties = described_class.new.input_schema.fetch("properties")

        expect(properties.fetch("limit")).to include("maximum")
        expect(properties.fetch("offset")).to include("maximum")
      end

      # The measured half: `lazy.first(n)` RESERVES an Array of n slots before
      # a single line is read (773 MB at n=10^8, measured), so a permitted-but
      # -large limit is an allocation the model chose. `lazy.take(n).force`
      # reserves nothing. Under an address-space cap the difference is a
      # `NoMemoryError`, which is not a StandardError and so escapes
      # Effect::Handler::Live's rescue and propagates past the loop.
      it "reserves no address space in proportion to a large limit" do
        skip "no /proc/self/status here -- the address-space check needs procfs" unless File.exist?("/proc/self/status")
        path = write("small.txt", numbered(10))
        before = vm_size_kb

        tool.call(path:, limit: 50_000_000)

        expect(vm_size_kb - before).to be < 10_000
      end
    end

    # Fix 2: `offset: 1` with no limit IS the whole file, so it must take the
    # whole-file path rather than materialise every line as its own String.
    # Left routed to Window it was strictly worse than the File.read it is
    # equivalent to -- and, once T5 bounds the unwindowed read, it would have
    # been a one-keyword bypass of the artifact bound at the highest memory
    # cost of the three spellings.
    describe "an offset of one with no limit" do
      let(:many) { numbered(20_000) }

      it "returns bytes identical to the unwindowed read" do
        path = write("many.txt", many)

        expect(tool.call(path:, offset: 1)).to eq(tool.call(path:))
      end

      it "records the same complete read the unwindowed path records" do
        path = write("many.txt", many)
        session = Lain::Session.new

        tool.call({ path:, offset: 1 }, invocation_with(session))

        expect(session.read?(path)).to be(true)
      end

      it "allocates like a whole read, not like a line-by-line one" do
        path = write("many.txt", many)
        whole = objects_allocated { tool.call(path:) }

        windowed = objects_allocated { tool.call(path:, offset: 1) }

        expect(windowed).to be < whole + 1000
      end
    end
  end

  def vm_size_kb = File.read("/proc/self/status")[/VmSize:\s+(\d+)/, 1].to_i

  def objects_allocated
    GC.start
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end
end
