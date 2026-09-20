# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# This spec's fixture, kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ReplaySpecSupport
  # Turns a read of any path ending in "err.rb" into an error result AFTER the
  # tool recorded it, as a result-side middleware may.
  class ErrorOnErr < Lain::Middleware::Base
    def call(env, &app)
      carried = downstream(env, &app)
      path = env.fetch(:effect).input.to_h.transform_keys(&:to_s)["path"].to_s
      path.end_with?("err.rb") ? carried.merge(result: Lain::Tool::Result.error("withheld")) : carried
    end
  end
end

# What a resume does with a committed compaction cut. The summary a model wrote
# for the cut's range lives in {Lain::Compaction::Strategy::Summarizing}'s
# in-memory memo, which a resumed process does not have and which forgets a
# failure -- so the one part of a cut a resume cannot recompute is exactly the
# part the record carries, and the replayed Session is how it reaches the
# Source.
RSpec.describe Lain::SessionRecord::Replay do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:base) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt") }
  let(:clock) { -> { Time.at(1_700_000_000).utc } }

  # Counts its asks and numbers its answers, so a second ask for the same range
  # cannot come back byte-identical by coincidence.
  let(:counting_oracle_class) do
    Class.new do
      attr_reader :asks

      def initialize = (@asks = 0)

      def ask(_inputs = {})
        @asks += 1
        Struct.new(:summary) { def await = self }.new("what the stretch decided (answer #{@asks})")
      end
    end
  end

  def text(index) = { "type" => "text", "text" => "turn #{index}: #{"the lazy dog slept through it. " * 30}" }

  def timeline(size)
    (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
      line.commit(role: index.odd? || index == 2 ? "user" : "assistant", content: [text(index)])
    end
  end

  def source(oracle:, need:, hard_cap:, journal: Lain::Channel::Null.instance)
    Lain::Compaction::Source.new(
      need:, cold: Lain::Compaction::Cold.new(cache_profile: { ttl: 300 }, journal:), hard_cap:, keep_last: 2,
      journal:, clock:, strategy: Lain::Compaction::Strategy::SummarizeConversation.new(oracle:)
    )
  end

  # Plan steps compact and nothing else does, forced even while warm.
  def stepping(oracle, journal)
    source(oracle:, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000), hard_cap: 1, journal:)
  end

  def rendered(built, line, session)
    built.context_for(base:, timeline: line, usage: nil, session:)
         .render(timeline: line, toolset: Lain::Toolset.new([]), workspace: Lain::Workspace.empty)
         .messages
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }

  def todo(content) = Struct.new(:content, :status).new(content, "completed")

  # The same chain, grown to `size` turns under {#timeline}'s roles.
  def grown_to(line, size)
    ((line.length + 1)..size).inject(line) do |chain, index|
      chain.commit(role: index.odd? ? "user" : "assistant", content: [text(index)])
    end
  end

  describe "a committed compaction cut" do
    it "renders the recorded replacement on resume without asking the summarizer again" do
      line = timeline(6)
      recording = Lain::Session.new(journal:)
      recording.write_todos([Struct.new(:content, :status).new("summarize", "completed")])
      recorded_oracle = counting_oracle_class.new
      recorded = rendered(source(oracle: recorded_oracle, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
                                 hard_cap: 1, journal:), line, recording)
      resumed_oracle = counting_oracle_class.new
      resumed_source = source(oracle: resumed_oracle, need: Lain::Compaction::Need.new(byte_threshold: 1_000_000),
                              hard_cap: 1_000_000)

      resumed = rendered(resumed_source, line, described_class.new(journal_io.string.each_line).session)

      expect(records.map { |record| record["type"] }).to include("compaction_cut")
      expect(recorded_oracle.asks).to eq(1)
      expect(Lain::Canonical.dump(resumed.first)).to eq(Lain::Canonical.dump(recorded.first))
      expect(resumed.size).to eq(recorded.size)
      expect(resumed_oracle.asks).to eq(0)
    end

    # The plan-step latch is part of what a cut records: the completions a
    # commit consumed. A resume that forgot it would fire the step again, ask
    # the summarizer, and commit a cut the recording never made.
    it "does not fire a plan step the recording already consumed, at a head with history past the cut" do
      line = timeline(8)
      recording = Lain::Session.new(journal:)
      recording.write_todos([Struct.new(:content, :status).new("summarize", "completed")])
      recorder = stepping(counting_oracle_class.new, journal)
      rendered(recorder, line, recording)
      grown = %w[user assistant].each_with_index.inject(line) do |chain, (role, index)|
        chain.commit(role:, content: [text(9 + index)])
      end
      recorded = rendered(recorder, grown, recording)
      resumed_oracle = counting_oracle_class.new
      resumed_session = described_class.new(journal_io.string.each_line).session

      resumed = rendered(stepping(resumed_oracle, Lain::Channel::Null.instance), grown, resumed_session)

      expect(resumed_oracle.asks).to eq(0)
      expect(resumed_session.compaction_cuts.size).to eq(1)
      expect(Lain::Canonical.dump(resumed)).to eq(Lain::Canonical.dump(recorded))
    end

    # A collapse re-summarizes the held replacements, and the record is the
    # only place that second summary survives: a resume must render it from
    # there, and must hold it alone, not beside the cuts it superseded.
    it "renders a collapse of held cuts byte-identically on resume, without asking the summarizer" do
      recording = Lain::Session.new(journal:)
      recorder = stepping(counting_oracle_class.new, journal)
      completed = 0
      step = lambda do |line|
        completed += 1
        recording.write_todos(Array.new(completed) { |index| todo("step #{index}") })
        rendered(recorder, line, recording)
      end
      line = [6, 8, 10, 12].inject(timeline(4)) do |grown, size|
        grown = grown_to(grown, size)
        step.call(grown)
        grown
      end
      live = step.call(line)
      resumed_oracle = counting_oracle_class.new
      resumed_session = described_class.new(journal_io.string.each_line).session

      resumed = rendered(stepping(resumed_oracle, Lain::Channel::Null.instance), line, resumed_session)

      cuts = resumed_session.compaction_cuts
      expect(cuts.map(&:kind)).to eq(%w[advance advance advance advance collapse])
      expect(cuts.last.supersedes).to eq(cuts.first(4).map(&:address))
      expect(resumed_oracle.asks).to eq(0)
      expect(Lain::Canonical.dump(resumed)).to eq(Lain::Canonical.dump(live))
    end

    # A collapse names the cuts it replaces by address, as a child names its
    # parent; one the record does not hold would render a seam missing ranges.
    it "refuses a collapse superseding a cut the record does not hold, as a corrupt session record" do
      writer = Lain::Session.new(journal:)
      parent = %w[blake3:one blake3:two].inject(nil) do |previous, digest|
        cut = Lain::Telemetry::CompactionCut.new(digest:, head: digest, strategy: "eager", kind: "advance",
                                                 parent: previous, supersedes: [], plan_step_completions: 0,
                                                 collapses: [{ "span" => [digest, digest], "content" => [] }])
        writer.record_compaction_cut(cut)
        cut.address
      end
      writer.record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(digest: "blake3:two", head: "blake3:two", strategy: "eager",
                                           kind: "collapse", parent:, supersedes: ["blake3:lost", parent],
                                           plan_step_completions: 0,
                                           collapses: [{ "span" => %w[blake3:one blake3:two], "content" => [] }])
      )

      expect { described_class.new(journal_io.string.each_line).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /supersedes.*blake3:lost/)
    end

    it "folds every cut in recorded order, parent before child" do
      writer = Lain::Session.new(journal:)
      %w[blake3:one blake3:two].inject(nil) do |parent, digest|
        cut = Lain::Telemetry::CompactionCut.new(digest:, head: digest, strategy: "eager", kind: "advance", parent:,
                                                 supersedes: [], plan_step_completions: 0,
                                                 collapses: [{ "span" => [digest, digest], "content" => [] }])
        writer.record_compaction_cut(cut)
        cut.address
      end

      expect(described_class.new(journal_io.string.each_line).session.compaction_cuts)
        .to eq(writer.compaction_cuts)
    end

    # A truncated or hand-edited file that lost a parent is a seam with a hole
    # in it; folding the child anyway would render the wrong replacement. It
    # is refused as a corrupt session record, which resume and fork already
    # report as "cannot resume <file>".
    it "refuses a cut whose parent the record does not hold, as a corrupt session record" do
      Lain::Session.new(journal:).record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(digest: "blake3:one", head: "blake3:one", strategy: "eager",
                                           kind: "advance", parent: nil, supersedes: [], plan_step_completions: 0,
                                           collapses: [{ "span" => %w[blake3:one blake3:one], "content" => [] }])
      )
      orphaned = journal_io.string.each_line.map { |line| JSON.parse(line).merge("parent" => "blake3:lost") }

      expect { described_class.new(orphaned).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /record chain is incomplete.*blake3:lost/)
    end

    it "replays a record with no cut to a session holding none" do
      Lain::Session.new(journal:).record_read("/tmp/a.rb")

      expect(described_class.new(journal_io.string.each_line).session.compaction_cuts).to eq([])
    end
  end

  # A read counts on a resumed chain exactly when it counted on the recorded
  # one: the record carries each read's call, the recorded turns say which turn
  # delivered it, and the resumed agent asks about the chain it resumed onto.
  describe "reads, against the chain the session resumes onto", :seam do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new]) }
    let(:scribe) { Lain::SessionRecord::Scribe.new(journal:, context: base, toolset:) }

    around do |example|
      Dir.mktmpdir("lain-replay-reads") do |dir|
        @path = File.join(dir, "notes.rb")
        File.write(@path, "line 1\nline 2\n")
        example.run
      end
    end

    attr_reader :path

    def agent(responses, **rest)
      Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), toolset:, context: base, **rest)
    end

    def edit
      tool_response(["tu_edit", "edit_file", { "path" => path, "old_string" => "line 2", "new_string" => "two" }])
    end

    # The recorded chat: one whole read of notes.rb, every turn and read in
    # the session file as the chat's own scribe writes them.
    def recorded
      read = tool_response(["tu_read", "read_file", { "path" => path }])
      scribe # its header opens the file, ahead of every read, as a chat's does
      agent([read, text_response("read")], session: Lain::Session.new(journal:)).tap do |run|
        run.ask("read notes.rb")
        scribe.catch_up(run.timeline)
      end
    end

    def resume_and_edit
      lines = journal_io.string.each_line.to_a
      resumed = agent([edit, text_response("tried")], session: described_class.new(lines).session,
                                                      timeline: Lain::Bench::Session.load(lines).timeline)
      resumed.ask("edit it")
      resumed.timeline.ancestors.flat_map(&:content).find { |block| block["tool_use_id"] == "tu_edit" }
    end

    it "refuses an edit when the session's only whole read was rewound away before it was saved" do
      run = recorded
      scribe.rewound(to: run.rewind(run.timeline.length).timeline.head_digest)

      expect(resume_and_edit).to include("is_error" => true, "content" => a_string_including("was never read"))
      expect(File.read(path)).to eq("line 1\nline 2\n")
    end

    it "allows the edit when that read's delivering turn is still on the resumed chain" do
      recorded

      expect(resume_and_edit).to include("is_error" => false)
      expect(File.read(path)).to eq("line 1\ntwo\n")
    end

    # A release is evidence that bytes were sent, not a mask: folded as one, a
    # resumed session would refuse the edit its read earned. Nor does it restore
    # the release, so the resumed run asks again before sending the secret.
    it "does not resume a recorded release as a mask, so the edit its read earned is allowed" do
      recorded
      journal << Lain::Telemetry::ReadReleased.new(tool_use_id: "tu_read", path:, regions: 2, requester: "agent",
                                                   surface: "tty")

      expect(resume_and_edit).to include("is_error" => false)
      expect(File.read(path)).to eq("line 1\ntwo\n")
    end

    it "withholds a read no recorded turn delivered, as a round torn before its results landed" do
      Lain::Session.new(journal:).record_read(path, tool_use_id: "tu_torn")

      expect(described_class.new(journal_io.string.each_line).session.read?(path)).to be(false)
    end

    it "refuses a read record whose span names no lines, as a corrupt session record" do
      Lain::Session.new(journal:).record_read(path, lines: 3..9)
      bogus = journal_io.string.each_line.map { |line| JSON.parse(line).merge("lines" => [0, nil]) }

      expect { described_class.new(bogus).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /session_read record .* cannot be rebuilt.*lines must be/)
    end

    # Every session file written before reads carried spans holds this shape.
    # It does not resume -- but it is refused as the damage it is, which both
    # doors turn into "cannot resume <file>", never a raw KeyError.
    it "refuses a read record written before reads carried spans, as a corrupt session record" do
      old = [{ "type" => "session_read", "path" => "/tmp/a.rb", "complete" => true }]

      expect { described_class.new(old).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /before reads carried line spans/)
    end

    it "refuses a withheld-round marker that names no round, as a corrupt session record" do
      expect { described_class.new([{ "type" => "session_read_withheld", "rounds" => [["h", nil]] }]).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /session_read_withheld record cannot be rebuilt/)
    end

    it "refuses a read record whose file version cannot be rebuilt, as a corrupt session record" do
      bad = [{ "type" => "session_read", "path" => "/tmp/a.rb", "lines" => [1, nil], "identity" => {},
               "tool_use_id" => nil, "head" => nil }]

      expect { described_class.new(bad).session }
        .to raise_error(Lain::Bench::Session::Corrupt, /identity must carry exactly/)
    end
  end

  # The live read-set against the one a replay rebuilds. Ollama numbers each
  # response's calls from zero, so one id arrives round after round, and a
  # session file holds rounds that never delivered: a torn round a resume
  # repairs with a turn written after the next round's reads, a stranded
  # answer, a parent file in a resume chain. A read binds to the turn that
  # answers its call FROM THE HEAD ITS ROUND OPENED ON, live and on replay.
  describe "a replay binding reads as the live session did", :seam do
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "sys") }
    let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new]) }
    let(:scribe) { Lain::SessionRecord::Scribe.new(journal:, context:, toolset:) }
    let(:names) { %w[a b c err d e] }
    let(:store) { Lain::Store.new }
    let(:root) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }]) }

    around do |example|
      Dir.mktmpdir("lain-replay-binding") do |dir|
        @dir = dir
        names.each { |name| File.write(file(name), (1..10).map { |i| "#{name}#{i}\n" }.join) }
        example.run
      end
    end

    def file(name) = File.join(@dir, "#{name}.rb")

    # One response of parallel reads, numbered from zero the way Ollama does.
    def reads(*calls)
      tool_response(*calls.each_with_index.map do |(name, window), index|
        ["ollama-tool-#{index}", "read_file", { "path" => file(name) }.merge((window || {}).transform_keys(&:to_s))]
      end)
    end

    def asking(timeline, marker)
      timeline.commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "ollama-tool-0",
                                                    "name" => "read_file", "input" => { "x" => marker } }])
    end

    def answering(asked, is_error: false)
      asked.commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "ollama-tool-0",
                                            "content" => "bytes", "is_error" => is_error }])
    end

    # One live round: opened on `asked`, one read, delivered by the next turn.
    def live_round(session, asked, name)
      session.on_chain(asked)
      session.record_read(file(name), tool_use_id: "ollama-tool-0")
      answering(asked).tap do |delivered|
        session.record_delivery(digest: delivered.head_digest, parent: asked.head_digest,
                                content: delivered.head.content)
      end
    end

    def header(from) = { "type" => "session", "resumed_from" => { "file" => "earlier.ndjson", "head" => from } }

    def live_agent(responses, session)
      agent = nil
      turns = Lain::Middleware::Stack.new([Lain::Middleware::JournalTurns.new(scribe:,
                                                                              timeline: -> { agent.timeline })])
      agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), toolset:, context:, session:,
                              turn_middleware: turns,
                              tool_middleware: Lain::Middleware::Stack.new([ReplaySpecSupport::ErrorOnErr.new]))
    end

    def disagreements(live, timeline, heads)
      sessions = [live.withhold_undelivered, described_class.new(journal_io.string.each_line).session]
      heads.flat_map { |head| head.ancestors.map(&:digest) }.uniq.filter_map do |digest|
        differing = differing_at(sessions, timeline.checkout(digest))
        [digest, differing] unless differing.empty?
      end
    end

    def differing_at(sessions, at)
      sessions.each { |session| session.on_chain(at) }
      names.reject { |name| sessions.map { |session| answers(session, name) }.uniq.one? }
    end

    def answers(session, name) = [session.read?(file(name)), session.partially_read?(file(name))]

    it "agrees with the live session at every head: parallel reads, reused ids, an errored read, rewind, re-read" do
      session = Lain::Session.new(journal:)
      run = live_agent([reads(["a"], ["b", { offset: 1, limit: 5 }]), text_response("r1"),
                        reads(["b", { offset: 6 }], ["err"]), reads(["c"], ["d", { offset: 1, limit: 3 }]),
                        text_response("r2"), reads(["c"], ["e"]), text_response("r3")], session)
      heads = %w[one two].map { |prompt| run.ask(prompt).then { run.timeline } }
      scribe.catch_up(run.timeline)
      scribe.rewound(to: run.rewind(5).timeline.head_digest)
      # The rewind lands on the prompt "two", which nothing on this chain
      # answers, so "three" folds into it and the record trades it for the
      # folded turn, as the chat's ask does.
      run.ask("three", on_fold: ->(stranded, folded) { scribe.replaced(to: stranded.head.parent, with: folded) })

      expect(disagreements(session, run.timeline, [*heads, run.timeline])).to eq([])
    end

    # A resume chain concatenates every file, oldest first. A parent file
    # ending in a round that never delivered -- killed mid-round, or still
    # running in another pane -- must not lend its read to the child's round.
    it "does not let a parent file's undelivered read bind to a child file's turn with a reused id" do
      parent_io = StringIO.new
      parent = Lain::Session.new(journal: Lain::Journal.new(io: parent_io))
      parent.on_chain(asking(root, 0))
      parent.record_read(file("a"), tool_use_id: "ollama-tool-0")
      child = Lain::Session.new(journal:)
      asked = asking(root, 1)
      delivered = live_round(child, asked, "b")
      [asked, delivered].each { |turn| journal << Lain::SessionRecord.turn(turn.head) }
      lines = parent_io.string.lines + ["#{JSON.generate(header(root.head_digest))}\n"] + journal_io.string.lines

      replayed = described_class.new(lines).session.on_chain(delivered)

      expect([replayed.read?(file("b")), replayed.read?(file("a"))]).to eq([true, false])
    end

    # A round whose results could not be committed leaves its read open; the
    # next ask answers the stranded head without telling the session, and that
    # answer is written after the next round's reads.
    it "replays a read delivered after a stranded answer the way the live session counted it" do
      session = Lain::Session.new(journal:)
      stuck = asking(root, 1)
      session.on_chain(stuck)
      session.record_read(file("a"), tool_use_id: "ollama-tool-0")
      journal << Lain::SessionRecord.turn(stuck.head)
      stranded = stuck.commit(role: :user, content: Lain::Tool::Cancellation.new(stuck.head, kind: :unknown).blocks)
      asked = asking(stranded.commit(role: :user, content: [{ "type" => "text", "text" => "again" }]), 2)
      delivered = live_round(session, asked, "b")
      delivered.ancestors.take(4).reverse_each { |turn| journal << Lain::SessionRecord.turn(turn) }
      session.on_chain(delivered)

      replayed = described_class.new(journal_io.string.each_line).session.on_chain(delivered)

      expect([session.read?(file("b")), session.read?(file("a"))]).to eq([true, false])
      expect([replayed.read?(file("b")), replayed.read?(file("a"))]).to eq([true, false])
    end

    # The common shape: a chat killed mid-round is resumed, and the load-time
    # repair answering the torn call is written by the first catch_up -- after
    # the resumed chat's first round has already written its reads.
    it "keeps a resumed chat's first-round read counting on the next resume, past a torn round's repair" do
      torn_io = StringIO.new
      torn = asking(root, 1)
      killed = Lain::Session.new(journal: Lain::Journal.new(io: torn_io))
      [root, torn].each { |turn| torn_io << "#{JSON.generate(Lain::SessionRecord.turn(turn.head))}\n" }
      killed.on_chain(torn)
      killed.record_read(file("a"), tool_use_id: "ollama-tool-0")
      resumed = described_class.new(torn_io.string.lines).session.journals_into(journal)
      repair = torn.commit(role: :user, content: Lain::Tool::Cancellation.new(torn.head, kind: :unknown).blocks)
      asked = asking(repair.commit(role: :user, content: [{ "type" => "text", "text" => "again" }]), 2)
      delivered = live_round(resumed, asked, "b")
      delivered.ancestors.take(4).reverse_each { |turn| journal << Lain::SessionRecord.turn(turn) }
      lines = torn_io.string.lines + ["#{JSON.generate(header(torn.head_digest))}\n"] + journal_io.string.lines

      again = described_class.new(lines).session.on_chain(delivered)

      expect([resumed.on_chain(delivered).read?(file("b")), again.read?(file("b"))]).to eq([true, true])
    end

    # A round on head A that commits nothing, then the byte-identical A
    # re-running its tools -- a resend with a deterministic model -- over a file
    # that changed in between. The live session withholds the first round when
    # the second opens; the record says so, and a replay folds it, so the stale
    # window cannot add up with an older version's windows on either side.
    it "does not count a no-commit round's read when the same head re-runs its tools, live or replayed" do
      old = Lain::Session::FileIdentity.new(device: 1, inode: 1, size: 1, mtime: 1)
      path = file("a")
      session = Lain::Session.new(journal:)
      bottom = asking(root, 0)
      session.on_chain(bottom)
      session.record_read(path, lines: 6.., identity: old, tool_use_id: "ollama-tool-0")
      delivered = answering(bottom)
      session.record_delivery(digest: delivered.head_digest, parent: bottom.head_digest,
                              content: delivered.head.content)
      asked = asking(delivered.commit(role: :user, content: [{ "type" => "text", "text" => "top" }]), 1)
      session.on_chain(asked)
      session.record_read(path, lines: 1..5, identity: old, tool_use_id: "ollama-tool-0")
      session.on_chain(asked)
      session.record_read(path, lines: 1..5, identity: old.with(size: 2, mtime: 2), tool_use_id: "ollama-tool-0")
      rerun = answering(asked)
      session.record_delivery(digest: rerun.head_digest, parent: asked.head_digest, content: rerun.head.content)
      rerun.ancestors.take(5).reverse_each { |turn| journal << Lain::SessionRecord.turn(turn) }

      replayed = described_class.new(journal_io.string.each_line).session

      expect([session, replayed].map { |side| side.on_chain(rerun).read?(path) }).to eq([false, false])
    end
  end

  # The project-memory view a resume renders from: the `memory_loaded` record
  # seeds it, the recorded memory_write turns fold onto it, and a `rewound`
  # record decides which of them the chain still carries.
  describe "the memory view it rebuilds" do
    def item(id) = Lain::Memory::Item.new(id:, description: "about #{id}", body: "body of #{id}")

    def loaded_record(*items)
      Lain::Telemetry::MemoryLoaded.of(Lain::Memory::ProjectStore::Loaded.of(items)).to_journal
    end

    def write_turn(digest, id, parent: nil)
      { "type" => "turn", "digest" => digest, "parent" => parent,
        "content" => [{ "type" => "tool_use", "id" => "tu_#{id}", "name" => "memory_write",
                        "input" => { "id" => id, "description" => "about #{id}", "body" => "body of #{id}" } }] }
    end

    def answered(digest, id, parent:)
      { "type" => "turn", "digest" => digest, "parent" => parent,
        "content" => [{ "type" => "tool_result", "tool_use_id" => "tu_#{id}", "is_error" => false }] }
    end

    let(:recorded) do
      [{ "type" => "session" }, loaded_record(item("seeded")),
       write_turn("d1", "written"), answered("d2", "written", parent: "d1")]
    end

    it "renders the seeded items and the chain's own writes in the session's manifest" do
      replayed = described_class.new(recorded)

      expect(replayed.memory.index.to_h.keys).to contain_exactly("seeded", "written")
      expect(replayed.session.reminders.join).to include("seeded", "written")
    end

    it "drops a write the chain was rewound past" do
      replayed = described_class.new(recorded + [{ "type" => "rewound", "from" => "d2", "to" => nil }])

      expect(replayed.memory.index.to_h.keys).to eq(["seeded"])
    end

    # The SEED rides on the recorder, not just the folded index: a caller
    # holding a chain shorter than the recorded one -- a `/fork` below a
    # memory_write -- re-folds from it, and a recorder that had forgotten what
    # it opened on would reseed from nothing and drop what the session
    # inherited.
    it "carries the seed the chain opened on" do
      expect(described_class.new(recorded).memory.loaded.items.map(&:id)).to eq(["seeded"])
    end

    it "carries no store, so rebuilding a record writes nothing durable" do
      rebuilt = described_class.new(recorded).memory
      rebuilt.write(item("late"))

      expect(rebuilt.index.to_h.keys).to include("late")
      expect(Lain::Memory::ProjectStore::Null.load.items).to be_empty
    end

    it "re-folds to a shorter chain from that seed, dropping what the chain no longer carries" do
      rebuilt = described_class.new(recorded).memory
      rebuilt.follow(Lain::Timeline.empty)

      expect(rebuilt.index.to_h.keys).to eq(["seeded"])
    end

    # THE BOUNDARY of that rule, named rather than left to be discovered: a fork
    # below a write made in an EARLIER file of a resume chain still renders that
    # write, because the newer file's seed already holds it and a seed is where
    # the fold starts. Exact for a write made in the SAME file, which is the
    # case `cli/resume_spec` drives through the real door.
    it "still carries a write the newer file's seed inherited, however short the chain" do
      chain = [{ "type" => "session" }, write_turn("d1", "inherited"),
               answered("d2", "inherited", parent: "d1"), loaded_record,
               { "type" => "session" }, loaded_record(item("inherited")),
               write_turn("d3", "later", parent: "d2"), answered("d4", "later", parent: "d3")]
      rebuilt = described_class.new(chain).memory
      rebuilt.follow(Lain::Timeline.empty)

      expect(rebuilt.index.to_h.keys).to eq(["inherited"])
    end

    it "rebuilds an empty view for a record that carries no memory at all" do
      expect(described_class.new([{ "type" => "session" }]).memory.index).to be_empty
    end
  end
end
