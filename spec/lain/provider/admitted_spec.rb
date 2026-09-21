# frozen_string_literal: true

require "stringio"

# The join between a gate that knows about SERVERS and a provider that knows
# about its own endpoint, its own caller, and where that caller's records land.
# Extracted when both arms needed the identical eight lines -- the point at
# which a duplicated policy starts to drift -- so it is exercised here against a
# bare includer rather than only through the two providers in `admission_spec.rb`.
RSpec.describe Lain::Provider::Admitted do
  # A minimal includer: the three messages the module depends on, and nothing
  # else. Depending on MESSAGES rather than on an includer's ivars is what lets
  # the two real arms resolve their endpoints differently -- and what lets each
  # of them name a journal of its own without this module knowing how a session
  # comes by one.
  # `width:` is sentinel-defaulted rather than nil-defaulted because "declared
  # nothing" and "declared nil" have to stay distinguishable here: the mixin's
  # own nil default is what keeps {Provider::Anthropic} untouched, and an
  # includer that always overrode the method would never exercise it.
  def caller_for(endpoint:, queue: true, journal: Lain::Channel::Null::INSTANCE, width: :undeclared)
    Class.new do
      include Lain::Provider::Admitted

      define_method(:queue_for_capacity?) { queue }
      define_method(:resolved_endpoint) { endpoint }
      define_method(:wait_journal) { journal }
      define_method(:admission_width) { width } unless width == :undeclared
      # `#admitted` is private, so the double needs a public way in.
      define_method(:run) { |&block| admitted(&block) }
    end.new
  end

  let(:endpoint) { "http://127.0.0.1:11434/#{SecureRandom.hex(4)}" }

  it "runs the block inside the endpoint's slot and returns its value" do
    expect(Sync { caller_for(endpoint:).run { :answered } }).to eq(:answered)
  end

  it "reports the callers inside while the block runs" do
    inside = nil

    Sync { caller_for(endpoint:).run { inside = Lain::Provider::Admission.for(endpoint:).in_flight } }

    expect(inside).to eq(1)
    expect(Lain::Provider::Admission.for(endpoint:).in_flight).to eq(0)
  end

  it "queues a willing caller behind the holder rather than refusing it" do
    events = []
    holder = caller_for(endpoint:)
    patient = caller_for(endpoint:)

    Sync do |task|
      held = task.async do
        holder.run do
          events << :holder_in
          task.sleep(0.15)
          events << :holder_out
        end
      end
      task.sleep(0.03)
      [held, task.async { patient.run { events << :patient_in } }].each(&:wait)
    end

    expect(events).to eq(%i[holder_in holder_out patient_in])
  end

  # The refusal has to be a StandardError, because {Oracle::Eager}'s task
  # boundary is what turns it into a skipped summary rather than a dead turn.
  it "refuses an unwilling caller by name, without running its block" do
    ran = false
    holder = caller_for(endpoint:)
    impatient = caller_for(endpoint:, queue: false)
    refusal = nil

    Sync do |task|
      held = task.async { holder.run { task.sleep(0.2) } }
      task.sleep(0.03)
      begin
        impatient.run { ran = true }
      rescue Lain::Provider::Admission::Busy => e
        refusal = e
      end
      held.wait
    end

    expect(refusal).to be_a(Lain::Provider::Admission::Busy).and be_a(StandardError)
    expect(refusal.message).to include(endpoint)
    expect(ran).to be(false)
  end

  it "admits an unwilling caller when the endpoint is free" do
    expect(Sync { caller_for(endpoint:, queue: false).run { :summarised } }).to eq(:summarised)
  end

  # A block returning nil must not read as a refusal: {Admission::REFUSED} is a
  # sentinel precisely so "ran, gave nothing" stays distinguishable.
  it "passes a nil result through rather than mistaking it for a refusal" do
    expect(Sync { caller_for(endpoint:, queue: false).run { nil } }).to be_nil
  end

  it "releases the slot when the block raises" do
    admitting = caller_for(endpoint:)

    Sync do
      expect { admitting.run { raise "boom" } }.to raise_error(RuntimeError, "boom")
    end

    expect(Lain::Provider::Admission.for(endpoint:).in_flight).to eq(0)
  end

  # The fourth message, and the only optional one: an includer that knows its
  # server's capacity says so, and one that does not says nothing. The default
  # lives in the mixin so a provider whose endpoint locality already classifies
  # correctly -- {Provider::Anthropic}, which includes this module -- needs no
  # edit at all to keep the arm it has.
  describe "a width the includer declares for its own endpoint" do
    let(:cloud) { "https://ollama.com" }

    # THE RESETS ARE LOAD-BEARING, the same posture `ollama_spec.rb`'s
    # `without_admission` takes and for the same reason: {Admission.for} pins
    # whatever an endpoint's FIRST resolution decided, now including a declared
    # width. These examples name one endpoint deliberately -- two includers
    # declaring different things about `ollama.com` is the case that matters --
    # so each one has to be the first this process resolved it, and must not be
    # what a later example inherits. Remove either reset and this block becomes
    # order-dependent under a different `--seed`.
    def unpinned
      Lain::Provider::Admission.reset!
      yield
    ensure
      Lain::Provider::Admission.reset!
    end

    it "gates the endpoint at the declared width" do
      unpinned do
        Sync { caller_for(endpoint: cloud, width: 3).run { :answered } }

        expect(Lain::Provider::Admission.for(endpoint: cloud).width).to eq(3)
      end
    end

    it "leaves the endpoint unbounded when the includer declares nothing" do
      unpinned do
        Sync { caller_for(endpoint: cloud).run { :answered } }

        expect(Lain::Provider::Admission.for(endpoint: cloud)).to be_a(Lain::Provider::Admission::Null)
      end
    end

    # The join's share of the panel review: a provider that declares nothing
    # about the cloud endpoint -- which `--provider ollama --api-base
    # https://ollama.com` builds today -- pins {Admission::Null}, and a later
    # provider that DOES know its plan's capacity has to be able to take that
    # endpoint over. Otherwise the first silent round trip of a process decides
    # that every metered one after it runs unbounded.
    it "lets a declaring includer take over an endpoint a silent one left unbounded" do
      unpinned do
        Sync { caller_for(endpoint: cloud).run { :silent } }
        Sync { caller_for(endpoint: cloud, width: 3).run { :declared } }

        expect(Lain::Provider::Admission.for(endpoint: cloud).width).to eq(3)
      end
    end

    it "still serialises a local endpoint the includer declared a width for" do
      unpinned do
        Sync { caller_for(endpoint:, width: 3).run { :answered } }

        expect(Lain::Provider::Admission.for(endpoint:).width).to eq(Lain::Provider::Admission::DEFAULT_WIDTH)
      end
    end
  end

  # {Admission::Journal} was written, spec'd at its own mirror path, and never
  # constructed -- so three rounds of QA journals held zero
  # `provider_wait` records while the gate they describe was live. The wrap
  # happens HERE and not in {Admission.build} because the two objects have
  # different lifetimes: capacity is process-global (a property of the server,
  # memoised per endpoint for the life of the process) while a journal is
  # per-session (a property of the caller). Decorating per call is what lets one
  # memoised gate serve two sessions that record to different places.
  describe "the wait a caller leaves behind" do
    let(:io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io:) }
    # The gate keys on {Admission.canonical}, and the record reports what the
    # gate was keyed on -- so `127.0.0.1` journals as `localhost`.
    let(:canonical) { Lain::Provider::Admission.canonical(endpoint) }

    # Holds the endpoint's one slot for `seconds`, so the caller under test has
    # to queue for it.
    def while_held(task, seconds:)
      held = task.async { caller_for(endpoint:).run { task.sleep(seconds) } }
      task.sleep(0.03)
      yield
      held.wait
    end

    it "journals a provider_wait naming the endpoint and the seconds queued" do
      waited = nil

      Sync do |task|
        while_held(task, seconds: 0.15) { caller_for(endpoint:, journal:).run { |seconds| waited = seconds } }
      end

      expect(waited).to be > 0
      expect(io).to include_journal_record("provider_wait", kind: "waited", endpoint: canonical,
                                                            waited_seconds: waited.round(3))
    end

    it "journals nothing when the caller took a slot on its first attempt" do
      Sync { caller_for(endpoint:, journal:).run { :answered } }

      expect(io.string).to be_empty
    end

    # Open decision 4, kept: an oracle SKIPPED for capacity leaves no record.
    # `#try_enter` is the eager oracle's entry point and a busy endpoint there
    # is a skip, not a wait -- filing it under `provider_wait` would describe it
    # with the wrong noun and put a record on every turn whose summary was
    # declined.
    it "journals nothing when an unwilling caller is refused rather than queued" do
      Sync do |task|
        while_held(task, seconds: 0.2) do
          expect { caller_for(endpoint:, queue: false, journal:).run { :never } }
            .to raise_error(Lain::Provider::Admission::Busy)
        end
      end

      expect(io.string).to be_empty
    end

    # The other half of that distinction, and the shape no acceptance criterion
    # named: a caller that WAS willing to wait, waited, and ran out of deadline
    # journals `kind: "refused"`. It is not the skip above -- a skip is a caller
    # declining to queue, while this is a saturation reading, which is exactly
    # what a reader summing an endpoint's waits wants to see. Pinned here so the
    # shape is decided rather than discovered, and so the guard's rule that a
    # refusal carries NO `waited_seconds` (no wait completed) is exercised
    # through the real decorator rather than only in its own spec.
    #
    # The gate is stubbed for its DEADLINE and nothing else: {Admission.for}
    # memoises a gate built with {Admission::DEFAULT_DEADLINE}, which is 300
    # seconds and takes no keyword, so the refusal arm is otherwise unreachable
    # in bounded time. The gate handed back is a real {Admission}.
    it "journals a refusal when a caller that queued runs out of deadline" do
      gate = Lain::Provider::Admission.new(endpoint: canonical, width: 1, deadline: 0.05, poll_interval: 0.01)
      allow(Lain::Provider::Admission).to receive(:for).and_return(gate)

      Sync do |task|
        held = task.async { caller_for(endpoint:).run { task.sleep(0.3) } }
        task.sleep(0.02)
        expect { caller_for(endpoint:, journal:).run { :never } }
          .to raise_error(Lain::Provider::Admission::Busy)
        held.wait
      end

      expect(io).to include_journal_record("provider_wait", kind: "refused", endpoint: canonical,
                                                            waited_seconds: nil, in_flight: 1)
    end

    # The lifetime split, mechanically: one process-global gate, two callers
    # recording to two destinations. A wrap inside {Admission.build} could not
    # express this -- the first session to resolve an endpoint would own its
    # journal for the life of the process.
    it "decorates per call, so two callers on one gate journal to their own destinations" do
      other_io = StringIO.new
      other = Lain::Journal.new(io: other_io)

      Sync do |task|
        while_held(task, seconds: 0.15) { caller_for(endpoint:, journal:).run { :first } }
        while_held(task, seconds: 0.15) { caller_for(endpoint:, journal: other).run { :second } }
      end

      expect(io).to include_journal_record("provider_wait", endpoint: canonical)
      expect(other_io).to include_journal_record("provider_wait", endpoint: canonical)
    end
  end

  # The wiring half of it: the module above is only reachable through a real
  # provider, and a provider is only reachable through the thing that builds one
  # for a run. A capability wired nowhere is the defect this whole chunk is
  # about, so it is pinned here rather than left to inspection.
  describe "a provider built through CLI::Backend" do
    let(:io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io:) }
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", api_base: endpoint }, root: Dir.pwd) }

    before do
      # {Backend::Summarizer::RunJournal}'s late binding: the run's journal is
      # resolved per EVENT, because nothing orders {Backend#pipeline_source} --
      # where it gets bound -- against the provider construction in
      # `wiring.rb`. This stubs the one message that forwarder
      # sends, which is the message a bound run would answer.
      allow(backend).to receive(:journal).and_return(journal)
    end

    it "journals the wait it queued for, to the run's own journal" do
      provider = backend.provider

      Sync do |task|
        held = task.async { caller_for(endpoint:).run { task.sleep(0.15) } }
        task.sleep(0.03)
        provider.send(:admitted) { :answered }
        held.wait
      end

      expect(io).to include_journal_record("provider_wait", kind: "waited",
                                                            endpoint: Lain::Provider::Admission.canonical(endpoint))
    end
  end
end
