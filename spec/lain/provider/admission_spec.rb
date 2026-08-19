# frozen_string_literal: true

# F26: nothing in lain owned a provider's CAPACITY, so the harness put two
# requests on a one-slot server and read the silence it caused itself as a dead
# stream. {Provider::Admission} is that missing concept -- a gate per RESOLVED
# ENDPOINT, entered around a round trip.
#
# The last example is not an ordinary unit test, and it is the reason this object
# is hand-rolled rather than an `Async::Semaphore`. It was a standalone probe
# during T1's escalation, where it measured three failures at once: the
# `FiberError: fiber called across threads` lands in the RELEASING fiber (the
# agent's turn, killed by an unrelated resend), the waiting thread stays parked
# after a 5s join, and `Semaphore#release` decrements before it resumes, so the
# gate silently stops gating. `Provider#complete` really is reached from a second
# OS thread on the `--nvim` path (`agent.rb:234-236`), so that example pins the
# property the whole design exists for.
RSpec.describe Lain::Provider::Admission do
  # A fresh endpoint per example: `.for` memoises per endpoint in a process-global
  # registry, so sharing a name would leak one example's width into the next.
  let(:endpoint) { "http://localhost:11434/#{SecureRandom.hex(4)}" }

  describe "#enter" do
    it "makes a second caller wait rather than overlap the first" do
      admission = described_class.new(endpoint:, width: 1)
      events = []

      Sync do |task|
        first = task.async do
          admission.enter do
            events << :first_in
            task.sleep(0.1)
            events << :first_out
          end
        end
        task.sleep(0.02)
        second = task.async { admission.enter { events << :second_in } }
        [first, second].each(&:wait)
      end

      expect(events).to eq(%i[first_in first_out second_in])
    end

    it "releases when the block raises, so the next caller is admitted" do
      admission = described_class.new(endpoint:, width: 1)
      admitted = false

      Sync do
        expect { admission.enter { raise "boom" } }.to raise_error(RuntimeError, "boom")
        admission.enter { admitted = true }
      end

      expect(admitted).to be(true)
    end

    # Async::Stop is < Exception, not < StandardError, so only an `ensure` covers
    # it (isolation/worker_handoff.rb:27-34 writes the same lesson out).
    it "releases when the holding fiber is cancelled rather than raising" do
      admission = described_class.new(endpoint:, width: 1)
      admitted = false

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(10) } }
        task.sleep(0.02)
        holder.stop
        task.sleep(0.02)
        admission.enter { admitted = true }
      end

      expect(admitted).to be(true)
    end

    it "bounds the wait and refuses naming the endpoint, the deadline, and why one name covers several" do
      admission = described_class.new(endpoint:, width: 1, deadline: 0.05)
      refusal = nil

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(5) } }
        task.sleep(0.02)
        begin
          admission.enter { nil }
        rescue Lain::Provider::Admission::Busy => e
          refusal = e
        end
        holder.stop
      end

      expect(refusal).to be_a(Lain::Provider::Admission::Busy)
      expect(refusal.message).to include(endpoint).and include("0.05")
      # It names the CANONICAL endpoint, which may not be the string the operator
      # typed, so it says why one name can stand for several spellings.
      expect(refusal.message).to include("one gate per server, whatever the spelling")
    end

    it "reports the wait to the caller, and reports none to the caller that never waited" do
      admission = described_class.new(endpoint:, width: 1)
      waits = {}

      Sync do |task|
        first = task.async do
          admission.enter do |waited|
            waits[:first] = waited
            task.sleep(0.2)
          end
        end
        task.sleep(0.02)
        second = task.async { admission.enter { |waited| waits[:second] = waited } }
        [first, second].each(&:wait)
      end

      expect(waits[:first]).to eq(0.0)
      expect(waits[:second]).to be >= 0.1
    end
  end

  describe "#try_enter" do
    it "turns a caller away immediately rather than queueing it, without running its block" do
      admission = described_class.new(endpoint:, width: 1)
      ran = false
      answer = nil

      Sync do |task|
        holder = task.async { admission.enter { task.sleep(5) } }
        task.sleep(0.02)
        answer = admission.try_enter { ran = true }
        holder.stop
      end

      expect(answer).to be(described_class::REFUSED)
      expect(ran).to be(false)
    end

    it "admits when the endpoint is free, and returns the block's value" do
      admission = described_class.new(endpoint:, width: 1)

      expect(Sync { admission.try_enter { :summarised } }).to eq(:summarised)
    end
  end

  describe ".for" do
    it "does not make two different resolved endpoints contend" do
      other = "http://localhost:11435/#{SecureRandom.hex(4)}"
      admitted = false

      Sync do |task|
        holder = task.async { described_class.for(endpoint:).enter { task.sleep(5) } }
        task.sleep(0.02)
        described_class.for(endpoint: other).enter { admitted = true }
        holder.stop
      end

      expect(admitted).to be(true)
    end

    it "returns the same admission for the same endpoint" do
      expect(described_class.for(endpoint:)).to be(described_class.for(endpoint:))
    end

    # The documented escape hatch for a session admission has wedged; the house
    # pattern for an env-only off switch is provider/http/configuration.rb:127-131.
    it "admits everyone concurrently when LAIN_PROVIDER_CONCURRENCY is 0" do
      inside = 0
      peak = 0

      with_env("LAIN_PROVIDER_CONCURRENCY" => "0") do
        admission = described_class.for(endpoint:)
        expect(admission).to be_a(described_class::Null)

        Sync do |task|
          Array.new(3) do
            task.async do
              admission.enter do
                inside += 1
                peak = [peak, inside].max
                task.sleep(0.05)
                inside -= 1
              end
            end
          end.each(&:wait)
        end
      end

      expect(peak).to eq(3)
    end

    # THE BLOCKER the panel found. `-1` passes `Integer()`, so `@count < @width`
    # is `0 < -1` -- false with NOTHING in flight -- and every caller polls the
    # full deadline before raising. It is also the exact idiom someone reaches
    # for meaning "no limit", so the failure mode is a hung session produced by
    # a user trying to turn the feature OFF. Format was validated; domain was not.
    it "refuses a negative width rather than building a permanently shut gate" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "-1") do
        expect { described_class.for(endpoint:) }
          .to raise_error(Lain::Error, /LAIN_PROVIDER_CONCURRENCY/)
      end
    end

    it "names the value in the refusal, the way a non-numeric one is named" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "-4") do
        expect { described_class.for(endpoint:) }.to raise_error(Lain::Error, /"-4"/)
      end
    end
  end

  # Width 1 is a LOCAL-SERVER claim -- F26 is a one-slot local server handed two
  # requests -- so it is applied only where that claim holds. A hosted endpoint
  # gated at 1 would serialise concurrent subagents: `cli/wiring.rb:475` ->
  # `toolset_build.rb:316` builds ONE shared `Subagent::Seam` provider that every
  # child spawn runs over, and those children run at once. One provider, N
  # concurrent callers, one endpoint key -- so sharing the client does not soften
  # it, and the result is a throughput regression nobody asked for.
  describe "locality, which is what width 1 is a claim about" do
    # The most callers ever inside at once, which is the only thing "does it
    # serialise" can mean. A Hash rather than two locals so {#occupying} can
    # write to it without a closure the reader has to trace.
    def peak_concurrency(admission, callers: 3)
      gauge = { inside: 0, peak: 0 }

      Sync do |task|
        tasks = Array.new(callers) { task.async { occupying(admission, gauge) { task.sleep(0.05) } } }
        tasks.each(&:wait)
      end

      gauge[:peak]
    end

    def occupying(admission, gauge)
      admission.enter do
        gauge[:inside] += 1
        gauge[:peak] = [gauge[:peak], gauge[:inside]].max
        yield
        gauge[:inside] -= 1
      end
    end

    it "serialises two concurrent callers on one local endpoint" do
      expect(peak_concurrency(described_class.for(endpoint:))).to eq(1)
    end

    it "does not serialise two concurrent callers on one hosted endpoint" do
      hosted = described_class.for(endpoint: "https://api.anthropic.com/#{SecureRandom.hex(4)}")

      expect(peak_concurrency(hosted)).to eq(3)
    end

    it "hands a hosted endpoint the unbounded arm rather than a wide gate" do
      expect(described_class.for(endpoint: "https://api.example.test")).to be_a(described_class::Null)
    end

    # THE KEY MUST FOLD WHAT THE CLASSIFIER FOLDS, or {DEFAULT_WIDTH}'s argument
    # is defeated by the keying itself: `.local?` calls every 127/8 address one
    # server *because it is one server*, and a raw-string key then hands each
    # spelling its own slot.
    it "hands one ollama one gate however its address was spelled" do
      spellings = ["http://localhost:11434", "http://localhost:11434/", "http://LOCALHOST:11434",
                   "http://127.0.0.1:11434", "http://127.5.5.5:11434", "http://[::1]:11434",
                   "http://localhost.:11434", "http://0.0.0.0:11434"]

      gates = spellings.map { |endpoint| described_class.for(endpoint:) }

      expect(gates.uniq.size).to eq(1)
    end

    it "really admits only one of two spellings at a time, not merely one object" do
      Sync do |task|
        first = described_class.for(endpoint: "http://localhost:11434")
        second = described_class.for(endpoint: "http://127.0.0.1:11434")
        events = []
        held = task.async { first.enter { events << :first_in and task.sleep(0.15) and events << :first_out } }
        task.sleep(0.03)
        [held, task.async { second.enter { events << :second_in } }].each(&:wait)

        expect(events).to eq(%i[first_in first_out second_in])
      end
    end

    # Folded far enough to make one server one gate, and NO FURTHER. A port or a
    # base path names a different service, and folding either would silently
    # share one slot between two of them.
    it "keeps two ollamas on two ports apart" do
      expect(described_class.for(endpoint: "http://localhost:11434"))
        .not_to be(described_class.for(endpoint: "http://localhost:11435"))
    end

    it "keeps two base paths on one host apart" do
      expect(described_class.for(endpoint: "http://localhost:11434/alpha"))
        .not_to be(described_class.for(endpoint: "http://localhost:11434/beta"))
    end

    it "folds a local spelling to one key, and never onto a hosted one" do
      expect(described_class.canonical("http://127.0.0.1:11434/")).to eq("http://localhost:11434")
      expect(described_class.canonical("https://api.anthropic.com")).to eq("https://api.anthropic.com:443")
    end

    # A socket path is case-SENSITIVE, unlike a hostname, so the one thing the
    # key may not do to it is downcase it.
    it "does not downcase a unix socket path" do
      expect(described_class.canonical("unix:///run/Ollama.sock")).to include("Ollama")
    end

    # The override is what an operator reaches for, so it has to work in the
    # direction that is NOT the default -- putting a ceiling on a hosted arm.
    it "lets an explicit width gate a hosted endpoint anyway" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "1") do
        hosted = described_class.for(endpoint: "https://api.example.test/#{SecureRandom.hex(4)}")

        expect(hosted).to be_a(described_class)
        expect(peak_concurrency(hosted)).to eq(1)
      end
    end

    it "lets the off switch unbound a local endpoint" do
      with_env("LAIN_PROVIDER_CONCURRENCY" => "0") do
        expect(described_class.for(endpoint:)).to be_a(described_class::Null)
      end
    end
  end

  describe "a width that could never admit anyone" do
    # The sibling hole: `.for` routes 0 to Null, but a direct construction does
    # not, so `new(width: 0)` is the same shut gate by another door.
    it "refuses a zero width at construction" do
      expect { described_class.new(endpoint:, width: 0) }
        .to raise_error(Lain::Error, /width/)
    end

    it "refuses a negative width at construction" do
      expect { described_class.new(endpoint:, width: -1) }
        .to raise_error(Lain::Error, /width/)
    end
  end

  describe ".reset!" do
    # The spec used to mint a random endpoint per example to dodge cross-example
    # leakage -- a fixture working around a missing affordance. This is the
    # affordance: the registry pins the env at an endpoint's FIRST resolution,
    # so re-reading it needs an explicit clear.
    it "drops the memoised admissions, so the env is read afresh" do
      before_reset = described_class.for(endpoint:)
      described_class.reset!

      expect(described_class.for(endpoint:)).not_to be(before_reset)
    end

    it "lets a later env change take effect for an endpoint already resolved" do
      expect(described_class.for(endpoint:)).to be_a(described_class)

      described_class.reset!
      with_env("LAIN_PROVIDER_CONCURRENCY" => "0") do
        expect(described_class.for(endpoint:)).to be_a(described_class::Null)
      end
    end
  end

  describe described_class::Null do
    # A Null Object may do nothing; it may not LIE. T3's journal reads this.
    it "reports the callers actually inside it, rather than a flat zero" do
      admission = described_class.new(endpoint: "http://unbounded.example")
      seen = nil

      Sync { admission.enter { seen = admission.in_flight } }

      expect(seen).to eq(1)
      expect(admission.in_flight).to eq(0)
    end

    it "reports them from try_enter too, and unwinds when the block raises" do
      admission = described_class.new(endpoint: "http://unbounded.example")
      seen = nil

      Sync do
        admission.try_enter { seen = admission.in_flight }
        expect { admission.enter { raise "boom" } }.to raise_error(RuntimeError)
      end

      expect(seen).to eq(1)
      expect(admission.in_flight).to eq(0)
    end
  end

  # THE cross-thread example. `Provider#complete` is reached from the Neovim
  # resend-worker thread (repl.rb:135 -> neovim.rb:351 -> resend_bridge.rb:156 ->
  # agent.rb:240's `Sync`, which spins a SECOND reactor because there is none to
  # join) while the eager oracle, span summarizer and window probes run on the
  # conductor's. An Async::Semaphore fails every assertion below.
  describe "two reactors on two threads" do
    it "gates them without corrupting itself, wedging a waiter, or raising into the holder" do
      admission = described_class.new(endpoint:, width: 1)
      events = Queue.new
      errors = Queue.new
      held = Queue.new
      second_waited = nil

      holder = Thread.new do
        Sync do
          admission.enter do
            events << :holder_in
            held << :held
            sleep(0.15)
            events << :holder_out
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors << e
      end

      held.pop
      waiter = Thread.new do
        Sync do
          admission.enter do |waited|
            second_waited = waited
            events << :waiter_in
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        errors << e
      end

      expect([holder, waiter].map { |t| t.join(5) }).to all(be_truthy) # nothing wedged
      expect(errors.size).to eq(0)
      expect(Array.new(events.size) { events.pop }).to eq(%i[holder_in holder_out waiter_in])
      expect(second_waited).to be_positive # it really was gated, not waved through
      expect(Sync { admission.try_enter { :free } }).to eq(:free) # and the gate is not stuck held
    end
  end

  # T2. The gate above is only worth having if EVERY round trip goes through it,
  # and the enumeration that would guarantee that cannot be written: there are six
  # provider construction sites on the chat path and {Oracle::SecretRead.tier}
  # (`oracle/secret_read.rb:134`) is structurally forbidden from accepting an
  # injected collaborator -- that seam IS the disclosure the rung exists to
  # prevent. So admission is taken by the PROVIDER, keyed by the endpoint the
  # provider resolves for itself, and capacity becomes a property of the server
  # rather than of whoever built the client.
  #
  # These examples therefore build providers the way an unco-operating caller
  # does -- separately, with no shared object between them -- and assert they
  # still contend.
  describe "taken by the provider, so no construction site can miss it" do
    let(:clock_class) { Lain::Provider::HTTP::Streaming::StallClock }

    # Never the real default here except where an example is ABOUT the default:
    # `.for` memoises in a process-global registry, so an example sharing a key
    # with the rest of the suite leaks its width into whatever runs next. The
    # path suffix is only ever a key -- every transport below is a double, so
    # nothing dials it.
    def unique_base = "http://127.0.0.1:11434/#{SecureRandom.hex(4)}"

    def ollama_request(**overrides)
      Lain::Request.new(model: "qwen3:4b", max_tokens: 16, stream: false,
                        messages: [{ role: "user", content: "hi" }], **overrides)
    end

    def anthropic_request(**overrides)
      Lain::Request.new(model: "claude-opus-4-8", max_tokens: 16, stream: false,
                        messages: [{ role: "user", content: "hi" }], **overrides)
    end

    # An ollama transport double that runs `body_block` in place of the round
    # trip. `attempt:` is DECLARED rather than swallowed, for the reason
    # `ollama_spec.rb:13-26` gives: a double accepting no keyword takes the
    # Provider's `attempt:` as its HEADERS and says nothing.
    def ollama_transport(&body_block)
      Class.new do
        define_method(:sync_post) do |_payload, _headers = {}, attempt: nil| # rubocop:disable Lint/UnusedBlockArgument
          Struct.new(:body).new(yield || {})
        end
      end.new
    end

    def anthropic_transport(&body_block)
      Class.new do
        define_method(:sync_post) { |_payload, _headers = {}, **| Struct.new(:body).new(yield || {}) }
      end.new
    end

    # `sleep` rather than `task.sleep` because the block runs inside the
    # provider, which has no task to hand -- and under a reactor `Kernel#sleep`
    # is hooked by `Async::Scheduler#kernel_sleep` and yields the fiber, which is
    # the same property {Admission}'s own poll depends on.
    def marking(events, name, hold: 0.0)
      lambda do
        events << :"#{name}_in"
        sleep(hold) if hold.positive?
        events << :"#{name}_out"
        {}
      end
    end

    # The whole point of keying on the RESOLVED endpoint: neither provider knows
    # the other exists, and there is no collaborator between them to inject.
    it "never overlaps two independently built providers on one resolved endpoint" do
      base = unique_base
      events = []
      first = Lain::Provider::Ollama.new(api_base: base,
                                         transport: ollama_transport(&marking(
                                           events, :first, hold: 0.15
                                         )))
      second = Lain::Provider::Ollama.new(api_base: base, transport: ollama_transport(&marking(events, :second)))

      Sync do |task|
        holder = task.async { first.complete(ollama_request) }
        task.sleep(0.03)
        [holder, task.async { second.complete(ollama_request) }].each(&:wait)
      end

      expect(events).to eq(%i[first_in first_out second_in second_out])
    end

    # THE REGRESSION TEST FOR THE WHOLE CARD, promoted from a review probe that
    # reproduced F26 after admission had supposedly fixed it.
    #
    # The pairing is the real one, not a convenient one: a chat provider built
    # from `--api-base`, against the BARE `Provider::Ollama.new` that
    # {Oracle::SecretRead.tier} constructs -- the site that structurally cannot
    # accept an injected collaborator, and the reason admission lives inside the
    # provider instead of in `Backend`. Both reach one ollama.
    #
    # It failed for every spelling except the byte-identical one, because
    # `.local?` folded loopback while the registry keyed on the raw STRING. The
    # AC above did not catch it: it configures the byte-identical default, which
    # is the one case an operator never has to think about. **Pin the spellings,
    # not one string.**
    [["http://127.0.0.1:11434", "a dotted-quad --api-base"],
     ["http://localhost:11434/", "a trailing slash"],
     ["http://LOCALHOST:11434", "an uppercased host"],
     ["http://[::1]:11434", "the v6 loopback"],
     ["http://0.0.0.0:11434", "a bind-all base"],
     ["http://localhost:11434", "the control: the byte-identical default"]].each do |base, label|
      it "serialises the secret-read oracle behind a chat provider built with #{label}" do
        events = []
        chat = Lain::Provider::Ollama.new(api_base: base, transport: ollama_transport(&marking(events, :chat,
                                                                                               hold: 0.15)))
        # Exactly what `oracle/secret_read.rb:134` builds: no api_base, no seam.
        secret_read = Lain::Provider::Ollama.new(transport: ollama_transport(&marking(events, :oracle)))

        Sync do |task|
          held = task.async { chat.complete(ollama_request) }
          task.sleep(0.03)
          [held, task.async { secret_read.complete(ollama_request) }].each(&:wait)
        end

        expect(events).to eq(%i[chat_in chat_out oracle_in oracle_out])
      end
    end

    # The key is the endpoint the provider RESOLVED, not the flag it was handed.
    # A key of `@options[:api_base]` would read nil here and the configured
    # string there, and the two would not contend -- which is precisely the case
    # {Oracle::SecretRead} lands on, since it passes no api_base at all and still
    # reaches `http://localhost:11434`.
    it "makes a provider built with no api_base contend with one built against that same default" do
      events = []
      bare = Lain::Provider::Ollama.new(transport: ollama_transport(&marking(events, :bare, hold: 0.15)))
      configured = Lain::Provider::Ollama.new(
        api_base: Lain::Provider::Ollama::Transport::DEFAULT_API_BASE,
        transport: ollama_transport(&marking(events, :configured))
      )

      Sync do |task|
        holder = task.async { bare.complete(ollama_request) }
        task.sleep(0.03)
        [holder, task.async { configured.complete(ollama_request) }].each(&:wait)
      end

      expect(events).to eq(%i[bare_in bare_out configured_in configured_out])
    end

    # There is ONE `--api-base` for every tier (`exe/lain:416`), so
    # `--provider anthropic --summarizer-provider ollama` gives `api_base == nil`
    # on both sides. A key derived from the flag would serialise a hosted turn
    # behind a local summary; a key derived from what each provider resolved does
    # not.
    it "does not serialise a hosted endpoint behind a local one" do
      events = []
      local = Lain::Provider::Ollama.new(api_base: unique_base,
                                         transport: ollama_transport(&marking(events, :local, hold: 0.2)))
      hosted = Lain::Provider::Anthropic.new(api_key: "sk-test", api_base: "https://api.example.test",
                                             transport: anthropic_transport(&marking(events, :hosted)))

      Sync do |task|
        holder = task.async { local.complete(ollama_request) }
        task.sleep(0.03)
        [task.async { hosted.complete(anthropic_request) }, holder].each(&:wait)
      end

      expect(events).to eq(%i[local_in hosted_in hosted_out local_out])
    end

    # The DEFAULT that a bare construction resolves to has to be the one the
    # transport would really dial, or the example above pins agreement between
    # two providers on a string neither of them talks to. Pinned mechanically
    # rather than trusted, because the two live in different files.
    it "keys each arm on the endpoint its own transport resolves" do
      config = Lain::Provider::HTTP::Configuration.new
      config.anthropic_api_key = "sk-test"

      expect(Lain::Provider::Ollama::Transport.new(Lain::Provider::HTTP::Configuration.new).api_base)
        .to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
      expect(Lain::Provider::Anthropic::Transport.new(config).api_base)
        .to eq(Lain::Provider::Anthropic::DEFAULT_API_BASE)
    end

    # THE POSITION OF THE SEAM, and the reason it may never drift downward.
    #
    # The stall clock arms on the FIRST TICK inside the transport
    # (`http/streaming/faraday_handlers.rb:397`, reached per body chunk), and its
    # grace is 30s. Admission taken below that -- inside `#stream`, or around
    # `#watch` -- would leave a queued request holding an armed clock with no
    # server sending it anything, and the 30s would fire against a stream that
    # was merely waiting its turn. Wrapping `#complete` instead means a queued
    # caller has not entered its transport at all, which is the observable here:
    # `no transport call yet` IS `no clock installed`, from outside a fiber whose
    # storage nothing else may read.
    it "keeps a queued caller outside the stream, so nothing arms a clock while it waits" do
      base = unique_base
      waiter_entries = []
      waiter_touches_during_hold = nil
      clock_seen_by_waiter = nil

      holder = Lain::Provider::Ollama.new(api_base: base, transport: ollama_transport do
        sleep(0.1)
        waiter_touches_during_hold = waiter_entries.size
        sleep(0.1)
        {}
      end)
      waiter = Lain::Provider::Ollama.new(api_base: base, transport: ollama_transport do
        waiter_entries << :in
        clock_seen_by_waiter = clock_class.current
        {}
      end)

      Sync do |task|
        held = task.async { holder.complete(ollama_request) }
        task.sleep(0.03)
        [held, task.async { waiter.complete(ollama_request) }].each(&:wait)
      end

      expect(waiter_touches_during_hold).to eq(0)
      expect(clock_seen_by_waiter).to be(clock_class::Null)
    end

    # Open decision 4. `Oracle::Eager` promises the turn that produced a tool
    # result never waits on its summary (`eager.rb:45-47`), so its provider is
    # built unwilling to queue and a busy endpoint SKIPS the summary. Queueing
    # instead is the worse degradation: a fire reaped at teardown burns its
    # digest for the whole session, while a skip is a miss
    # {Compaction::SummarySnapshot} already reads as ordinary.
    #
    # Capacity is a property of the server; willingness to wait is a property of
    # the caller. Hence a CONSTRUCTOR keyword and not an argument to `#complete`.
    describe "a provider built unwilling to queue" do
      it "refuses at once instead of waiting, and never reaches its transport" do
        base = unique_base
        touched = false
        events = []
        holder = Lain::Provider::Ollama.new(api_base: base,
                                            transport: ollama_transport(&marking(events, :holder, hold: 0.3)))
        impatient = Lain::Provider::Ollama.new(api_base: base, queue: false,
                                               transport: ollama_transport { touched = true })
        refusal = nil
        waited = nil

        Sync do |task|
          held = task.async { holder.complete(ollama_request) }
          task.sleep(0.03)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            impatient.complete(ollama_request)
          rescue Lain::Provider::Admission::Busy => e
            refusal = e
          end
          waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          held.wait
        end

        expect(refusal).to be_a(Lain::Provider::Admission::Busy)
        expect(refusal.message).to include(base)
        expect(touched).to be(false)
        expect(waited).to be < 0.1 # it did not queue behind the 0.3s holder
      end

      # The refusal has to be a StandardError for {Oracle::Eager}'s task-boundary
      # rescue to contain it into a miss rather than killing the turn that fired
      # the summary.
      it "refuses with an error the eager oracle's containment already catches" do
        expect(Lain::Provider::Admission::Busy.ancestors).to include(Lain::Error, StandardError)
      end

      it "still completes normally when the endpoint is free" do
        provider = Lain::Provider::Ollama.new(api_base: unique_base, queue: false,
                                              transport: ollama_transport { {} })

        expect(Sync { provider.complete(ollama_request) }).to be_a(Lain::Response)
      end

      # The default is the other way, and the span summarizer depends on it: it
      # answers on the render path, where the summary is worth waiting for.
      it "waits by default, so only a caller that asked gets the skip" do
        base = unique_base
        events = []
        holder = Lain::Provider::Ollama.new(api_base: base,
                                            transport: ollama_transport(&marking(events, :holder, hold: 0.15)))
        patient = Lain::Provider::Ollama.new(api_base: base, transport: ollama_transport(&marking(events, :patient)))

        Sync do |task|
          held = task.async { holder.complete(ollama_request) }
          task.sleep(0.03)
          [held, task.async { patient.complete(ollama_request) }].each(&:wait)
        end

        expect(events).to eq(%i[holder_in holder_out patient_in patient_out])
      end
    end
  end
end
