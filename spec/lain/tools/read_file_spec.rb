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

    # ... and the same file with NO window, which is a different reader
    # entirely. This had zero coverage: every empty-file example above passes
    # an offset or a limit and so routes to Window, while Whole is the path
    # every other caller in the repo takes. `File.read` WITH A LENGTH answers
    # nil at EOF -- which every zero-length file is -- so a `touch`ed .rb, an
    # empty __init__.py or a .keep raised FrozenError out of the length-read's
    # nil fallback, past #perform's rescue, and reached the model as a nonsense
    # refusal naming a frozen String.
    it "reads an empty file with no window at all" do
      path = write("empty.txt", "")
      session = Lain::Session.new

      result = tool.call({ path: }, invocation_with(session))

      expect(result).to eq(Lain::Tool::Result.ok(""))
      expect(session.read?(path)).to be(true)
    end

    it "hands an empty file back in the default external encoding, as File.read does" do
      path = write("empty.txt", "")

      expect(tool.call(path:).content.encoding).to eq(File.read(path).encoding)
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

  # T5 fix round B2. The contract this file's own subject states -- "never a
  # raise" -- run as a table over the shapes that break readers. Once PER
  # READER, because the empty-file defect lived exactly in the gap between
  # them: there was an empty-file example, it passed offset/limit, and the
  # default path had no coverage at all.
  describe "the tier-1 read contract, over pathological file shapes" do
    def read_at(path) = tool.call(path:)

    def scratch = tmpdir

    def file_of(bytes) = File.join(tmpdir, "shape.bin").tap { |path| File.binwrite(path, bytes) }

    it_behaves_like "a tier-1 read of any path that never raises"

    context "when read unwindowed, which is what every other caller in the repo does" do
      def read_ceiling = Lain::Tools::ReadFile::WHOLE_BOUND.limit

      def read_of(bytes) = tool.call(path: file_of(bytes))

      it_behaves_like "a tier-1 read that never raises"
    end

    # `limit` is what routes to Window rather than Whole, and it is deliberately
    # far past any row here so the WINDOW's own ceiling is the one being tested
    # rather than the line count.
    context "when read through a window" do
      def read_ceiling = Lain::Tools::ReadFile::WINDOW_BOUND.limit

      def read_of(bytes) = tool.call(path: file_of(bytes), offset: 1, limit: 10_000_000)

      it_behaves_like "a tier-1 read that never raises"
    end
  end

  # Peak RSS reached by a FORKED child running the block, in kB. VmHWM only
  # rises and is never reset, so a delta taken in this process is meaningless
  # once the worker has peaked higher elsewhere; two children forked from the
  # same parent inherit the same mark, so the difference between them belongs
  # to the block and to nothing before it.
  def peak_rss_in_child(&)
    reader, writer = IO.pipe
    pid = fork { report_peak_rss(reader, writer, &) }
    writer.close
    reported = reader.read
    reader.close
    Process.wait(pid)
    # A child that died says so, LOUDLY. Silence used to read as 0, and two
    # zeroes subtract to a passing assertion -- a guard that measures nothing
    # and stays green is worse than no guard, which is the whole lesson of the
    # VmHWM reading this replaced.
    raise "the child reported no peak RSS: #{reported.inspect}" unless reported.match?(/\A\d+\z/)

    reported.to_i
  end

  # `exit!` in an ENSURE, and both halves are load-bearing. `exit!` rather than
  # `exit` so the child never runs RSpec's at_exit hooks and reports a second
  # suite result over the parent's; `ensure` so a raise inside the block cannot
  # let the child fall back into the runner and go on executing the worker's
  # remaining examples -- which under parallel_rspec is indistinguishable from
  # the OOM-kill shape CLAUDE.md warns about.
  def report_peak_rss(reader, writer)
    reader.close
    yield
    writer.write(File.read("/proc/self/status")[/VmHWM:\s+(\d+)/, 1])
  rescue StandardError => e
    writer.write("failed: #{e.class}: #{e.message}")
  ensure
    writer.close
    exit!(0)
  end

  def objects_allocated
    GC.start
    before = GC.stat(:total_allocated_objects)
    yield
    GC.stat(:total_allocated_objects) - before
  end

  # T5: the whole-artifact bound. A file's contents have no partial form, so an
  # oversized read is REFUSED and told where to go instead (Tool::Bounds'
  # stated boundary) rather than truncated into an answer that reads complete.
  # The three facts that matter are that the bytes are never read, that the
  # refusal carries none of them, and that the door T3 opened stays open.
  describe "refusing a read that is too large to hand back" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    # Sparse: File.size reports the apparent length while the file occupies
    # almost no disk, so an example can offer a size no read should pay for
    # without writing the bytes it is asserting are never read.
    def sparse(name, size)
      path = File.join(tmpdir, name)
      File.open(path, "w") { |file| file.truncate(size) }
      path
    end

    # Real bytes, one line each, so a window over them is a window over
    # something rather than over a hole.
    def filled(name, size)
      line = "#{"x" * 63}\n"
      write(name, line * (size / line.bytesize))
    end

    # Every block size the refusal's separator probe asked the filesystem for,
    # in order. It wraps the tool's OWN File.open rather than standing a double
    # in front of it, so the reading is of the real call; and it filters on the
    # path so nothing else running in the example can contribute a row.
    def probe_blocks(path)
      asked = []
      allow(File).to receive(:open).and_wrap_original do |original, *args, &opened|
        if opened && args.first == path
          original.call(*args) { |file| opened.call(recording(file, asked)) }
        else
          original.call(*args, &opened)
        end
      end
      asked
    end

    def recording(file, asked)
      allow(file).to receive(:read).and_wrap_original do |read, *sizes|
        asked << sizes.first
        read.call(*sizes)
      end
      file
    end

    let(:whole_ceiling) { Lain::Tools::ReadFile::WHOLE_BOUND.limit }
    let(:window_ceiling) { Lain::Tools::ReadFile::WINDOW_BOUND.limit }

    it "refuses an unwindowed read of a file over the ceiling" do
      path = sparse("huge.bin", whole_ceiling + 1)

      result = tool.call(path:)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include(path, (whole_ceiling + 1).to_s, whole_ceiling.to_s)
    end

    # AC1's mechanism, restated for T11 rather than relaxed. The DECISION is
    # still reached from File.size -- what changed is that composing the ADVICE
    # for a file over the WINDOW ceiling now costs a separator probe, so "it is
    # never read" is no longer the true statement and asserting it would be
    # asserting the wrong thing. The bound is what carries the memory claim
    # now: every block the probe asks for is one block, and the whole probe is
    # at most the window ceiling, against a 2 MiB file.
    #
    # `not_to be_empty` FIRST, and it is not a formality -- it is what stops
    # the two bounds below being vacuous. `all` and `sum` are both true of an
    # empty Array, so a probe that stopped going through this reader at all
    # would satisfy them while allocating whatever it liked. Measured during
    # review: a 1 MiB `File.read(path, N)` slurp -- exactly the shape this
    # example exists to forbid -- left it green without this line.
    #
    # The `File.read` assertion is narrower than it looks and is kept for what
    # it does cover: RSpec matches whole argument lists, so `with(path)`
    # matches only the UNBOUNDED one-arg `File.read(path)` and never
    # `File.read(path, n)`. The bounds above are what forbid the length-taking
    # slurp.
    it "reads at most a bounded probe of the file it refuses, and never slurps it" do
      path = sparse("huge.bin", whole_ceiling * 8)
      allow(File).to receive(:read).and_call_original
      blocks = probe_blocks(path)

      tool.call(path:)

      expect(File).not_to have_received(:read).with(path)
      expect(blocks).not_to be_empty
      expect(blocks).to all(be_between(1, Lain::Tools::ReadFile::PROBE_BLOCK))
      expect(blocks.sum).to be <= window_ceiling
    end

    # ... and the walk stops at the first separator, so the ordinary file --
    # one that has newlines in it -- costs exactly one block however large it
    # is. This is the half that keeps the probe off the hot path's budget.
    it "stops the probe at the first newline" do
      path = filled("many.txt", window_ceiling * 2)
      blocks = probe_blocks(path)

      tool.call(path:)

      expect(blocks.size).to eq(1)
    end

    it "names a window and the structural tools as the narrower actions" do
      path = sparse("huge.rb", whole_ceiling + 1)

      content = tool.call(path:).content

      expect(content).to include("offset", "limit")
      expect(content).to match(/code_outline|file_symbols|ast_search/)
    end

    # T11. `offset` and `limit` count LINES, so advising them for a file that
    # is ONE line is advice the model cannot act on -- QA spent a round trip on
    # a 1,200,003-byte one-line JSON being told to window a file that refuses
    # every window in turn. The branch is exactly the one where the advice is
    # wrong: a file the WINDOW ceiling cannot admit either.
    describe "a file whose first line alone is over the window ceiling" do
      it "sends a one-line file over the window ceiling to a byte range instead" do
        path = sparse("one.json", window_ceiling + 3)

        content = tool.call(path:).content

        expect(content).to include("head -c", "one line alone is over the ceiling")
        expect(content).not_to include(Lain::Tools::ReadFile::PART_ONLY)
        expect(content).not_to include(Lain::Tools::ReadFile::FULL_COVER)
      end

      it "still names the structural tools alongside the byte range" do
        path = sparse("one.json", window_ceiling + 3)

        expect(tool.call(path:).content).to match(/code_outline|file_symbols|ast_search/)
      end

      # The boundary is LongLine's own, and it is one byte off the obvious
      # reading of it. Window#read chunks at `WINDOW_BOUND.limit + 1` and
      # LongLine refuses any chunk OVER the ceiling, so a first line of exactly
      # `limit + 1` bytes INCLUDING its newline arrives whole and IS refused --
      # a probe asking "is there a newline within limit + 1 bytes" answers yes
      # for this file and reopens the very loop this card closes.
      it "sends a first line of exactly the ceiling plus its newline to a byte range too" do
        path = write("edge.json", "#{"x" * window_ceiling}\n")

        content = tool.call(path:).content

        expect(content).to include("head -c")
        expect(content).not_to include(Lain::Tools::ReadFile::PART_ONLY)
        expect(content).not_to include(Lain::Tools::ReadFile::FULL_COVER)
      end

      # ... and it does not over-reach by one in the other direction: a first
      # line of exactly the ceiling INCLUDING its newline is the largest one a
      # window can still serve, so that file keeps the window advice, and the
      # window is asserted to work rather than assumed to.
      it "keeps the window advice for a first line of exactly the ceiling, and that window works" do
        path = write("fits.json", "#{"x" * (window_ceiling - 1)}\nrest\n")

        content = tool.call(path:).content

        expect(content).to include(Lain::Tools::ReadFile::PART_ONLY)
        expect(content).not_to include("head -c")
        expect(tool.call(path:, offset: 1, limit: 1)).to have_attributes(is_error: false)
      end

      # The FULL_COVER branch has no bug and must not be widened into: a
      # newline-free file UNDER the window ceiling has a line 1 under the
      # ceiling, so LongLine never fires and a full-cover window serves it.
      it "leaves a newline-free file under the window ceiling on its full-cover advice" do
        path = sparse("wide.bin", whole_ceiling + 1024)

        content = tool.call(path:).content

        expect(content).to include(Lain::Tools::ReadFile::FULL_COVER)
        expect(content).not_to include("head -c")
      end

      it "serves that same file through the full-cover window it was advised to use" do
        path = sparse("wide.bin", whole_ceiling + 1024)

        result = tool.call(path:, offset: 1, limit: 10_000_000)

        expect(result).to have_attributes(is_error: false)
        expect(result.content.bytesize).to eq(whole_ceiling + 1024)
      end

      it "still offers a window for a line-structured file under the window ceiling" do
        path = filled("many.txt", whole_ceiling * 2)

        expect(tool.call(path:).content).to include(Lain::Tools::ReadFile::FULL_COVER)
      end

      # ... and a line-structured file OVER the window ceiling keeps the
      # partial-window advice: its line 1 is short, so a window narrow enough
      # does reach it and the byte range would be the wrong ceiling to send it
      # down.
      it "still offers a partial window for a line-structured file over the window ceiling" do
        path = filled("vast.txt", window_ceiling * 2)

        content = tool.call(path:).content

        expect(content).to include(Lain::Tools::ReadFile::PART_ONLY)
        expect(content).not_to include("head -c")
      end

      it "carries none of the one-line file's bytes into the refusal" do
        path = write("one.json", "SENTINEL" * ((window_ceiling / 8) + 2))

        expect(tool.call(path:).content).not_to include("SENTINEL")
      end

      it "records nothing on the session for the one-line file it refused" do
        path = sparse("one.json", window_ceiling + 3)
        session = Lain::Session.new

        tool.call({ path: }, invocation_with(session))

        expect(session.read?(path)).to be(false)
        expect(session.partially_read?(path)).to be(false)
      end
    end

    it "carries none of the refused file's bytes" do
      path = write("huge.txt", "SENTINEL\n" * ((whole_ceiling / 9) + 2))

      expect(tool.call(path:).content).not_to include("SENTINEL")
    end

    it "records nothing on the session for a read it refused" do
      path = sparse("huge.bin", whole_ceiling + 1)
      session = Lain::Session.new

      tool.call({ path: }, invocation_with(session))

      expect(session.read?(path)).to be(false)
      expect(session.partially_read?(path)).to be(false)
    end

    it "still reads a file exactly at the ceiling" do
      path = filled("edge.txt", whole_ceiling)

      expect(tool.call(path:)).to have_attributes(is_error: false)
    end

    # The deadlock this card must not create. A file over the whole-read
    # ceiling is still reachable end to end through a window, and a window that
    # covers it records a COMPLETE read -- which is the one predicate
    # Tools::EditFile and Tools::WriteFile both ask.
    it "leaves a file over the whole ceiling editable through a full-cover window" do
      path = filled("over.txt", whole_ceiling * 2)
      session = Lain::Session.new

      result = tool.call({ path:, offset: 1, limit: 10_000_000 }, invocation_with(session))

      expect(result).to have_attributes(is_error: false)
      expect(result.content).to eq(File.read(path))
      expect(session.read?(path)).to be(true)
    end

    # ... but a window is not an unbounded escape from the bound: a limit large
    # enough to cover a huge file is a whole-artifact read wearing a window's
    # clothes, so the bytes a window HANDS BACK carry their own ceiling.
    it "refuses a window that hands back more than the window ceiling" do
      path = filled("vast.txt", window_ceiling + 65_536)

      result = tool.call(path:, offset: 1, limit: 10_000_000)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include(path, window_ceiling.to_s)
    end

    it "names the span it measured, and its true size, when it refuses a window" do
      line = "#{"x" * 63}\n"
      over = (window_ceiling / line.bytesize) + 1
      path = filled("vast.txt", window_ceiling + 65_536)

      content = tool.call(path:, offset: 1, limit: 10_000_000).content

      expect(content).to include("lines 1-#{over}", (over * line.bytesize).to_s)
    end

    it "carries none of the refused window's bytes" do
      path = write("vast.txt", "SENTINEL\n" * ((window_ceiling / 9) + 2))

      expect(tool.call(path:, offset: 1, limit: 10_000_000).content).not_to include("SENTINEL")
    end

    it "records nothing on the session for a window it refused" do
      path = filled("vast.txt", window_ceiling + 65_536)
      session = Lain::Session.new

      tool.call({ path:, offset: 1, limit: 10_000_000 }, invocation_with(session))

      expect(session.read?(path)).to be(false)
      expect(session.partially_read?(path)).to be(false)
    end

    it "leaves a narrower window of the same file readable" do
      path = filled("vast.txt", window_ceiling + 65_536)

      expect(tool.call(path:, offset: 1, limit: 100)).to have_attributes(is_error: false)
    end

    # A file with no line separator at all is ONE line, and `File.foreach`
    # hands a line over entire -- so without a byte limit on the read itself a
    # single-line file is materialised before any byte counter can see it, and
    # the failure at scale is a `NoMemoryError`, which is not a StandardError
    # and so escapes Effect::Handler::Live's rescue exactly as T3's own
    # `first(n)` note describes. Measured on a 512 MiB sparse file: 0 kB peak
    # RSS on the whole-read arm, 512 MB on the window arm.
    #
    # The teeth here are BEHAVIOURAL and so cannot decay with process order:
    # the size the refusal names is the size it MEASURED, and a reader that had
    # materialised the line would have had to say the whole 8 MiB to say
    # anything at all.
    it "weighs a separatorless file one chunk at a time, never as one line" do
      path = sparse("oneline.bin", window_ceiling * 8)

      result = tool.call(path:, offset: 1, limit: 1)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("the first #{window_ceiling + 1} bytes")
      expect(result.content).not_to include((window_ceiling * 8).to_s)
    end

    # The measured half, in a CHILD so the reading is order-independent: VmHWM
    # is a process-lifetime high-water mark that only rises, so a delta taken
    # in this process reads 0 for any call staying under a peak the worker
    # already hit -- and under parallel_rspec a worker has run many files at
    # ~150 MB before reaching here. Two children forked from the same parent
    # inherit the same mark, so the difference between them is the call's own.
    it "costs a chunk of memory, not a file's worth" do
      skip "fork and procfs are what this measures with" unless Process.respond_to?(:fork) &&
                                                                File.exist?("/proc/self/status")
      big = sparse("oneline.bin", window_ceiling * 8)
      small = write("small.txt", "x\n")

      control = peak_rss_in_child { tool.call(path: small, offset: 1, limit: 1) }
      measured = peak_rss_in_child { tool.call(path: big, offset: 1, limit: 1) }

      expect(measured - control).to be < (window_ceiling * 4 / 1024)
    end

    # ... and it must not tell such a file's reader to narrow a window, because
    # no offset and no limit reaches inside one line. The subject names a byte
    # prefix of the line, which is the only thing that was measured.
    it "sends a single over-long line somewhere other than a narrower window" do
      path = write("minified.js", "x" * (window_ceiling + 1024))

      content = tool.call(path:, offset: 1, limit: 1).content

      expect(content).to include("of line 1 of #{path}", "bash")
      expect(content).not_to include("smaller limit")
    end

    # B1. The byte limit that keeps a long line weighable SPLITS it, and
    # `offset`/`limit` count LINES -- so a walk that counts chunks steps over a
    # split boundary and renumbers every line after it. Measured before the
    # fix: `offset: 2, limit: 3` on this file returned is_error=false with
    # 512 KB of line 1's TAIL labelled "lines 2-4". A wrong answer returned as
    # a success is the one outcome the whole-artifact doctrine exists to
    # prevent, so the file refuses whatever the offset.
    describe "a file holding a line over the window ceiling" do
      let(:path) do
        write("mixed.txt", "#{"A" * (window_ceiling + (window_ceiling / 2))}\nsecond\nthird\nfourth\n")
      end

      [{ offset: 2, limit: 3 }, { offset: 3, limit: 2 }, { offset: 4, limit: 2 }, { offset: 2 }].each do |window|
        it "refuses #{window.inspect} rather than renumbering past the split" do
          result = tool.call(path:, **window)

          expect(result).to have_attributes(is_error: true)
          expect(result.content).to include("of line 1 of #{path}")
        end
      end

      it "hands back no byte of the over-long line under any offset" do
        expect(tool.call(path:, offset: 2, limit: 3).content).not_to include("AAAA")
      end

      # The rule is "if the walk touches an over-ceiling line, refuse", with no
      # exception for the ONE line past the window that decides completeness --
      # so a short line followed by a huge one is refused too, naming the huge
      # one. That is a real loss and it is the honest simple rule: the
      # alternative is a second notion of which chunks count, and the deadlock
      # is untouched either way, because a file holding a line over the window
      # ceiling is over that ceiling itself and was never in the editable band.
      it "refuses even a window whose only oversized line is the one past its end" do
        short = write("head.txt", "first\n#{"A" * (window_ceiling + 1024)}\n")

        result = tool.call(path: short, offset: 1, limit: 1)

        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("of line 2 of #{short}")
      end

      it "leaves every file in the editable band untouched by that rule" do
        band = filled("band.txt", whole_ceiling * 3)

        expect(tool.call(path: band, offset: 1, limit: 10_000_000)).to have_attributes(is_error: false)
      end

      # The line number is counted from COMPLETED lines, so it is the file's
      # own numbering rather than the walk's: a separatorless file is one line
      # however far past its end the offset reaches.
      it "names line 1 of a separatorless file whatever offset was asked for" do
        separatorless = sparse("oneline.bin", window_ceiling * 4)

        expect(tool.call(path: separatorless, offset: 500).content).to include("of line 1 of")
      end

      # The refusal has to name a window that would WORK, and for a long line
      # the model did not ask to see that is not the head of the file by
      # default. A window ending at line M pulls line M+1 as its completeness
      # probe, so the last window a file blocked at line N can serve ends at
      # N-2 -- which is where the arithmetic in these examples comes from, and
      # following it is asserted rather than assumed.
      describe "the narrower action it names" do
        let(:blocked) do
          lines = (1..200).map { |n| "line #{n}\n" }
          lines[40] = "#{"B" * (window_ceiling + 1024)}\n"
          write("blocked.txt", lines.join)
        end

        it "tells a window that starts before the long line where to stop" do
          content = tool.call(path: blocked, offset: 1, limit: 100).content

          expect(content).to include("stop the window before line 41: offset 1 with limit at most 39")
          expect(tool.call(path: blocked, offset: 1, limit: 39)).to have_attributes(is_error: false)
        end

        it "says the long line is BEFORE a window that starts after it, and names one that works" do
          content = tool.call(path: blocked, offset: 100, limit: 10).content

          expect(content).to include("line 41 is before the window you asked for and cannot be walked past")
          expect(content).to include("offset 1 with limit at most 39")
          expect(tool.call(path: blocked, offset: 1, limit: 39)).to have_attributes(is_error: false)
        end

        it "does not send a window far into the file to a byte range at the head of it" do
          expect(tool.call(path: blocked, offset: 100, limit: 10).content).not_to include("head -c")
        end

        # Nothing before line 1 or 2 can be read, so there the only honest
        # advice really is to leave read_file.
        it "falls back to a byte range when the very first line is the long one" do
          first = write("first.txt", "B" * (window_ceiling + 1024))

          content = tool.call(path: first, offset: 1, limit: 5).content

          expect(content).to include("head -c")
        end
      end
    end

    # S3. `whole_lines?` answered "was the last chunk split", which is one byte
    # away from "is one line over the ceiling": a line of exactly the chunk
    # limit INCLUDING its newline arrives whole, so the model was told to
    # narrow a window that had nothing to narrow -- offset 1/limit 2 and
    # offset 1/limit 1 returned byte-identical refusals. Any single chunk over
    # the ceiling is now the long-line case, whether or not it ends in one.
    it "never advises narrowing a window that has only one line in it" do
      path = write("exact.txt", "#{"x" * window_ceiling}\n")

      one = tool.call(path:, offset: 1, limit: 1)
      two = tool.call(path:, offset: 1, limit: 2)

      expect(one.content).to include("of line 1 of #{path}")
      expect(one.content).not_to include("smaller limit")
      expect(two.content).to eq(one.content)
    end

    # S2. `File.size` is 0 for a character device and for a fifo, so the stat
    # that makes the whole-read refusal free waves both through. Measured
    # under `ulimit -v`: `read_file /dev/zero` died with NoMemoryError, which
    # is not a StandardError and so escapes both #perform's rescue and
    # Effect::Handler::Live's -- the identical route closed on the window arm,
    # left open on the arm the memory claim is about.
    it "refuses a character device rather than believing its size" do
      skip "no /dev/zero here" unless File.exist?("/dev/zero")

      result = tool.call(path: "/dev/zero")

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("regular file")
    end

    it "refuses a fifo for the same reason" do
      path = File.join(tmpdir, "pipe")
      File.mkfifo(path)

      expect(tool.call(path:)).to have_attributes(is_error: true, content: /regular file/)
    end

    # ... and the stat is a decision, not a guarantee: an appender writing
    # between the stat and the read handed back 1,309,696 bytes through a
    # 262,144-byte ceiling. Stubbing the stat is the deterministic stand-in
    # for that race -- the read itself must be capped too.
    it "caps the read as well as the stat, so a file that grew is still refused" do
      path = filled("grew.txt", whole_ceiling * 2)
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(path).and_return(10)

      result = tool.call(path:)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include(whole_ceiling.to_s)
    end

    # ... and it says only what it measured. Having just learned the stat was
    # wrong, this branch knows a PREFIX and not a total, so it names the prefix
    # and offers only a partial window -- promising a full-cover one would be
    # promising a size it cannot check.
    it "names the prefix it measured, not a total it does not know, when a file grew" do
      path = filled("grew.txt", whole_ceiling * 2)
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(path).and_return(10)

      content = tool.call(path:).content

      expect(content).to include("the first #{whole_ceiling + 1} bytes of #{path}")
      expect(content).to include(Lain::Tools::ReadFile::PART_ONLY)
      expect(content).not_to include(Lain::Tools::ReadFile::FULL_COVER)
    end

    it "keeps the unwindowed read's bytes and encoding identical for a file that fits" do
      utf8 = write("utf8.txt", "héllo wörld\n" * 10)
      raw = File.read(utf8)

      result = tool.call(path: utf8)

      expect(result.content).to eq(raw)
      expect(result.content.encoding).to eq(raw.encoding)
    end

    it "keeps invalid UTF-8 intact through the capped read" do
      path = File.join(tmpdir, "invalid.bin")
      File.binwrite(path, "\xFF\xFE ok\n")

      expect(tool.call(path:).content.b).to eq("\xFF\xFE ok\n".b)
    end

    # The window ceiling sits above the whole-read ceiling on purpose: were
    # they equal, every file between them would be unreadable end to end and so
    # permanently uneditable.
    it "keeps the window ceiling above the whole-read ceiling" do
      expect(window_ceiling).to be > whole_ceiling
    end
  end
end
