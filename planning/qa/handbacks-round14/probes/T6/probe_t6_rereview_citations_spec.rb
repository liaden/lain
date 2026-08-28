# frozen_string_literal: true

# T6 RE-REVIEW PROBE -- not in the suite (rake pspec runs `spec` only).
#     bundle exec rspec probe-t6-rereview-citations_spec.rb
#
# The deepest agent PARKS on a question; every agent above it is left with an
# unreturned iteration, so every :spawn edge down the chain cites a head its own
# JournalTurns will never promote. Depth 1 is the card's own shape; 2 and 3 are
# what #spawning_handle has to cover.
require "async"
require "stringio"
require "tmpdir"

RSpec.describe "T6 re-review: citations under a parked question" do
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:union) { Lain::Toolset.new([Lain::Tools::ReadFile.new, EchoTool.new]) }
  let(:child_context) { Lain::Context.new(model: "child-model", max_tokens: 256) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:scribe) do
    Lain::SessionRecord::Scribe.new(journal:, context: Lain::Context.new(model: "m", max_tokens: 8),
                                    toolset: union, workspace: Lain::Workspace.empty)
  end
  let(:observer) { ->(event) { scribe.call(event) } }
  let(:notifier) { instance_double(Lain::Notify) }
  let(:askers) { Lain::CLI::Wiring::Askers.new(notifier:, observer:) }

  before { allow(notifier).to receive(:question) }

  def mock(*r) = Lain::Provider::Mock.new(responses: r)
  def policy(prefix: :fresh) = Lain::Tool::SpawnPolicy.new(prefix:, posture: :schema, only: [])
  def asks(q = "which db?") = tool_response(["c1", "ask_human", { "question" => q }])

  def subagent(provider, toolset, prefix: :fresh)
    Lain::Tools::Subagent.new(
      seam: Lain::Tools::Subagent::Seam.new(provider:, context_factory: -> { child_context },
                                            parent:, askers:, observer:),
      toolset:, policy: policy(prefix:), max_depth: 6
    )
  end

  def parked_leaf(prefix: :fresh) = subagent(mock(asks, text_response("in")), union, prefix:)

  def tower(spawns_above, prefix: :fresh)
    return parked_leaf(prefix:) if spawns_above.zero?

    inner = tower(spawns_above - 1, prefix:)
    subagent(mock(tool_response(["s", "subagent", { "prompt" => "deeper" }]), text_response("out")),
             Lain::Toolset.new([Lain::Tools::ReadFile.new, inner]), prefix:)
  end

  def run_parked(tool)
    Sync do |task|
      run = task.async { tool.call({ "prompt" => "go" }, invocation) }
      pumped_until(task) { !askers.questions.empty? }
      askers.questions.dequeue
      run.stop
    end
    scribe.catch_up(parent)
    scribe.close(reason: :exit)
    journal_io.string
  end

  # Prints the record table and names every dangling edge, so a failure says
  # WHICH record and WHICH digest rather than only that the load refused.
  def dangling(bytes)
    lines = bytes.each_line.map { |l| JSON.parse(l) }
    have = lines.filter_map { |r| r["digest"] }.to_set
    warn "--- RECORDS ---"
    lines.each_with_index do |r, i|
      next unless %w[turn child_turn message spawn].include?(r["type"])

      warn format("%2d %-11s digest=%s render_parent=%s causal=%s", i, r["type"], r["digest"].to_s[7, 8],
                  r["render_parent"].to_s[7, 8], Array(r["causal_parents"]).map { |d| d.to_s[7, 8] }.inspect)
    end
    lines.each_with_index.flat_map do |r, i|
      edges = Array(r["causal_parents"]) + [r["render_parent"]].compact
      edges.reject { |d| have.include?(d) }.map { |d| "record #{i} (#{r["type"]}) cites missing #{d[7, 12]}" }
    end
  end

  def reopened(bytes)
    Dir.mktmpdir do |state_home|
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home })
      File.write(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"), bytes)
      yield Lain::CLI::Resume.new(paths:)
    end
  end

  def fork_selector = "20260101@#{parent.head_digest.delete_prefix("blake3:")[0, 12]}"

  [1, 2, 3].each do |depth|
    context "with the parked agent #{depth} spawn(s) down" do
      it "leaves no dangling citation, and both doors reopen" do
        bytes = run_parked(tower(depth - 1))

        expect(dangling(bytes)).to be_empty
        reopened(bytes) do |resume|
          expect(resume.fork(selector: fork_selector).timeline.head_digest).to eq(parent.head_digest)
          expect(resume.call.timeline.head_digest).to eq(parent.head_digest)
        end
      end
    end
  end

  it "leaves no dangling citation at depth 2 under the inherit prefix" do
    expect(dangling(run_parked(tower(1, prefix: :inherit)))).to be_empty
  end

  # A grandchild's :spawn and the grandchild's own question must agree about
  # which heads are promoted -- two promote-then-cite sites, one feed each.
  it "cites only promoted heads from BOTH sites at depth 2" do
    bytes = run_parked(tower(1))
    lines = bytes.each_line.map { |l| JSON.parse(l) }
    messages = lines.select { |r| r["type"] == "message" }
    have = lines.filter_map { |r| r["digest"] }.to_set

    expect(messages.size).to be >= 3 # outer spawn, nested spawn, the question
    expect(messages.flat_map { |r| Array(r["causal_parents"]) }).to all(satisfy { |d| have.include?(d) })
  end

  # ---- the shapes that were already green, re-checked ----------------------

  it "carries every cited digest when two siblings park at once" do
    tool = subagent(mock(asks("first?"), asks("second?"), text_response("done")), union)
    Sync do |task|
      a = task.async { tool.call({ "prompt" => "a" }, invocation) }
      b = task.async { tool.call({ "prompt" => "b" }, invocation) }
      pumped_until(task) { askers.questions.size >= 2 }
      [a, b].each(&:stop)
    end
    scribe.catch_up(parent)
    scribe.close(reason: :exit)

    expect(dangling(journal_io.string)).to be_empty
  end

  it "carries every cited digest when a child parks on its SECOND question" do
    tool = subagent(mock(asks("first?"), asks("second?"), text_response("done")), union)
    Sync do |task|
      run = task.async { tool.call({ "prompt" => "go" }, invocation) }
      pumped_until(task) { !askers.questions.empty? }
      askers.directory.reply("postgres", askers.questions.dequeue.digest)
      pumped_until(task) { !askers.questions.empty? }
      askers.questions.dequeue
      run.stop
    end
    scribe.catch_up(parent)
    scribe.close(reason: :exit)

    expect(dangling(journal_io.string)).to be_empty
  end

  it "journals each child turn exactly once on the answered path" do
    tool = subagent(mock(asks, text_response("done")), union)
    Sync do |task|
      run = task.async { tool.call({ "prompt" => "go" }, invocation) }
      pumped_until(task) { !askers.questions.empty? }
      askers.directory.reply("postgres", askers.questions.dequeue.digest)
      run.wait
    ensure
      run.stop
    end
    scribe.close(reason: :exit)

    digests = journal_io.string.each_line.filter_map do |line|
      record = JSON.parse(line)
      record["digest"] if record["type"] == "child_turn"
    end
    warn "PROBE child_turn records: #{digests.size}, distinct: #{digests.uniq.size}"
    expect(digests).to eq(digests.uniq)
  end

  # A spawn REFUSED at the depth ceiling must not settle: nothing is cited, so
  # nothing should be promoted.
  it "does not promote when the spawn is refused at the ceiling" do
    capped = Lain::Tools::Subagent.new(
      seam: Lain::Tools::Subagent::Seam.new(provider: mock(text_response("never")),
                                            context_factory: -> { child_context },
                                            parent:, askers:, observer:),
      toolset: union, policy:, max_depth: 0
    )

    expect(capped.call({ "prompt" => "go" }, invocation)).not_to be_ok
    expect(journal_io.string).to be_empty
  end

  it "reports the new objects' shapes" do
    chain = Lain::Tools::Subagent::ChildBuilder::Chain.new(
      base: parent, timeline: -> { parent },
      feed: Lain::Tools::Subagent::TurnFeed.new(observer: Lain::Event::ChainWriter::Null.new)
    )
    handle = Lain::Tools::AskHuman::Parent.new(read: parent)
    warn "PROBE chain frozen=#{chain.frozen?} shareable=#{Ractor.shareable?(chain)}"
    warn "PROBE parent-handle frozen=#{handle.frozen?} shareable=#{Ractor.shareable?(handle)}"

    # The asker's #timeline leg must NOT settle; the spawn's thunk must.
    settles = []
    settling = Lain::Tools::AskHuman::Parent.new(read: -> { parent }, settle: ->(t) { settles << t.head_digest })
    settling.timeline
    expect(settles).to be_empty
    settling.settled
    expect(settles).to eq([parent.head_digest])
  end
end
