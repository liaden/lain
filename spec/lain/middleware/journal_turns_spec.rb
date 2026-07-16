# frozen_string_literal: true

# T13 fix round (Patterson): per-ITERATION durability. The exe's per-ask
# catch_up loses a SIGKILL'd multi-tool loop's committed turns; this middleware
# tees scribe.catch_up after each turn-phase iteration, so every committed turn
# is on disk before the next model call. The live head is read through a THUNK
# (the exe's `-> { agent.timeline }` idiom), because the turn env's :timeline is
# the PRE-step snapshot -- Agent#run_loop merges response/settled into the env,
# never the moved timeline.
RSpec.describe Lain::Middleware::JournalTurns do
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  let(:timeline) { Lain::Timeline.empty(store:).commit(role: :user, content: text("hi")) }

  # The scribe duck: records every catch_up argument, in call order.
  let(:caught) { [] }
  let(:scribe) do
    seen = caught
    Class.new do
      define_method(:catch_up) { |timeline| seen << timeline }
    end.new
  end

  it "catches the scribe up on the LIVE head after downstream, not the env's pre-step snapshot" do
    live = timeline
    middleware = described_class.new(scribe:, timeline: -> { live })

    result = middleware.call({ iteration: 0, timeline: }) do |env|
      # The step: the timeline moves AFTER the env was built, exactly as
      # Agent#run_loop's step commits after the middleware saw the env.
      live = live.commit(role: :assistant, content: text("yo"))
      env.merge(response: :fake, settled: true)
    end

    expect(caught).to eq([live])
    expect(caught.first.head_digest).not_to eq(timeline.head_digest)
    expect(result.fetch(:settled)).to be(true)
  end

  it "passes the env through untouched -- it observes, it never transforms" do
    middleware = described_class.new(scribe:, timeline: -> { timeline })
    env = { iteration: 3, timeline: }

    result = middleware.call(env) { |inner| inner.merge(settled: false) }

    expect(result).to eq(env.merge(settled: false))
  end

  it "does not catch up when downstream raises -- the interrupted iteration journals nothing new" do
    middleware = described_class.new(scribe:, timeline: -> { timeline })

    expect { middleware.call({ iteration: 0, timeline: }) { raise Lain::Error, "stopped" } }
      .to raise_error(Lain::Error, "stopped")
    expect(caught).to be_empty
  end

  it "composes as a middleware (the monoid surface)" do
    middleware = described_class.new(scribe:, timeline: -> { timeline })
    composed = Lain::Middleware::Identity >> middleware

    composed.call({ timeline: }) { |env| env }

    expect(caught).to eq([timeline])
  end
end
