# frozen_string_literal: true

# Seam spec (plan integration check 5): Context::Compact only shapes the
# RENDERED request -- the request bytes a Provider actually receives -- never
# the Timeline itself. A turn commits its full content regardless of what any
# Context combinator later does to a rendered view of it, and {SessionRecord}
# journals turns straight off the render chain (see {SessionRecord.turn}:
# `turn.content`, not anything Context ever touched). So a compacted
# session's journal -- and a session reloaded from that journal through
# {Bench::Session.load} -- must stay byte-complete even though the provider,
# mid-run, only ever saw the compacted view.
#
# This spec asserts an invariant that already holds by construction: Compact
# lives entirely inside `Context#render`'s pure pipeline, while the Scribe
# and Loader both work off {Lain::Timeline}, which Compact never sees. If this
# ever fails, that is a finding about a lib regression, not something this
# spec should paper over.
RSpec.describe "compaction-retention invariant" do
  # Three long, independently-markered rounds so the LAST rendered request can
  # be checked for exactly which markers a keep_last: 2 / low-threshold Compact
  # would drop -- and the journal can be checked for all of them regardless.
  # Methods, not constants: RuboCop's Lint/ConstantDefinitionInBlock rightly
  # flags a constant assigned inside a `describe` block (it would leak onto
  # the enclosing class the block is `instance_eval`'d against).
  def filler = "x" * 3_000
  def ask1 = "ASK1-#{filler}"
  def reply1 = "REPLY1-#{filler}"
  def ask2 = "ASK2-#{filler}"
  def reply2 = "REPLY2-#{filler}"
  def ask3 = "ASK3-final"
  def reply3 = "REPLY3-final"

  let(:summarizer) { ->(_dropped) { "[compacted]" } }

  # A Context subclass whose pipeline composes Compact ahead of the default
  # Reminder/CacheBreakpoints stages -- the same "swap the pipeline" shape
  # dry_replay_spec and session_spec already use for Prune. threshold: 500 is
  # comfortably under one FILLER-sized message, so any drop candidate that
  # includes a marker message trips it; keep_last: 2 keeps only the trailing
  # pair verbatim.
  let(:compacting_context_class) do
    compact = Lain::Context::Compact.new(threshold: 500, keep_last: 2, summarizer:)
    Class.new(Lain::Context) do
      define_singleton_method(:pipeline) do |workspace|
        compact >> Lain::Context::Reminder.new(workspace:) >> Lain::Context::CacheBreakpoints.new
      end
    end
  end

  let(:context) { compacting_context_class.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def of_type(records, type) = records.select { |record| record["type"] == type }

  it "renders a compacted request to the provider but journals -- and reloads -- the full history" do
    provider = Lain::Provider::Mock.new(responses: [text_response(reply1), text_response(reply2),
                                                    text_response(reply3)])
    agent = Lain::Agent.new(provider:, toolset:, context:, workspace:)

    agent.ask(ask1)
    agent.ask(ask2)
    agent.ask(ask3)

    # 1 & 2: the THIRD render (the request the provider actually completed
    # reply3 against) proves Compact reshaped the view -- round 1 is dropped
    # entirely (outside keep_last: 2, and well over the byte threshold), round
    # 2's ask is dropped too, but its reply survives inside the kept tail.
    rendered_bytes = Lain::Canonical.dump(provider.last_request.messages)
    expect(rendered_bytes).not_to include(ask1)
    expect(rendered_bytes).not_to include(reply1)
    expect(rendered_bytes).not_to include(ask2)
    expect(rendered_bytes).to include(reply2)
    expect(rendered_bytes).to include(ask3)
    expect(rendered_bytes).to include("[compacted]")

    # 3: the journal's `turn` records carry the FULL, uncompacted content of
    # every committed turn -- byte-equal to the Timeline's own turns, which is
    # what SessionRecord.turn journals off (turn.content, never a rendered
    # view).
    scribe = Lain::SessionRecord::Scribe.new(journal:, context:, toolset:, workspace:)
    scribe.catch_up(agent.timeline)
    scribe.close(reason: :exit)

    turn_records = of_type(journal_io.string.each_line.map { |line| JSON.parse(line) }, "turn")
    committed = agent.timeline.to_a

    expect(turn_records.map { |record| record.fetch("content") }).to eq(committed.map(&:content))
    expect(turn_records.map { |record| record.fetch("digest") }).to eq(committed.map(&:digest))

    full_bytes = Lain::Canonical.dump(turn_records.map { |record| record.fetch("content") })
    expect(full_bytes).to include(ask1)
    expect(full_bytes).to include(reply1)
    expect(full_bytes).to include(ask2)
    expect(full_bytes).to include(reply2)
    expect(full_bytes).to include(ask3)
    expect(full_bytes).not_to include("[compacted]")

    # 4: reloading through the Loader rebuilds a byte-complete, digest-verified
    # Timeline -- the log is lossless even though the live view was ever only
    # a view.
    recording = Lain::Bench::Session.load(journal_io.string.each_line.to_a)

    expect(recording.open?).to be(false)
    expect(recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    expect(recording.timeline.to_a.map(&:content)).to eq(committed.map(&:content))
    expect(recording.timeline.to_a.map(&:digest)).to eq(committed.map(&:digest))

    reloaded_bytes = Lain::Canonical.dump(recording.timeline.to_a.map(&:content))
    expect(reloaded_bytes).to include(ask1)
    expect(reloaded_bytes).to include(reply1)
    expect(reloaded_bytes).to include(ask2)
    expect(reloaded_bytes).to include(reply2)
  end
end
