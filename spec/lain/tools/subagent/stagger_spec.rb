# frozen_string_literal: true

require "async"
require "timeout"
require "tempfile"

RSpec.describe Lain::Tools::Subagent::Stagger do
  let(:journal) { [] }
  subject(:stagger) { described_class.new(journal:) }

  # Genuine FD-level redirection, not a bare `$stderr = StringIO.new`: the
  # async gem's Console logger may hold its own reference to the ORIGINAL
  # `$stderr` IO object (resolved once, at gem load), so reassigning the
  # global would not intercept anything it writes. `IO#reopen` instead
  # points the SAME underlying file descriptor at a tempfile, so anything
  # writing to fd 2 -- including an already-cached IO reference -- lands
  # here. Verified against tmp/c3-probes/probe_bare_async_stderr_leak.rb's
  # own `2>stderr.log` shell redirection before use below.
  def capture_stderr(&block)
    original = $stderr.dup
    Tempfile.create("stderr-capture") { |tmp| redirect_stderr_through(tmp, &block) }
  ensure
    $stderr.reopen(original)
    original.close
  end

  def redirect_stderr_through(tmp)
    $stderr.reopen(tmp)
    yield
    $stderr.flush
    tmp.rewind
    tmp.read
  end

  # A dispatch unit shaped closely enough after a real streaming round trip
  # to exercise genuine fiber interleaving without a network: it logs its
  # own dispatch, YIELDS to the reactor (the "request in flight" wait a real
  # socket read would impose), fires `on_stream_started` when `stream:`,
  # yields again (the rest of the stream), then completes. `log` is a
  # SHARED array so a spec can read true chronological order across
  # siblings -- the property "child 1 dispatches alone" is a claim about
  # ORDER, which only a shared, append-only log can show.
  def dispatch_unit(index, log, stream: true, digest: "prefix-#{index}")
    lambda do |on_stream_started:|
      log << [:dispatch, index, digest]
      Async::Task.current.yield
      if stream
        on_stream_started.call(digest)
        log << [:stream_started, index, digest]
      end
      Async::Task.current.yield
      "result-#{index}"
    end
  end

  describe "#call" do
    it "returns [] for an empty fan-out, dispatching and journaling nothing" do
      expect(stagger.call([])).to eq([])
      expect(journal).to be_empty
    end

    it "releases a lone task with no gating" do
      log = []

      expect(stagger.call([dispatch_unit(0, log)])).to eq(["result-0"])
      expect(log.map { |event, index, _digest| [event, index] })
        .to eq([[:dispatch, 0], [:stream_started, 0]])
      expect(journal.map(&:class)).to eq([described_class::Dispatched, described_class::Released])
    end
  end

  # AC1 (Gherkin): "release one, await, release the rest"
  describe "release one, await, release the rest" do
    it "dispatches child 1 alone, releases 2-4 only after child 1's stream_started, and journals dispatch order" do
      log = []
      tasks = Array.new(4) { |i| dispatch_unit(i, log) }

      results = stagger.call(tasks)

      expect(results).to eq(%w[result-0 result-1 result-2 result-3])

      # Child 1 alone: the only :dispatch entry before ANY :stream_started is index 0's own.
      release_at = log.index { |event, *| event == :stream_started }
      dispatches_before_release = log.first(release_at).select { |event, *| event == :dispatch }
      expect(dispatches_before_release).to eq([[:dispatch, 0, "prefix-0"]])

      # 2-4 dispatch only strictly AFTER child 1's stream_started fires.
      later_dispatch_indices = log.drop(release_at + 1).select { |event, *| event == :dispatch }.map { |_e, i, _d| i }
      expect(later_dispatch_indices).to contain_exactly(1, 2, 3)

      # Dispatch order journals: 0 dispatches, the release names why, then 1-3 dispatch.
      expect(journal.map(&:class)).to eq(
        [described_class::Dispatched, described_class::Released,
         described_class::Dispatched, described_class::Dispatched, described_class::Dispatched]
      )
      expect(journal.first.index).to eq(0)
      expect(journal[1].reason).to eq(:stream_started)
      expect(journal.drop(2).map(&:index)).to contain_exactly(1, 2, 3)
    end
  end

  # AC3 (Gherkin): "no stream_started degrades safely"
  describe "no stream_started degrades safely" do
    it "releases all children when the provider never signals, journaling the degradation" do
      log = []
      tasks = Array.new(3) { |i| dispatch_unit(i, log, stream: false) }

      results = nil
      expect { Timeout.timeout(2) { results = stagger.call(tasks) } }.not_to raise_error

      expect(results).to eq(%w[result-0 result-1 result-2])
      expect(log.select { |event, *| event == :dispatch }.map { |_e, i, _d| i }).to contain_exactly(0, 1, 2)
      expect(journal.map(&:class)).to eq(
        [described_class::Dispatched, described_class::Released,
         described_class::Dispatched, described_class::Dispatched]
      )
      expect(journal[1].reason).to eq(:degraded)
    end

    it "still opens the gate (and journals the degradation) when sibling 1 raises before ever signalling" do
      log = []
      boom = ->(**_kwargs) { raise "boom" }
      tasks = [boom, dispatch_unit(1, log)]

      expect { Timeout.timeout(2) { stagger.call(tasks) } }.to raise_error(RuntimeError, "boom")

      expect(journal.map(&:class)).to include(described_class::Released)
      expect(journal.grep(described_class::Released).first.reason).to eq(:degraded)
    end

    # FIX 1 (review round 1, BLOCKER): the async gem itself, not Lain, writes
    # "Task may have ended with unhandled exception." straight to STDERR
    # whenever an eagerly-run `.async` block raises before its own first
    # yield and nobody has called `.wait` on it YET -- regardless of whether
    # `.wait` later re-raises and a caller handles it cleanly (reproduced
    # 100% against the bare gem, no Lain involved, in
    # tmp/c3-probes/probe_bare_async_stderr_leak.rb). `spec/output_discipline
    # _spec.rb`'s AST scan cannot see this: the `warn` call lives inside the
    # gem, not in lib/. A stray line interleaved into the Journal's NDJSON is
    # exactly the catastrophe CLAUDE.md's output discipline section exists
    # to prevent -- one bad byte and `JSON.parse` fails on that line. The
    # fix is `finished: false` at both `root.async` call sites in
    # {Stagger#call}/{Stagger#release_rest} (tested black-box here, not by
    # asserting the kwarg is present, since the observable property is the
    # one that matters: no bytes on stderr).
    it "never writes to stderr when sibling 1 raises before ever signalling" do
      boom = ->(**_kwargs) { raise "boom" }
      tasks = [boom, dispatch_unit(1, [])]

      stderr_output = capture_stderr do
        expect { Timeout.timeout(2) { stagger.call(tasks) } }.to raise_error(RuntimeError, "boom")
      end

      expect(stderr_output).to be_empty
    end
  end

  # AC2 (Gherkin): "the measurement shows the point"
  describe "the measurement shows the point" do
    let(:template) { "Shared sibling brief, the bulk every worker reads first. " * 80 }
    let(:factory_context) { Lain::Context.new(model: "child-model", max_tokens: 512) }
    let(:strategy) { Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate.new(template:) }
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:store) { Lain::Store.new }

    # Four real sibling-template Requests -- byte-identical system/tools,
    # one per-child task riding in messages -- built the same way
    # {Subagent#spawn_agent} shapes a child's Context and {Context#render}s
    # it, without driving a whole Agent loop: this card measures dispatch
    # ORDERING, not the subagent tool itself (C2's own spec already proves
    # the byte-identity of the prefix end to end).
    def sibling_requests(tasks)
      shaped = strategy.child_context(factory_context)
      tasks.map do |task|
        timeline = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => task }])
        shaped.render(timeline:, toolset:)
      end
    end

    let(:requests) { sibling_requests(%w[alpha-task beta-task gamma-task delta-task]) }

    # The SYSTEM_PREFIX entry of the chain (Request::SYSTEM_PREFIX, -1) is
    # the shared template's own digest -- position -1 always precedes every
    # per-child message, so it is the one entry every sibling's chain can
    # possibly share.
    def prefix_head(request) = request.prefix_digests.to_h.fetch(-1)

    # `release`, when given, is a shared {Lain::Promise} the unit parks on
    # AFTER logging its own dispatch and BEFORE it may signal
    # `stream_started` -- the barrier the "unstaggered control" test below
    # needs: an unresolved Promise blocks unconditionally (unlike a bare
    # `Async::Task.current.yield`, which only cedes one scheduler tick and
    # gives no guarantee every sibling has already dispatched by the time it
    # resumes). With no `release`, the unit signals immediately, which is
    # exactly the shape {Stagger} itself drives sibling 1 through.
    def dispatch_unit_for(index, request, log, release: nil)
      lambda do |on_stream_started:|
        digest = prefix_head(request)
        log << [:dispatch, index, digest]
        release&.await
        on_stream_started.call(digest)
        log << [:stream_started, index, digest]
        request
      end
    end

    # A dispatch is a READ of its prefix iff an EARLIER dispatch shares the
    # same byte-identical prefix digest and had already reached
    # `stream_started` (CE-5: the earliest point its cache write becomes
    # probe-able) by the time THIS one started -- otherwise it is a WRITE.
    # Purely a function of the observed chronological log, so the SAME
    # classifier reads both runs below; only the observed order differs.
    # This is the demo table CE-5's acceptance criterion asks for.
    def demo_table(log)
      opened = Set.new
      log.each_with_object([]) do |(event, index, digest), rows|
        rows << [index, opened.include?(digest) ? :read : :write] if event == :dispatch
        opened << digest if event == :stream_started
      end
    end

    it "confirms the fixture's siblings share one writable template chain head" do
      heads = requests.map { |request| prefix_head(request) }

      expect(heads.uniq.size).to eq(1)
    end

    it "shows the staggered run as 1 write + N-1 byte-identical reuses" do
      log = []
      tasks = requests.each_with_index.map { |request, i| dispatch_unit_for(i, request, log) }

      described_class.new(journal: []).call(tasks)
      table = demo_table(log)

      expect(table.first).to eq([0, :write])
      expect(table.count { |_index, kind| kind == :write }).to eq(1)
      expect(table.count { |_index, kind| kind == :read }).to eq(3)
    end

    # The control's task shape deliberately does NOT gate on Stagger, or on
    # anything about a sibling's stream_started -- true simultaneous dispatch
    # (CE-5's premise: "fan out N siblings simultaneously and all N pay full
    # prefill"). The barrier below (`release`) only holds every sibling at
    # "dispatched, not yet streaming" until ALL FOUR have reached that point,
    # which is what makes "simultaneous" a guarantee rather than a hopeful
    # race against reactor fairness -- an unresolved {Lain::Promise} parks a
    # fiber unconditionally, so none can slip past to signal early.
    it "shows the unstaggered control as N independent first-dispatches" do
      log = []
      release = Lain::Promise.new
      tasks = requests.each_with_index.map { |request, i| dispatch_unit_for(i, request, log, release:) }

      Sync do |root|
        handles = tasks.map { |task| root.async { task.call(on_stream_started: ->(_digest) {}) } }
        release.resolve(true)
        handles.map(&:wait)
      end
      table = demo_table(log)

      expect(table.count { |_index, kind| kind == :write }).to eq(4)
      expect(table.count { |_index, kind| kind == :read }).to eq(0)
    end
  end
end
