# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Approval::RememberedAllow do
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal:) }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "cargo test" }) }

  def in_dir(cwd, requester: nil)
    session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {}))
    requester ? Lain::Approval::Parked::PolicySwitch::Requested.new(session, requester) : session
  end

  def approved_by_human(context)
    Sync do |task|
      run = task.async { queue.adjudicate(effect, context) }
      task.with_timeout(1) { queue.dequeue }.approve(surface: "spec", authority: :human)
      run.wait
    end
  end

  it "replays the human's allow of the exact call as the human's" do
    approved_by_human(in_dir("/srv/p"))

    ruling = described_class.new(queue:).call(effect, in_dir("/srv/p"))

    expect([ruling.verdict, ruling.authority, ruling.contained?]).to eq([:allow, :human, false])
    expect(ruling.reason).to eq(described_class::REMEMBERED)
  end

  it "answers nothing for the same call from another requester" do
    approved_by_human(in_dir("/srv/p"))

    expect(described_class.new(queue:).call(effect, in_dir("/srv/p", requester: "researcher"))).to be_nil
  end

  it "answers nothing in another directory, or for a call nobody allowed" do
    approved_by_human(in_dir("/srv/p"))
    other = effect.with(input: { "command" => "cargo build" })

    expect([described_class.new(queue:).call(effect, in_dir("/srv/q")),
            described_class.new(queue:).call(other, in_dir("/srv/p"))]).to all(be_nil)
  end

  def reading_secrets(context, holdings: { ".env" => 1 })
    held = Lain::Approval::Disclosure.new(holdings:, sinks: [], unnameable: false)
    SimpleDelegator.new(context).tap { |reading| reading.define_singleton_method(:disclosure) { held } }
  end

  it "answers nothing once the call reads a secret file beyond those the human's yes was shown" do
    approved_by_human(reading_secrets(in_dir("/srv/p")))
    more = reading_secrets(in_dir("/srv/p"), holdings: { ".env" => 1, "config/master.key" => 1 })

    expect(described_class.new(queue:).call(effect, more)).to be_nil
  end

  it "answers nothing once the call reads secrets the human's yes was not shown" do
    approved_by_human(in_dir("/srv/p"))

    expect(described_class.new(queue:).call(effect, reading_secrets(in_dir("/srv/p")))).to be_nil
  end

  it "replays a yes the human gave while the call read secrets" do
    approved_by_human(reading_secrets(in_dir("/srv/p")))

    expect(described_class.new(queue:).call(effect, reading_secrets(in_dir("/srv/p"))))
      .to have_attributes(verdict: :allow, authority: :human)
  end

  it "answers nothing once the call reads a file lain did not scan whole, which the yes was not shown" do
    approved_by_human(in_dir("/srv/p"))
    unscanned = Lain::Approval::Disclosure.new(holdings: {}, sinks: [], unnameable: false, unscanned: ["big.log"])
    big = SimpleDelegator.new(in_dir("/srv/p")).tap { |held| held.define_singleton_method(:disclosure) { unscanned } }

    expect(described_class.new(queue:).call(effect, big)).to be_nil
  end

  it "answers nothing for a call barred from automatic approval" do
    approved_by_human(in_dir("/srv/p"))
    barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(in_dir("/srv/p"), barred: true)

    expect(described_class.new(queue:).call(effect, barred)).to be_nil
  end

  it "has a null for a session with no queue, which replays nothing" do
    expect(described_class::None.call(effect, in_dir("/srv/p"))).to be_nil
  end
end
