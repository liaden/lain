# frozen_string_literal: true

require "tmpdir"

# One local endpoint's model residency, held across processes through real flocks.
RSpec.describe Lain::Provider::Residency, :seam do
  around do |example|
    Dir.mktmpdir("lain-residency") do |dir|
      @dir = dir
      example.run
    end
  end

  after { @holders&.each(&:release) }

  let(:paths) { Lain::Paths.new(env: { "HOME" => @dir, "XDG_STATE_HOME" => @dir }) }
  let(:residency) { described_class.for(endpoint: "http://127.0.0.1:11434", paths:) }
  let(:journal) { [] }

  # Another process holding the endpoint for `model` until released; it leaves through exit!, and
  # closes the earlier holders' pipes so a release reaches only the holder it names.
  def held_elsewhere(model)
    ready, held = IO.pipe
    release, go = IO.pipe
    pid = fork do
      [ready, go, *@holders&.map(&:go)].each(&:close)
      residency.holding(model:, deadline: 0, journal: []) { held.write("held") && held.flush && release.read(1) }
    ensure
      exit!(0)
    end
    [held, release].each(&:close)
    raise "the other process never held the endpoint" unless ready.read(4) == "held"

    released(pid, go).tap { |holder| (@holders ||= []) << holder }
  end

  def released(pid, release_end)
    Struct.new(:pid, :go) do
      def release
        return if go.closed?

        go.close
        Process.wait(pid)
      end
    end.new(pid, release_end)
  end

  def waited = journal.grep(described_class::Waited)

  it "makes a request for another model wait until the holder releases, then journals that it held after waiting" do
    holder = held_elsewhere("model-a")
    notices = []
    patient = described_class.for(endpoint: "http://127.0.0.1:11434", paths:, patience: 0.05)
    waiting = Thread.new do
      patient.holding(model: "model-b", deadline: 30, journal:, notice: ->(event) { notices << event }) { :ran }
    end
    deadline = Time.now + 5
    sleep(0.01) until notices.any? || Time.now > deadline

    expect(waiting).to be_alive
    holder.release

    expect(waiting.value).to eq(:ran)
    expect(notices.map(&:to_h)).to eq([{ endpoint: "http://localhost:11434", model: "model-b", resident: "model-a" }])
    expect(waited.map { |record| record.to_h.except(:waited) })
      .to eq([{ endpoint: "http://localhost:11434", model: "model-b", resident: "model-a", outcome: "held" }])
    expect(waited.first.waited).to be_positive
  end

  it "runs unheld once a positive deadline passes, journaling that it proceeded and how long it waited" do
    held_elsewhere("model-a")

    expect(residency.holding(model: "model-b", deadline: 0.05, journal:) { :ran }).to eq(:ran)
    expect(waited.map(&:outcome)).to eq(["proceeded"])
    expect(waited.first.waited).to be >= 0.05
  end

  it "tells no notice before the patience runs out" do
    held_elsewhere("model-a")
    notices = []

    residency.holding(model: "model-b", deadline: 0.05, journal:, notice: ->(event) { notices << event }) { :ran }

    expect(notices).to be_empty
  end

  it "lets a request for the held model run at once, beside the holder in another process" do
    held_elsewhere("model-a")

    expect(residency.holding(model: "model-a", deadline: 0, journal:) { :ran }).to eq(:ran)
    expect(journal).to be_empty
  end

  it "lets 2 requests in 1 process share the endpoint for 1 model, each on its own descriptor" do
    inner = residency.holding(model: "model-a", deadline: 0, journal:) do
      residency.holding(model: "model-a", deadline: 0, journal:) { :inner }
    end

    expect(inner).to eq(:inner)
  end

  it "keeps a swap waiting while any holder of the resident model remains, and runs it once all release" do
    first = held_elsewhere("model-a")
    held_elsewhere("model-a").tap do |second|
      first.release

      expect(residency.holding(model: "model-b", deadline: 0, journal:) { :ran }).to eq(:skipped)
      second.release
    end

    expect(residency.holding(model: "model-b", deadline: 0, journal:) { :ran }).to eq(:ran)
  end

  it "answers :skipped at once for a deadline of 0, without running the block or journaling a wait" do
    held_elsewhere("model-a")
    ran = false

    expect(residency.holding(model: "model-b", deadline: 0, journal:) { ran = true }).to eq(:skipped)
    expect(ran).to be(false)
    expect(journal).to be_empty
  end

  it "refuses another model in the same process while 1 request holds the endpoint" do
    inner = residency.holding(model: "model-a", deadline: 0, journal:) do
      residency.holding(model: "model-b", deadline: 0, journal:) { :ran }
    end

    expect(inner).to eq(:skipped)
  end

  it "takes the endpoint at once from a holder killed with SIGKILL" do
    holder = held_elsewhere("model-a")
    Process.kill(:KILL, holder.pid)
    holder.release

    expect(residency.holding(model: "model-b", deadline: 0, journal:) { :ran }).to eq(:ran)
  end

  it "holds nothing for a hosted endpoint" do
    hosted = described_class.for(endpoint: "https://ollama.com", paths:)
    held_elsewhere("model-a")

    expect(hosted.holding(model: "model-b", deadline: 0, journal:) { :ran }).to eq(:ran)
    expect(journal).to be_empty
  end

  it "journals a wait as residency_waited" do
    record = described_class::Waited.new(endpoint: "http://localhost:11434", model: "b", resident: "a",
                                         outcome: "held", waited: 0.25)

    expect(record.to_journal).to eq("type" => "residency_waited", "endpoint" => "http://localhost:11434",
                                    "model" => "b", "resident" => "a", "outcome" => "held", "waited" => 0.25)
  end

  it "reads the resident model only under the decision lock, so a write in progress is never read half done" do
    held_elsewhere("model-a")
    meta = Dir[File.join(@dir, "**", "residency-*.meta")].sole
    deciding = Lain::FileLock.new(meta)
    reading = nil

    deciding.hold do
      reading = Thread.new { residency.resident }
      sleep(0.01) while reading.status == "run"
      expect(reading).to be_alive
    end

    expect(reading.value).to eq("model-a")
  end
end
