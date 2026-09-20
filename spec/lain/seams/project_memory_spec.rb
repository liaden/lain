# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# One project memory store, and each session's own view of it. Driven through
# the production wiring -- {Lain::CLI::Wiring#run_state} builds the view,
# {Lain::SessionRecord::Replay#memory} rebuilds a recorded one -- over a real
# `$XDG_STATE_HOME`, because the store IS a file and what is under test is what
# crosses between two chats through it.
#
# The other half of the boundary is pinned here too: a compaction cut is a
# derived view of one chat's own history, and committing one must leave the
# project's durable memory untouched.
RSpec.describe "Project memory across chats", :seam do
  around do |example|
    Dir.mktmpdir("lain-project-memory") do |dir|
      @home = dir
      example.run
    end
  end

  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => @home, "HOME" => @home })

  def store = Lain::Memory::ProjectStore.new(project_dir: Lain::ProjectDir.new(root: @home, paths:))

  def item(id, body = "body of #{id}")
    Lain::Memory::Item.new(id:, description: "about #{id}", body:)
  end

  def write_call(tool_use_id, memory_item)
    [tool_use_id, "memory_write",
     { "id" => memory_item.id, "description" => memory_item.description, "body" => memory_item.body }]
  end

  # The production assembly, at the project this spec's state home belongs to.
  # A REAL status feed, publishing under the same temporary state home: nothing
  # on the memory path reads it, and a double would be the one stand-in in a
  # seam that is about real components meeting.
  def wiring(chronicle)
    Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                          status_feed: Lain::StatusFeed.new(path: File.join(@home, "state.json")),
                          paths:, project: Lain::Project.new(root: @home, cwd: @home, kind: :project,
                                                             detected_by: :flag))
  end

  def chronicle_over(io) = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:))

  # One chat, start to close: the real view, the real journal decoration, the
  # real memory_write tool, and the recorded NDJSON it leaves behind.
  def chat(responses, io: StringIO.new, resumed: nil)
    chronicle = chronicle_over(io)
    recorder, session = wiring(chronicle).run_state(resumed)
    toolset = Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:)])
    context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024)
    chronicle.start(context:, toolset:, **resumed_start(resumed))
    provider = Lain::Provider::Mock.new(responses:)
    agent = Lain::Agent.new(provider:, context:, toolset:, session:,
                            journal: Lain::Memory::JournalMemoryRoot.new(journal: chronicle.durable_journal,
                                                                         recorder:),
                            timeline: resumed&.timeline || Lain::Timeline.empty)
    agent.ask("go")
    chronicle.catch_up(agent.timeline)
    { io:, provider:, agent:, session:, recorder:, chronicle: }
  end

  # What CLI::Wiring passes the chronicle for a resumed run: the file it
  # continues and the digests already written, so the scribe appends rather
  # than re-recording the chain it inherited.
  def resumed_start(resumed)
    return {} if resumed.nil?

    { resumed_from: { "file" => "first.ndjson", "head" => resumed.timeline.head_digest },
      written: resumed.timeline.to_a.map(&:digest) }
  end

  # The value CLI::Resume hands Wiring#run: the replayed view and session, plus
  # the rebuilt timeline, which rides separately.
  def resumption(io)
    replayed = replay(io)
    Struct.new(:recorder, :session, :notices, :timeline)
          .new(replayed.memory, replayed.session, [],
               Lain::Bench::Session::Loader.new(io.string.each_line).recording.timeline)
  end

  def manifest_of(run) = run.fetch(:provider).requests.map { |request| request.cache_payload.to_s }.join

  def records(io) = io.string.each_line.map { |line| JSON.parse(line) }

  def replay(io) = Lain::SessionRecord::Replay.new(records(io))

  # What `/rewind` does, in its own order: journal the move, then move.
  def rewind(run, count = nil)
    before = run.fetch(:agent).timeline
    count ||= before.length
    run.fetch(:chronicle).catch_up(before)
    run.fetch(:chronicle).rewound(to: before.rewind(count).head_digest)
    run.fetch(:agent).rewind(count)
  end

  let(:done) { text_response("done") }

  describe "a fresh chat over an earlier chat's writes" do
    it "renders the earlier chat's item in its first request's manifest" do
      chat([tool_response(write_call("tu_1", item("db-conventions"))), done])

      fresh = chat([done])
      expect(manifest_of(fresh)).to include("db-conventions")
    end

    it "keeps the item in the store where a later chat still finds it" do
      chat([tool_response(write_call("tu_1", item("db-conventions"))), done])

      expect(store.load.items.map(&:id)).to eq(["db-conventions"])
    end
  end

  # A session's view is a snapshot. Another chat writing into the store while
  # this one runs must not move what this one renders, or what its already
  # recorded memory_root values verify against.
  describe "another chat's write mid-session" do
    it "leaves this session's manifest and its recorded roots alone" do
      io = StringIO.new
      chronicle = chronicle_over(io)
      recorder, session = wiring(chronicle).run_state(nil)
      store.view.write(item("other"))

      expect(session.reminders.join).not_to include("other")
      expect(recorder.index).to be_empty
      expect { Lain::Bench::Session::MemoryReplay.new(records: records(io)).recorded_memory }.not_to raise_error
    end
  end

  describe "a resume of a chat that wrote memory" do
    it "renders the recorded manifest and verifies every recorded root" do
      first = chat([tool_response(write_call("tu_1", item("kept"))), done])

      second = chat([done], resumed: resumption(first.fetch(:io)))
      expect(manifest_of(second)).to include("kept")
      expect { Lain::Bench::Session::MemoryReplay.new(records: records(second.fetch(:io))).recorded_memory }
        .not_to raise_error
    end

    it "does not pick up what another chat wrote in between" do
      first = chat([tool_response(write_call("tu_1", item("kept"))), done])
      store.view.write(item("elsewhere"))

      second = chat([done], resumed: resumption(first.fetch(:io)))
      expect(manifest_of(second)).not_to include("elsewhere")
    end
  end

  # The view follows the chain, LIVE as well as on replay. A session that keeps
  # going after the rewind is the shape a human actually produces, and the one
  # where a live view that did not follow would go on showing the model a
  # memory its own record says is gone -- then render something else entirely
  # after a resume.
  describe "a rewind past a memory_write, and the session that continues" do
    # Write a memory, rewind past the turn that wrote it, then ask again.
    def rewound_run
      chat([tool_response(write_call("tu_1", item("tmp-note"))), done, done]).tap do |run|
        rewind(run)
        run.fetch(:agent).ask("carry on")
        run.fetch(:chronicle).catch_up(run.fetch(:agent).timeline)
      end
    end

    it "stops rendering the memory the chain no longer carries" do
      run = rewound_run

      expect(run.fetch(:session).reminders.join).not_to include("tmp-note")
      expect(run.fetch(:provider).requests.last.messages.to_s).not_to include("tmp-note")
    end

    it "replays to exactly the view the live session rendered" do
      run = rewound_run
      rebuilt = replay(run.fetch(:io)).memory

      expect(rebuilt.index.map(&:id)).to eq(run.fetch(:recorder).index.map(&:id))
    end

    # No root is exempted after a rewind: the replay reproduces the ones the
    # abandoned branch recorded from that branch's own ancestry.
    it "still reproduces every memory_root the file records" do
      parsed = records(rewound_run.fetch(:io))
      replayed = Lain::Bench::Session::MemoryReplay.new(records: parsed).recorded_memory

      unmatched = parsed.select { |record| record["type"] == "memory_root" }
                        .reject { |record| replayed.roots[record.fetch("turn_digest")] == record.fetch("root") }
      expect(unmatched).to be_empty
    end

    it "keeps the rewound entry in the store, where the next fresh chat sees it" do
      rewound_run

      expect(store.load.items.map(&:id)).to eq(["tmp-note"])
      expect(manifest_of(chat([done]))).to include("tmp-note")
    end
  end

  # THE SECOND RESUME. A resumed chat opens on the view its own record names,
  # rewinds inside itself, and is resumed again: every file of the chain has to
  # fold against its own seed, and the live view has to land where the replay
  # puts it, or the session is lost.
  describe "a resumed chat that rewinds, and is resumed again" do
    def first_run = chat([tool_response(write_call("tu_1", item("kept"))), done])

    # Back to the inherited head -- two turns, so the rewind does not land on a
    # stranded user prompt, which the next ask would FOLD rather than extend
    # (that path is `Repl::Ask#resending`'s, and a different record).
    def resumed_then_rewound(first)
      chat([done, done], resumed: resumption(first.fetch(:io))).tap do |run|
        rewind(run, 2)
        run.fetch(:agent).ask("carry on")
        run.fetch(:chronicle).catch_up(run.fetch(:agent).timeline)
      end
    end

    it "stands on the seed after the rewind, folding the inherited write once" do
      second = resumed_then_rewound(first_run)
      seeded = Lain::Memory::ProjectStore::Loaded.of([item("kept")]).index

      expect(second.fetch(:recorder).index.root).to eq(seeded.root)
      expect(second.fetch(:recorder).index.to_h.keys).to eq(["kept"])
    end

    it "stays resumable, chain and all" do
      first = first_run
      second = resumed_then_rewound(first)
      chain = records(first.fetch(:io)) + records(second.fetch(:io))

      expect { Lain::SessionRecord::Replay.new(chain).memory }.not_to raise_error
      expect { Lain::Bench::Session::MemoryReplay.new(records: chain).recorded_memory }.not_to raise_error
    end

    it "replays the chain to the view the live session stands on" do
      first = first_run
      second = resumed_then_rewound(first)
      chain = records(first.fetch(:io)) + records(second.fetch(:io))

      expect(Lain::SessionRecord::Replay.new(chain).memory.index.root)
        .to eq(second.fetch(:recorder).index.root)
    end
  end

  # Two subsystems, two records, and neither reads the other.
  describe "a committed compaction cut" do
    it "leaves the store's contents exactly as they were" do
      chat([tool_response(write_call("tu_1", item("durable"))), done])
      before = File.binread(store.path)

      Lain::Session.new.record_compaction_cut(
        Lain::Telemetry::CompactionCut.new(
          digest: "blake3:a", head: "blake3:b", strategy: "eager", kind: "advance", parent: nil,
          supersedes: [], plan_step_completions: 0,
          collapses: [{ "span" => %w[blake3:a blake3:b],
                        "content" => [{ "type" => "text",
                                        "text" => "a state document, which is not a memory" }] }]
        )
      )

      expect(File.binread(store.path)).to eq(before)
    end
  end
end
