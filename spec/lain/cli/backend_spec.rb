# frozen_string_literal: true

# Backend is the plain object the CLI's chat and bench-record paths BOTH resolve
# their provider and context through, extracted out of exe/lain so the
# provider/model/sampler resolution is unit-testable without a Thor instance and
# so a single seam decides what `--provider` means for every command. Errors
# here are Lain's, not Thor's: the exe layer maps {Lain::CLI::UnknownProvider} to
# a Thor::Error, but below the frontend an unknown provider is a plain Lain
# error (CLAUDE.md output/error discipline -- thor never crosses into lib/).
RSpec.describe Lain::CLI::Backend do
  subject(:backend) { described_class.new(options) }

  let(:options) { {} }

  # T10: a Backend on `--provider ollama` asks its server which window it is
  # SERVING before it builds the run's book ({Backend#context_window}), so
  # every ollama example here now makes one GET. The default answer is "nothing
  # resident", which is both the ordinary state of a fresh box and the answer
  # that leaves {ContextWindow::CONSERVATIVE_FALLBACK} in charge -- so an
  # example that is not about the window measures exactly what it did before.
  # An example that IS about it declares its own stub, which WebMock prefers
  # (the most recently registered match wins).
  before do
    stub_request(:get, %r{/api/ps})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: JSON.generate("models" => []))
  end

  def backend_for(**options) = described_class.new(options)

  describe "#provider" do
    it "constructs a Provider::Ollama honoring --api-base" do
      provider = backend_for(provider: "ollama", api_base: "http://localhost:11434").provider
      expect(provider).to be_a(Lain::Provider::Ollama)
      expect(provider.instance_variable_get(:@config).ollama_api_base).to eq("http://localhost:11434")
    end

    it "constructs a Provider::Anthropic for --provider anthropic" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
    end

    # The RAW arm, like --provider anthropic above: both hosted names resolve to
    # the vendored Faraday transport, and the official-SDK classes are oracles
    # in spec/support/provider_oracles/ that no run constructs.
    it "constructs a Provider::Bedrock for --provider bedrock" do
      provider = with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
        backend_for(provider: "bedrock").provider
      end
      expect(provider).to be_a(Lain::Provider::Bedrock)
    end

    # The whole point of the extraction (AC2): an unknown name is a Lain error,
    # NOT Thor::Error -- the exe maps it. chat and record both resolve through
    # this one method, so they reject an unknown provider identically.
    it "fails loudly on an unknown provider with a named Lain error, not Thor::Error" do
      expect { backend_for(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini", expected one of.*anthropic.*ollama/m)
    end

    it "raises a Lain::Error (so the exe's Lain::Error rescue presents it cleanly)" do
      expect(Lain::CLI::UnknownProvider).to be < Lain::Error
    end

    # A missing key used to reach Anthropic's own eager check and backtrace
    # as Provider::HTTP::ConfigurationError -- a plain StandardError the exe's
    # `rescue Lain::Error` does not catch. This refuses BEFORE construction, as
    # a named Lain error, so the exe's clean mapping applies here too.
    it "fails loudly on a missing ANTHROPIC_API_KEY with a named Lain error, not a raw backtrace class" do
      with_env("ANTHROPIC_API_KEY" => nil) do
        expect { backend_for(provider: "anthropic").provider }
          .to raise_error(Lain::CLI::Backend::MissingAPIKey, /ANTHROPIC_API_KEY.*--provider anthropic/m)
      end
    end

    it "raises a Lain::Error for a missing key too (so the exe's rescue presents it cleanly)" do
      expect(Lain::CLI::Backend::MissingAPIKey).to be < Lain::Error
    end
  end

  # T17w's convergence: "anthropic" always means {Provider::Anthropic} for
  # chat now, whether or not journaling is on -- the spool no longer switches
  # provider CLASS, only whether the spool it's handed is Null (--no-journal,
  # bench's no-spool-at-all default) or a real tee (journaling on). Class
  # identity alone is now vacuous (every branch here builds Anthropic), so
  # these pin the ACTUAL spool object reaching the built provider -- the same
  # ivar-inspection idiom the Ollama --api-base example above uses.
  describe "#provider spool threading" do
    it "still constructs Anthropic with the default Null spool when none is given at all" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") { backend_for(provider: "anthropic").provider }
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool))
        .to be_a(Lain::Provider::Spool::Null)
    end

    it "constructs Anthropic with the given Null spool -- --no-journal's answer" do
      spool = Lain::Provider::Spool::Null.new
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end

    it "carries the SAME spool object into Anthropic when journaling hands in a real one" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(spool:)
      end
      expect(provider).to be_a(Lain::Provider::Anthropic)
      expect(provider.instance_variable_get(:@retries).instance_variable_get(:@spool)).to be(spool)
    end

    it "never hands ollama or bedrock the spool keyword -- their constructors don't accept it" do
      spool = Lain::Provider::ResponseWal.new("/tmp/lain-backend-spec-session.wal")

      expect { backend_for(provider: "ollama").provider(spool:) }.not_to raise_error
      expect do
        with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
          backend_for(provider: "bedrock").provider(spool:)
        end
      end.not_to raise_error
    end
  end

  # CE-5: the RAW provider emits retry and stream_started events onto its
  # `channel:`. Chat's live TTY Channel must be that channel or the frontend
  # never sees a stream start; the headless/bench paths (no channel given)
  # keep the Null channel default, so nothing is emitted where nothing drains.
  describe "#provider channel threading" do
    it "threads the given live Channel into Anthropic so stream_started reaches it" do
      channel = Lain::Channel.new
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider(channel:)
      end
      expect(provider.instance_variable_get(:@channel)).to be(channel)
    end

    it "defaults to the Null channel when none is given (headless/bench stay quiet)" do
      provider = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic").provider
      end
      expect(provider.instance_variable_get(:@channel)).to be(Lain::Channel::Null.instance)
    end

    # T2/F7, and the assertion the other two in this group cannot make: those
    # read an ivar, which stays green whether or not the keyword was ever
    # threaded HERE. This drives the whole production chain instead -- Backend
    # -> Provider::Ollama -> #build_config's retry_block -> faraday-retry ->
    # the run's channel -- because a keyword accepted with a safe default and
    # never wired ships nothing, greenly. Ollama used to be the one arm whose
    # retries reached no Journal at all; the QA run's >400s silent hang is what
    # that cost.
    it "threads the live channel into ollama, so a retried ollama request is journaled" do
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_raise(Faraday::ConnectionFailed).then
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                       "message" => { "role" => "assistant", "content" => "pong" }))
      channel = RecordingChannel.new
      # The SHIPPED retry envelope, sleeps included (~0.1s for the one retry):
      # this example is about the wiring Backend performs, and shaping the
      # envelope would mean handing in a config, which is exactly the bypass
      # that would stop it proving anything.
      provider = backend_for(provider: "ollama").provider(channel:)

      response = provider.complete(Lain::Request.new(model: "qwen3:4b", max_tokens: 64, stream: false,
                                                     messages: [{ role: "user", content: "hi" }]))

      expect(response.text).to eq("pong")
      expect(channel.events.grep(Lain::Telemetry::ProviderRetry).map(&:attempt)).to eq([1])
    end
  end

  # T10: the ONE denominator this run divides by. The POC published 86.4%
  # occupancy at 2.7% of the real capacity -- the numerator was exact and only
  # the window was wrong -- because every reader defaulted to
  # {ContextWindow.default}'s 8,192 conservative fallback for an ollama model
  # id no Anthropic-shaped table carries. The book is built HERE, once, out of
  # the window T9's {Provider#context_window_tokens} says the server is
  # actually serving, and the status feed, the compaction source and the Agent
  # all read this one instance -- so `state.json`, the journal and the REPL
  # prompt cannot tell a human three different stories.
  #
  # {Backend::WindowBook} does the resolving and is exercised HERE rather than
  # in a file of its own, as {Backend::Ceiling} and {Backend::Summarizer} are:
  # what it resolves is three of Backend's own flags against Backend's own
  # provider, so every example below would have to build a Backend anyway, and
  # the memoization these readers depend on is Backend's.
  describe "#context_window" do
    let(:model) { "qwen3-coder:30b" }

    def ps_entry(name, context_length)
      { "name" => name, "model" => name, "size" => 18_000_000_000,
        "digest" => "abc123", "context_length" => context_length }
    end

    def serving(*entries)
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => entries))
    end

    def ollama_backend(**overrides) = backend_for(provider: "ollama", model:, max_tokens: 64, **overrides)

    # AC1, with the POC's own numerator. 7,079 tokens is 86.4% of 8,192 and
    # 21.6% of the window actually being served -- the whole defect, as one
    # number.
    it "measures a turn against the window the server says it is serving" do
      serving(ps_entry(model, 32_768))

      expect(ollama_backend.context_window.occupancy(7_079, model:).ratio).to eq(7_079.fdiv(32_768))
    end

    # AC2. nil is the ORDINARY answer here (nothing resident yet, or no server
    # at all), so the fallback has to stand rather than degrade further.
    it "keeps the conservative fallback when the provider reports no window" do
      serving

      expect(ollama_backend.context_window.occupancy(7_079, model:).ratio)
        .to eq(7_079.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
    end

    # The served window is the run's MODEL's, and every other name falls back to
    # what that model's own book says rather than inheriting a window measured
    # for a different runner.
    it "leaves every other model on the shipped table" do
      serving(ps_entry(model, 32_768))
      book = ollama_backend.context_window

      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
      expect(book.window_tokens("some-other-local:7b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # The SUBSTRING trap, which a merged-key book fails silently and 4-8x in the
    # forbidden direction. `ContextWindow#matched` falls back to
    # `name.include?(token)` over every key, so a served window merged into the
    # table becomes a prefix rule for every LATER model name -- and untagged
    # ollama names that are prefixes of tagged ones are the ordinary case, not a
    # contrived one: ollama prints the resident runner as `qwen3:latest` and
    # `Ollama#serves?` matches the untagged `qwen3` an operator typed. A
    # mid-session `/model qwen3-coder:30b` then measured 32,768 against a real
    # 8,192. Exact identity is the only rule a served window can carry, because
    # the server answered about one runner.
    it "never lends the run's served window to a model that merely contains its name" do
      serving(ps_entry("qwen3:latest", 32_768))
      book = backend_for(provider: "ollama", model: "qwen3", max_tokens: 64).context_window

      expect(book.window_tokens("qwen3")).to eq(32_768)
      expect(book.window_tokens("qwen3-coder:30b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(book.window_tokens("qwen3:4b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(book.window_tokens("qwen3-tiny:0.5b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # The other half of that rule, and the asymmetry it has to avoid: the book is
    # GRANTED through `Ollama#serves?`, which matches an untagged `--model qwen3`
    # against the `qwen3:latest` a server prints back -- so a window can exist
    # BECAUSE of a name a narrower spending rule then refuses to answer for.
    # That splits the two surfaces by one tag, because Agent#occupancy divides
    # using the operator's string while StatusFeed divides using the model the
    # response echoed. One set grants and spends.
    it "spends the window by the same names Ollama#serves? granted it by" do
      serving(ps_entry("qwen3:latest", 32_768))
      book = backend_for(provider: "ollama", model: "qwen3", max_tokens: 64).context_window

      expect(book.window_tokens("qwen3")).to eq(32_768)
      expect(book.window_tokens("qwen3:latest")).to eq(32_768)
    end

    # A blank `--model` is a WIRING bug and ContextWindow is loud about one.
    # `--num-ctx` resolves a window with NO server involved, so a blank model
    # otherwise reached the book with a real number beside it and the loudness
    # was swallowed -- the one path on which a served book must refuse to answer
    # for its own model.
    it "still refuses a blank --model loudly, even when --num-ctx resolved a window alone" do
      serving
      book = backend_for(provider: "ollama", model: "  ", max_tokens: 64, num_ctx: 16_384).context_window

      expect { book.window_tokens("  ") }.to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    # One book, one probe: the three readers must divide by the same number,
    # and asking three times could answer three different ones across a reload.
    it "answers the same book to every reader, off a single probe" do
      serving(ps_entry(model, 32_768))
      backend = ollama_backend

      expect(backend.context_window).to be(backend.context_window)
      expect(a_request(:get, "http://localhost:11434/api/ps")).to have_been_made.once
    end

    # T9's docstring makes this constraint the CALLER's, and T11 made it live:
    # a runner left at 32,768 by `ollama run` or by a sibling session answers
    # 32,768 while the very next request -- carrying --num-ctx -- reloads it at
    # the smaller size.
    describe "--num-ctx" do
      it "outranks a larger served window" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend(num_ctx: 16_384).context_window.window_tokens(model)).to eq(16_384)
      end

      # The forbidden direction, refused: answering the LARGER of the two
      # over-estimates the window, and an over-estimate means
      # `approaching_window` never fires at all -- worse than the crash the
      # conservative fallback replaces.
      it "never lifts the window above what the server reports" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend(num_ctx: 65_536).context_window.window_tokens(model)).to eq(32_768)
      end

      # T6 CHANGED THE SECOND HALF of this deliberately. The number stands --
      # discarding a plausible `--num-ctx` would over-report 4x on the ordinary
      # `--num-ctx 32768` case -- but nobody measured it, so it is a guess and
      # not the tier whose docstring says "the server said so". Measured before
      # the split: `--num-ctx 999999` journaled `provenance="probed"` while
      # ollama served 262,144.
      it "stands alone when the provider reports nothing, as a guess" do
        serving
        resolution = ollama_backend(num_ctx: 16_384).context_window.resolve(model)

        expect(resolution.window_tokens).to eq(16_384)
        expect(resolution.provenance).to eq(Lain::ContextWindow::GUESSED)
        expect(resolution).not_to be_authoritative
      end

      # `0` is TRUTHY, so nothing downstream fell back for it: it was sent
      # verbatim as the request's `num_ctx` AND adopted as the run's
      # denominator, where it killed the chat mid-turn with `ArgumentError:
      # window_tokens must be a positive Integer, got 0` out of
      # Compaction::Need. `--num-ctx` is `type: :numeric` with no range check
      # and EnvDefaults.numeric only rejects non-numbers, so `LAIN_NUM_CTX=0`
      # in an .envrc was that crash for every session in the directory.
      #
      # Refused, never filtered: a silently-ignored `--num-ctx 0` would be the
      # other half of the same failure, and the operator would never learn the
      # flag did nothing.
      it "refuses a zero at CONSTRUCTION, in the flag's own name" do
        expect { ollama_backend(num_ctx: 0) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive, got 0/)
      end

      it "refuses a negative the same way" do
        expect { ollama_backend(num_ctx: -1) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive/)
      end

      # Construction is the one path every command takes, so the refusal cannot
      # depend on which collaborator a given run happens to build -- `bench
      # record` never asks for a window book at all and still sends the flag.
      it "refuses before anything asks for a window or a payload" do
        expect { ollama_backend(num_ctx: 0) }.to raise_error(Lain::CLI::Backend::InvalidCeiling)
        expect(a_request(:get, %r{/api/ps})).not_to have_been_made
      end

      # UNSET is a real answer -- "serve the model's own" -- and must not trip
      # the ceiling {Ceiling} refuses for an omitted `--max-tokens`.
      it "accepts being unset, which is not the omission a ceiling refuses" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend.context_window.window_tokens(model)).to eq(32_768)
      end

      it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::InvalidCeiling).to be < Lain::Error
      end

      # T6. An operator's `--num-ctx` is a REQUEST, and there is exactly one
      # number it can be checked against before a runner exists: the maximum
      # the weights were trained for. `--num-ctx 999999` on a model trained to
      # 262,144 was accepted, sent, and journaled as the run's whole window
      # while ollama quietly served 262,144.
      #
      # The trained figure arrives through {Provider#trained_context_tokens},
      # which is a separate accessor for a reason spelled out at both ends: it
      # is a ceiling for refusing a flag and never a denominator. If it ever
      # becomes the second, the 8x under-report this area exists to prevent is
      # back one layer up.
      describe "above what the model can ever serve" do
        def trained(context_length)
          stub_request(:post, "http://localhost:11434/api/show")
            .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                       body: JSON.generate("model_info" => {
                                             "general.architecture" => "qwen3moe",
                                             "qwen3moe.context_length" => context_length
                                           }))
        end

        it "refuses at CONSTRUCTION, naming the flag, the value and the maximum" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 999_999) }
            .to raise_error(Lain::CLI::Backend::UnservableWindow,
                            "--num-ctx 999999 is above the model's trained maximum of 262144; " \
                            "no runner can serve a window larger than the weights were trained for")
        end

        it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
          expect(Lain::CLI::Backend::UnservableWindow).to be < Lain::Error
        end

        # Construction is what every command goes through, so a refused launch
        # never reaches a chat -- and it must not have opened one on the way to
        # deciding.
        it "starts no chat" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 999_999) }.to raise_error(Lain::CLI::Backend::UnservableWindow)
          expect(a_request(:post, "http://localhost:11434/api/chat")).not_to have_been_made
        end

        # The boundary, both sides. Equal is servable -- it is exactly what the
        # weights allow -- and an off-by-one here would refuse the very flag an
        # operator reads off `/api/show` and types in.
        it "accepts a value at the trained maximum" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 262_144) }.not_to raise_error
        end

        it "accepts a value below it" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 32_768) }.not_to raise_error
        end

        # Degrade, do not refuse. Only ollama publishes a trained maximum;
        # {Provider}'s base answers nil, and a provider that cannot say must
        # not block a launch -- so the refusal fires only where a ceiling is
        # known AND exceeded.
        it "does not block a launch on a provider that publishes no trained maximum" do
          expect do
            with_env("ANTHROPIC_API_KEY" => "sk-test") do
              backend_for(provider: "anthropic", model: "claude-opus-4-5", max_tokens: 64, num_ctx: 999_999)
            end
          end.not_to raise_error
        end

        # An ollama that is not running is the ordinary state of this arm, and
        # a launch that cannot be validated is not a launch that is wrong.
        it "does not block a launch when the server cannot answer" do
          stub_request(:post, "http://localhost:11434/api/show").to_raise(Faraday::ConnectionFailed)

          expect { ollama_backend(num_ctx: 999_999) }.not_to raise_error
        end

        # A flag nobody set has nothing to check, and checking it anyway would
        # buy every `lain up` a round trip for a question it is not asking.
        it "asks no ceiling at all when --num-ctx is unset" do
          serving(ps_entry(model, 32_768))

          ollama_backend.context_window

          expect(a_request(:post, "http://localhost:11434/api/show")).not_to have_been_made
        end

        # The construction ORDER, which T6's fix round made user-visible and
        # which nothing pinned: `--api-base` is validated before `--num-ctx`,
        # because the ceiling lookup is the first thing in construction that
        # talks to a server and a base URL it is about to probe has to be a
        # usable one first. Asserted through a run that gets BOTH flags wrong,
        # since that is the only case in which the order is observable -- swap
        # the two lines in `#initialize` and this reads InvalidCeiling instead.
        it "refuses a bad --api-base before it asks that base for a ceiling" do
          expect { ollama_backend(api_base: "localhost:11434", num_ctx: 0) }
            .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "localhost:11434"/)
        end

        # `--num-ctx 0` is refused by {Ceiling} for being non-positive, and that
        # refusal has to come first: a zero is a flag mistake whatever the model
        # was trained to, and reordering would make the message depend on
        # whether a server happened to be up.
        it "still refuses a non-positive value in Ceiling's name, not this one" do
          trained(262_144)

          expect { ollama_backend(num_ctx: 0) }
            .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--num-ctx must be positive/)
        end
      end
    end

    # T5: unlike an unknown --provider or a missing key (both below), a bad
    # `--api-base` is not a question #provider can defer -- Endpoint checks it
    # at CONSTRUCTION, same as --num-ctx above, because `localhost:11434` (the
    # scheme-less typo) is a VALID URI and used to sail past a URI.parse guard
    # straight into a bare Faraday NoMethodError on the first turn.
    describe "--api-base" do
      it "refuses a scheme-less base at CONSTRUCTION, in the flag's own name" do
        expect { ollama_backend(api_base: "localhost:11434") }
          .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "localhost:11434"/)
      end

      it "refuses a value that does not parse as a URI at all" do
        expect { ollama_backend(api_base: "not a url") }
          .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
      end

      it "refuses before anything asks for a window or a payload" do
        expect { ollama_backend(api_base: "not a url") }.to raise_error(Lain::CLI::Backend::InvalidEndpoint)
        expect(a_request(:get, %r{/api/ps})).not_to have_been_made
      end

      # UNSET is a real answer -- "ollama's own default" -- and must not trip
      # the refusal a value with no usable scheme gets.
      it "accepts being unset" do
        serving(ps_entry(model, 32_768))

        expect(ollama_backend.context_window.window_tokens(model)).to eq(32_768)
      end

      it "is a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::InvalidEndpoint).to be < Lain::Error
      end
    end

    # A provider with no endpoint that reports a served window answers nil from
    # {Provider#context_window_tokens} without asking anything, so the book is
    # the shipped one and no probe is paid for.
    it "leaves a provider that cannot report a served window on the shipped book" do
      book = with_env("ANTHROPIC_API_KEY" => "sk-test") do
        backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64).context_window
      end

      expect(book.window_tokens("claude-opus-4-8")).to eq(1_000_000)
      expect(book.window_tokens("qwen3:4b")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
    end

    # A denominator lookup is not where a bad `--provider` or a missing key is
    # discovered. Both refusals belong to #provider's real callers, and raising
    # here would move them ahead of the chronicle open -- which is precisely
    # the ordering ChatLaunch keeps so a refusal never orphans a fresh journal.
    it "does not turn an unknown --provider into a refusal of its own" do
      backend = backend_for(provider: "gemini", model: "x", max_tokens: 64)

      expect(backend.context_window.window_tokens("x")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect { backend.provider }.to raise_error(Lain::CLI::UnknownProvider)
    end

    # The same deferral with NO `--model` and a `--num-ctx` set, which is the
    # combination that reaches it: `#model` defaults THROUGH `#provider_name`,
    # so it raises `UnknownProvider` too, and a `--num-ctx` alone resolves a
    # window -- so the model name is asked for on the answering path, outside
    # any rescue, unless it is resolved once inside one. Both examples above
    # pin the provider message and neither could reach this.
    it "does not raise for a model resolved through an unknown --provider either" do
      backend = backend_for(provider: "gemini", max_tokens: 64, num_ctx: 16_384)

      expect(backend.context_window.window_tokens("x")).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect { backend.model }.to raise_error(Lain::CLI::UnknownProvider)
    end

    # T5 UPDATED this deliberately: `--api-base "not a url"` used to be a THIRD
    # deferral -- a denominator lookup left `#provider` to raise
    # URI::InvalidURIError on its own request -- but that meant construction
    # SUCCEEDED for a base that could never serve a chat, and the same
    # scheme-less typo (`localhost:11434`) parsed as a valid URI and reached a
    # bare Faraday NoMethodError on the first real turn instead of ever
    # raising here at all. Unlike the two deferrals above, a bad `--api-base`
    # is now refused at CONSTRUCTION (see the "--api-base" examples above,
    # which is where {Backend::Endpoint} is actually exercised) -- there is no
    # backend left standing for #context_window or #provider to be asked
    # about one.
    it "refuses an unusable --api-base at construction, not as a deferred #provider failure" do
      expect { backend_for(provider: "ollama", model:, max_tokens: 64, api_base: "not a url") }
        .to raise_error(Lain::CLI::Backend::InvalidEndpoint, /--api-base "not a url"/)
    end

    it "does not turn a missing ANTHROPIC_API_KEY into a refusal of its own" do
      backend = with_env("ANTHROPIC_API_KEY" => "") do
        backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64).tap(&:context_window)
      end

      expect(backend.context_window.window_tokens("claude-opus-4-8")).to eq(1_000_000)
    end
  end

  describe "#context" do
    it "defaults the model to the selected provider's own default" do
      expect(backend_for(provider: "ollama", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "defaults to Bedrock's model when --provider bedrock and no --model" do
      expect(backend_for(provider: "bedrock", model: nil, max_tokens: 1024).context.model)
        .to eq(Lain::Provider::BedrockReference::DEFAULT_MODEL)
    end

    it "honors an explicit --model over the provider default" do
      expect(backend_for(provider: "ollama", model: "qwen3:8b", max_tokens: 1024).context.model).to eq("qwen3:8b")
    end

    it "renders the prompt slots into the system prompt by default" do
      expect(backend_for(provider: "ollama", max_tokens: 1024).context.system)
        .to eq(Lain::Prompt::Slots.load.render)
    end

    it "honors an explicit system override without touching the slots" do
      expect(backend_for(provider: "ollama", max_tokens: 1024).context(system_override: "BE TERSE").system)
        .to eq("BE TERSE")
    end

    # `--max-tokens` has no default HERE (unlike --model, resolved above from the
    # provider) -- every command declaring the flag gives Thor one, so a nil means
    # a caller built this Backend and left the ceiling out. Backend is the single
    # authority on it now that Bench's own constants are flag declarations only,
    # so this is where it has to be caught: Context answers a nil with
    # `TypeError: can't convert nil into Integer`, which is not a Lain::Error, so
    # Boundary#render passes it through as a backtrace naming Context -- a class
    # no operator has heard of. Same wound MissingAPIKey and InvalidCeiling were
    # both written for; same error class as --summarizer-max-tokens'.
    it "refuses a missing ceiling as a Lain::Error naming the flag, never a TypeError from Context" do
      expect { backend_for(provider: "ollama").context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--max-tokens is not set/)
    end

    it "refuses an explicit nil ceiling the same way an absent key is refused" do
      expect { backend_for(provider: "ollama", max_tokens: nil).context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--max-tokens/)
    end

    # The two ceiling flags are two different mistakes to make, and one Ceiling
    # object now answers for both -- so the refusal has to name the one that was
    # actually wrong, or it sends the operator to the other flag.
    it "names --max-tokens, never the summarizer's flag, when the chat tier's is missing" do
      expect { backend_for(provider: "ollama").context }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling) do |error|
          expect(error.message).not_to include("summarizer")
        end
    end
  end

  # The object both ceiling flags now go through. Exercised here rather than in a
  # file of its own, as Backend::Summarizer and Backend::SpanSummarizer are: the
  # flag NAME is the field that makes it worth extracting, and the two callers
  # above and below are what prove each flag keeps its own voice.
  describe Lain::CLI::Backend::Ceiling do
    def ceiling(value) = described_class.new(flag: "--flag", value:)

    it "answers the parsed ceiling for a positive value" do
      expect(ceiling(64).tokens).to eq(64)
      expect(ceiling("64").tokens).to eq(64)
    end

    it "refuses an unset ceiling, naming its own flag" do
      expect { ceiling(nil).tokens }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--flag is not set/)
    end

    # 0 is TRUTHY, so no `||` downstream falls back for it and Request#max_tokens
    # only does `Integer()` -- the provider is what 400s, three layers away.
    it "refuses zero and negative ceilings, quoting the value" do
      expect { ceiling(0).tokens }.to raise_error(Lain::CLI::Backend::InvalidCeiling, /--flag must be positive, got 0/)
      expect { ceiling(-1).tokens }.to raise_error(Lain::CLI::Backend::InvalidCeiling, /got -1/)
    end

    # Unchanged from the inline `Integer(knob(...))` this replaced: a non-numeric
    # ceiling is a parser or programmer bug, and stays a loud ArgumentError rather
    # than being dressed up as an operator's flag mistake.
    it "leaves an unparseable ceiling as the ArgumentError it always was" do
      expect { ceiling("wide").tokens }.to raise_error(ArgumentError)
    end
  end

  # RES4: the exe's research subagent used to hand-assemble a SpawnPolicy
  # inline (exe/lain:293-297) instead of naming a catalog role, so the child's
  # capability set could drift from {Lain::Role::Catalog}'s own idea of what
  # "researcher" means. #spawn_policy resolves through the catalog instead --
  # the same "one seam decides" shape #provider and #context already give
  # --provider and --model.
  describe "#spawn_policy" do
    # SpawnPolicy's `prefix`/`posture` normalize to freshly-built strategy
    # objects (PrefixStrategy::Fresh.new, AttenuationPosture::Schema.new) with
    # no custom `==`, so two structurally-identical policies are NOT `==` by
    # Data's generated equality (it falls through to Object#==, i.e. identity)
    # -- comparing the policy "field-for-field" means comparing each field's
    # own value (a strategy's `#label`, and `only`), not `==` on the whole.
    # A smoke check only: WHICH tools the researcher holds is pinned at the seam
    # that renders them (role_prelude_wiring_spec's "keeps the researcher
    # tree-read-only"), and the next example proves this method is that
    # catalog's delegate rather than a parallel construction. Re-listing the
    # only-set here just gave the catalog a second place to drift from.
    it "resolves the researcher policy from the catalog: fresh prefix, schema posture" do
      resolved = backend.spawn_policy(:researcher)

      expect([resolved.prefix.label, resolved.posture.label]).to eq(%w[fresh schema])
    end

    it "comes from Role::Catalog.fetch, not a parallel construction -- attenuates identically" do
      union = Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::EditFile.new,
                                 Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])

      resolved = backend.spawn_policy(:researcher)
      cataloged = Lain::Role::Catalog.fetch(:researcher).spawn_policy

      expect(resolved.attenuate(union).names).to eq(cataloged.attenuate(union).names)
    end

    it "fails loudly on an uncataloged role name, naming the catalog (Role::Catalog's own refusal)" do
      expect { backend.spawn_policy(:chef) }
        .to raise_error(Lain::Role::Catalog::Unknown, /chef.*researcher/m)
    end
  end

  # RES4's escalation trigger: Context#cache_marked always marks the LAST
  # system block, and CacheBreakpoints budgets exactly ONE system cache slot
  # (the T24 follow-up) -- Anthropic's cache_control cap is 4 breakpoints, so
  # a second system mark here is a live 400 risk, not a style nit. A role's
  # prelude is TWO segments (the shared bulk, then the role tail --
  # {Lain::Role#prelude_segments}); rendering them as two ordinary text
  # blocks -- neither pre-marked -- through Context must spend that ONE mark
  # on the tail and leave the bulk unmarked, not double it. This spec is the
  # guard: if it ever found two marked blocks, that is the recorded risk, and
  # spending it is the orchestrator's call, not this glue's.
  describe "a role prelude rendered through Context spends exactly one cache mark" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    it "marks exactly one system block, not one per prelude segment" do
      role = Lain::Role::Catalog.fetch(:researcher)
      bulk, tail = role.prelude_segments(slots: backend.slots)
      context = Lain::Context.new(
        model: "probe", max_tokens: 64,
        system: [{ "type" => "text", "text" => bulk }, { "type" => "text", "text" => tail }]
      )

      request = context.render(timeline:, toolset: Lain::Toolset.new)
      marked = request.system.select { |block| block["cache"] }

      expect(marked.size).to eq(1)
      expect(marked.first["text"]).to eq(tail)
    end
  end

  # The loaded Slots are exposed (not just the rendered String) so the bench
  # record path can emit ONE Telemetry::SlotFills built from the exact slots
  # #context rendered, without a second disk read.
  describe "#slots" do
    it "exposes the loaded Prompt::Slots" do
      expect(backend.slots).to be_a(Lain::Prompt::Slots)
    end

    it "loads the slots once and memoizes them" do
      expect(backend.slots).to be(backend.slots)
    end
  end

  # T40: the slots are HALF a pair. This object is the one owner of both halves
  # now -- before, it owned the slots while Wiring separately owned the catalog,
  # and the two travelled onward as two keywords. One library, one read, one
  # owner; #slots is the library's, so the bench path's reader is unchanged.
  describe "#library" do
    it "exposes the session's ONE Skill::Library, memoized" do
      expect(backend.library).to be_a(Lain::Skill::Library)
      expect(backend.library).to be(backend.library)
    end

    it "answers #slots out of that library, so there is only one read of the tree" do
      expect(backend.slots).to be(backend.library.slots)
    end

    # Why the library cannot live in Wiring: the system prompt is rendered HERE,
    # from the slots half, at a point above every other reader.
    #
    # Asserted as the CHAIN (#context -> #slots -> library.slots) and not as `eq`
    # against a second render, because the two are not the same claim and the
    # weaker one is worthless here: the tree does not change between two reads,
    # so `eq` holds just as well when #context does its OWN Prompt::Slots.load --
    # which is precisely the bug this example's name denies. The T40 panel caught
    # that; the example survived the mutation it is named for.
    #
    # The reader is stubbed rather than the Slots instance because a Slots is
    # frozen and rspec-mocks refuses to proxy a frozen object. The last link of
    # the chain is pinned by the example above.
    it "renders the system prompt from the library's slots" do
      wired = backend_for(provider: "ollama", max_tokens: 1024)
      allow(wired).to receive(:slots).and_return(instance_double(Lain::Prompt::Slots, render: "SENTINEL-T40"))

      expect(wired.context.system).to eq("SENTINEL-T40")
    end
  end

  # A8: everything the live-wiring chunk built converges here. `lain chat`
  # compacts by DEFAULT -- eager summaries when the local tier answers, honest
  # elision when it does not -- so these pin the factories the exe's flags
  # resolve through, including the memoization that makes them RUN state rather
  # than per-call values (#context is deliberately the opposite: a fresh Context
  # at six call sites).
  describe "compaction wiring" do
    let(:journal) { RecordingChannel.new }
    # `pinned?` too: the per-turn path asks the Session which turns compaction
    # may not elide (B2), and a verifying double answers only what it declares.
    let(:session) { instance_double(Lain::Session, plan_step_completed?: false, pinned?: false) }
    let(:profile) { Lain::CacheProfile::ANTHROPIC }
    let(:toolset) { Lain::Toolset.new([]) }

    def compacting_backend(**overrides)
      backend_for(provider: "anthropic", model: "claude-opus-4-8", max_tokens: 64, **overrides)
    end

    def source_for(**overrides)
      compacting_backend(**overrides).pipeline_source(cache_profile: profile, journal:)
    end

    # A WELL-FORMED conversation -- alternating from `user` -- and substantial
    # enough that a rewrite actually SHRINKS it (Source#shrinks? refuses one
    # that would not).
    #
    # It used to be a run of `user` turns each carrying an orphan
    # `tool_result`, which the Messages API would reject outright. That was
    # invisible while compaction was a render-time projection and is not now:
    # {Compaction::Derivation} validates the chain it derives through
    # {Context::Conversation} and REFUSES an invalid one, so an ill-formed
    # fixture measures a compaction that never happens (`compacted: false`,
    # nothing raised). Tool blocks moved out with the orphans: the tier that
    # keys on them is exercised in `spec/lain/compaction/source_spec.rb`, and
    # what this file is about is which flags reach which collaborator.
    def history(size)
      (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
        body = "result number #{index}: #{"the quick brown fox jumped over the lazy dog. " * 20}"
        line.commit(role: index.odd? ? "user" : "assistant", content: [{ "type" => "text", "text" => body }])
      end
    end

    # One backend, one source, one turn -- the shape the live path takes.
    def decide(timeline, usage: nil, cache_profile: profile, **overrides)
      backend = compacting_backend(**overrides)
      backend.pipeline_source(cache_profile:, journal:)
             .context_for(base: backend.context, timeline:, usage:, session:)
    end

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    it "builds a live compaction Source when no compaction flags are given at all" do
      expect(source_for).to be_a(Lain::Compaction::Source)
    end

    it "builds the Null source under --no-compact" do
      expect(source_for(compact: false)).to be(Lain::Agent::PipelineSource::Null)
    end

    # AC2's second half: with compaction off, the turn's Context is the base
    # ITSELF, so the Request is byte-identical to one rendered with no source
    # wired at all -- not merely equivalent.
    it "renders byte-identically to an unwired Context under --no-compact" do
      backend = compacting_backend(compact: false)
      timeline = history(8)
      base = backend.context

      turn = backend.pipeline_source(cache_profile: profile, journal:)
                    .context_for(base:, timeline:, usage: nil, session:)

      expect(turn).to be(base)
      expect(Lain::Canonical.dump(turn.render(timeline:, toolset:).cache_payload))
        .to eq(Lain::Canonical.dump(base.render(timeline:, toolset:).cache_payload))
    end

    # The Observer is the PRODUCTION mount (summarizing.rb:38-45): it and the
    # Summarizing decorator are alternatives, never both against one Eager --
    # #fire consumes the digest before spawning, so whichever fires first spends
    # it and the other misses forever.
    it "wires the Summarizing::Observer over the one Eager the source reads" do
      backend = compacting_backend

      expect(backend.tool_observer).to be_a(Lain::Effect::Handler::Summarizing::Observer)
      expect(backend.tool_observer.eager).to be(backend.eager)
      expect(backend.pipeline_source(cache_profile: profile, journal:)
                    .eager).to be(backend.eager)
    end

    it "observes nothing under --no-compact -- no summary is ever read, so none is fired" do
      expect(compacting_backend(compact: false).tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
    end

    # AC6. Cold's accumulated warmth and the Eager's fired summaries are run
    # state: a factory rebuilt per call resets both, silently, every turn.
    it "builds the source, the eager, and the observer once per run" do
      backend = compacting_backend

      expect(backend.pipeline_source(cache_profile: profile, journal:))
        .to be(backend.pipeline_source(cache_profile: profile, journal:))
      expect(backend.eager).to be(backend.eager)
      expect(backend.tool_observer).to be(backend.tool_observer)
    end

    # The other half of that memo, and the half that could hurt: a memoized
    # factory answers its FIRST caller's arguments forever. With one wiring
    # site that is a cache hit; a second, DIFFERING call would silently hand
    # back a Source bound to the first journal, and every compaction decision
    # would land in Channel::Null with nothing failing -- the precise
    # silent-degrade shape this chunk exists to end. So it is loud.
    describe "a second, differing call" do
      it "refuses one that would bind a different journal" do
        backend = compacting_backend
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: profile) }
          .to raise_error(Lain::CLI::Backend::Rebound, /pipeline_source/)
      end

      it "refuses one that would bind a different cache profile" do
        backend = compacting_backend
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:) }
          .to raise_error(Lain::CLI::Backend::Rebound, /cache profile/i)
      end

      # The guard is about the BINDING, not about what got built, so it holds
      # on the Null branch too -- where the arguments are ignored entirely and
      # a mis-wiring would otherwise be even harder to see.
      it "refuses one under --no-compact as well, where the arguments are unused" do
        backend = compacting_backend(compact: false)
        backend.pipeline_source(cache_profile: profile, journal:)

        expect { backend.pipeline_source(cache_profile: profile) }
          .to raise_error(Lain::CLI::Backend::Rebound)
      end

      it "names a Lain::Error, so the exe presents it cleanly rather than as a backtrace" do
        expect(Lain::CLI::Backend::Rebound).to be < Lain::Error
      end
    end

    # AC4. `--provider ollama` and `--provider bedrock` name models no
    # Anthropic-shaped window table can carry, so ContextWindow.default falls
    # back rather than raising -- an unsupported provider must still START.
    # 7_500 used tokens is under 0.9 of every real entry and over 0.9 of the
    # 8_192 fallback, so this turn DOES cross the trigger ratio -- and the
    # trigger is withheld anyway, because a fallback is a guess and a guess may
    # not authorise an irreversible rewrite. That is the whole of F3: the QA run
    # compacted three times at 75-78% of a real 32_768 window.
    #
    # The denominator and the provenance are both asserted rather than inferred
    # from the absent signal, because empty signals alone would also be
    # satisfied by any window >= 8_334.
    #
    # T10 made the fallback the SECOND answer rather than the only one, so the
    # silent server is now stated rather than assumed: /api/ps answers with
    # nothing resident, which is exactly when the conservative fallback is
    # still what a run measures against.
    it "builds against the conservative fallback window for a model in no table, and chat starts" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                            compact_keep: 1, compact_bytes: 10_000_000)
      source = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      source.context_for(base: backend.context, timeline: history(6), usage: 7_500, session:)

      expect(decisions.last.signals).to eq([])
      expect(decisions.last.compacted).to be(false)
      expect(decisions.last.window_tokens).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(decisions.last.provenance).to eq(Lain::ContextWindow::GUESSED)
    end

    # The same 7,500 tokens, against a server that says it is serving 32,768:
    # 22.9% full, so nothing fires. The signal is what MOVED, which is the
    # whole card -- the numerator never changed.
    it "measures the same turn against a served window, and does not fire" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => [{ "name" => "qwen3:4b", "model" => "qwen3:4b",
                                                      "context_length" => 32_768 }]))
      backend = backend_for(provider: "ollama", model: "qwen3:4b", max_tokens: 64,
                            compact_keep: 1, compact_bytes: 10_000_000)
      source = backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      source.context_for(base: backend.context, timeline: history(6), usage: 7_500, session:)

      expect(decisions.last.signals).to be_empty
      expect(decisions.last.window_tokens).to eq(32_768)
      expect(decisions.last.used_tokens).to eq(7_500)
    end

    # A nil or blank --model is a WIRING bug, not an unsupported provider, and
    # ContextWindow says so loudly (context_window.rb:104-108) rather than
    # degrading to a fallback that would silently never fire.
    #
    # C1 moved the lookup off construction and onto the render, so the raise
    # lands on the first TURN rather than at startup -- later, but no quieter,
    # which is the ruling. The Source is built here without incident; the turn
    # is what refuses.
    it "refuses a blank --model loudly on the first turn rather than falling back" do
      stub_request(:get, "http://localhost:11434/api/ps")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("models" => []))
      backend = backend_for(provider: "ollama", model: "  ", max_tokens: 64)
      source = backend.pipeline_source(cache_profile: profile, journal:)

      expect { source.context_for(base: backend.context, timeline: history(2), usage: nil, session:) }
        .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    # AC5.
    it "schedules against an overridden byte threshold" do
      decide(history(6), compact_bytes: 200, compact_keep: 1)

      expect(decisions.last.signals).to include(:token_threshold)
    end

    it "leaves the default threshold far above a short history, so a fresh chat does not compact" do
      decide(history(6), compact_keep: 1)

      expect(decisions.last.signals).to be_empty
      expect(decisions.last.compacted).to be(false)
    end

    # The decision lands on EVERY turn, deferring ones included: Agent#render_request
    # delegates to a collaborator that reports nothing back, so this record is the
    # only trace the choice was made -- and on a bench whose deliverable is
    # comparability, an unrecorded decision is a missing measurement.
    it "journals a decision even when it defers" do
      decide(history(3), compact_keep: 1)

      expect(decisions.size).to eq(1)
      expect(decisions.last.compacted).to be(false)
    end

    # T9. `--compact-strategy` is DECLARED by exe/lain and RESOLVED by
    # CLI::CompactionStrategy; this is the seam that reads it. Without this call
    # site the flag ships parsed and consumed by nobody -- F7's "unwired in
    # production" pattern, and the exact direction `chat_flags_spec.rb` cannot
    # see (it fails on read-but-undeclared, never on declared-but-unread).
    describe "--compact-strategy" do
      def strategy_of(backend)
        source_for_backend(backend).instance_variable_get(:@derived).instance_variable_get(:@strategy)
      end

      def source_for_backend(backend) = backend.pipeline_source(cache_profile: profile, journal:)

      it "resolves the named strategy and injects it into the Source" do
        expect(strategy_of(compacting_backend(compact_strategy: "elide")))
          .to be_a(Lain::Compaction::Strategy::Elide)
      end

      it "builds the summarizing strategy over a RECORDED oracle, never a bare model tier" do
        strategy = strategy_of(compacting_backend(compact_strategy: "summarizing", provider: "ollama"))

        expect(strategy).to be_a(Lain::Compaction::Strategy::Summarizing)
        expect(strategy.instance_variable_get(:@oracle)).to be_a(Lain::Oracle::Recorded::Journaling)
      end

      it "refuses an unknown name as a Lain::Error, naming the flag and the valid set" do
        expect { source_for_backend(compacting_backend(compact_strategy: "vibes")) }
          .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /--compact-strategy.*summarizing/m)
      end

      # An UNSET flag is deliberately not CompactionStrategy::DEFAULT: the
      # un-flagged run keeps the eager tier it already fires and snapshots, and
      # naming a strategy is what opts into the seam. See {SpanSummarizer}.
      it "leaves the un-flagged run on its own eager tier rather than resolving a default" do
        expect(strategy_of(compacting_backend)).to be_nil
      end

      # The tier a down summarizer reports through. With the Null sink "the
      # summarizer is unreachable" and "compaction is off" are the same silence.
      it "threads the run's sink into the strategy" do
        sink = Lain::Sink::Null.new
        backend = compacting_backend(compact_strategy: "summarizing", provider: "ollama")
        strategy = backend.pipeline_source(cache_profile: profile, journal:, sink:)
                          .instance_variable_get(:@derived).instance_variable_get(:@strategy)

        expect(strategy.instance_variable_get(:@sink)).to be(sink)
      end

      # Resolved ONCE, with the memoized Source. #pipeline_source raises Rebound
      # on a differing second call and a model-backed strategy holds a memo, so
      # a strategy fetched per turn would be a second, disconnected one.
      it "resolves the strategy once for the run" do
        backend = compacting_backend(compact_strategy: "elide")

        expect(strategy_of(backend)).to be(strategy_of(backend))
      end
    end
  end

  # {Backend#same_provider?} compares the RAW `--provider` value rather than
  # going through {Backend#provider_name}, and that is the one place in this
  # class that reads a provider flag outside the validated seam. The reason is
  # testable rather than merely argued, so it is tested: with no chat provider in
  # the hash there is nothing for the summarizer tier to be the SAME as, so it
  # answers its own tier's default instead of refusing about a flag it does not
  # read. Routing the comparison through `provider_name` -- the alternative --
  # leaves the rest of the suite green, so without these two examples the choice
  # is defended by prose alone.
  describe "#summarizer_model with no chat provider in the option hash" do
    it "resolves the summarizer tier without raising about --provider" do
      backend = backend_for(summarizer_provider: "ollama", model: "qwen3-coder:30b")

      expect { backend.summarizer_model }.not_to raise_error
      expect(backend.summarizer_model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # The other half, and why the first is not a hole: the missing flag is still
    # refused loudly by the tier that actually reads it.
    it "still refuses the chat tier itself, so the missing flag is not silently forgiven" do
      backend = backend_for(summarizer_provider: "ollama", model: "qwen3-coder:30b")

      expect { backend.provider }.to raise_error(Lain::CLI::UnknownProvider, /unknown provider nil/)
    end
  end

  # A1. The eager summarizer is a SELECTABLE tier now, not a hardcoded local
  # one, and its spend lands on the record. Before this, #summary_oracle built a
  # bare Oracle::Model over Ollama and wrapped nothing, so eager summary Q&A
  # produced no Telemetry::OracleAnswer at all on the live chat path -- pointing
  # it at a paid model would have spent tokens with no trace of the spend.
  #
  # The default PROVIDER is unchanged (local Ollama), resolved through the SAME
  # validated PROVIDERS set the chat tier uses, so `--summarizer-provider` cannot
  # mean something `--provider` does not. The default MODEL is no longer fixed to
  # that provider's own: when both tiers name one provider it follows the chat's
  # `--model`, so the examples below that pin an Ollama chat read through the
  # inheritance branch and say so.
  describe "#summary_oracle" do
    let(:journal) { RecordingChannel.new }

    def summarizer_for(**overrides) = backend_for(provider: "ollama", max_tokens: 64, **overrides)

    # The journaling wrap is OUTERMOST (A3 slots a router above it), so the live
    # tier that actually pays is one layer in.
    # The nesting the run is wired in: RoutedSummarizer(Journaling(Model)).
    def journaling_of(backend) = backend.send(:summary_oracle).instance_variable_get(:@inner)
    def tier_of(backend) = journaling_of(backend).instance_variable_get(:@inner)

    # A local reply the summarizer schema accepts, priced with a REAL usage so
    # the journaled cost is a genuine count rather than the zero identity.
    def answering_provider
      reply = Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"it listed three files"}) }],
                                 stop_reason: :end_turn,
                                 usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
      Lain::Provider::Mock.new(responses: [reply])
    end

    def answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

    # The MODEL here arrives by inheritance, not by the tier's own default: an
    # ollama chat with `--model` unset resolves to Ollama's default, and the
    # summarizer shares its provider, so the two are the same string by two
    # different routes. What this example uniquely pins is the PROVIDER; the
    # tier's own default model is pinned by the cross-provider example below,
    # where nothing can be inherited.
    it "defaults to today's local tier -- Provider::Ollama, at the model the chat resolved" do
      tier = tier_of(summarizer_for)

      expect(tier.instance_variable_get(:@provider)).to be_a(Lain::Provider::Ollama)
      expect(tier.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    # A3: the router goes ABOVE the journaling wrap, not below it. Below, a
    # custom answer would be journaled as an oracle call some model was billed
    # for; above, it never reaches the record at all and a fallthrough is
    # journaled exactly once. The order is forced besides -- Recorded::Journaling
    # defines neither #model nor #usage, so the other nesting raises.
    it "wraps the journaled live tier in the routed summarizer, outermost" do
      expect(summarizer_for.send(:summary_oracle)).to be_a(Lain::Oracle::RoutedSummarizer)
      expect(journaling_of(summarizer_for)).to be_a(Lain::Oracle::Recorded::Journaling)
      expect(tier_of(summarizer_for)).to be_a(Lain::Oracle::Model)
    end

    # The project's own `.lain/summarizers.rb`, loaded once per oracle build.
    # Lain's own tree declares none, so the catalog is empty and every result
    # falls through -- which is exactly what the journaling examples below rely
    # on.
    it "routes through the project's declared summarizer catalog" do
      catalog = summarizer_for.send(:summary_oracle).instance_variable_get(:@catalog)

      expect(catalog).to be_a(Lain::Summarizer::Catalog)
      expect(catalog).to be_empty
    end

    # The point of the flag: compressing a tool result is a different job from
    # answering the conversation, so it gets its own tier. A local chat can buy
    # a better summarizer, and a frontier chat can keep summarizing for free.
    it "points the summarizer at a paid provider while the chat model stays local" do
      backend = summarizer_for(summarizer_provider: "anthropic")
      chat, summary = with_env("ANTHROPIC_API_KEY" => "sk-test") { [backend.provider, tier_of(backend)] }

      expect(chat).to be_a(Lain::Provider::Ollama)
      expect(summary.instance_variable_get(:@provider)).to be_a(Lain::Provider::Anthropic)
      expect(summary.model).to eq(Lain::Provider::Anthropic::DEFAULT_MODEL)
    end

    # The other side of that flag, and the case the GPU pays for: one local
    # provider serving both tiers holds ONE resident model, so a summarizer left
    # at the provider's default evicts the chat model on every compaction and
    # the next turn reloads it -- 84.0s against 7.5s, measured. Same provider
    # means the chat's model is already loaded, which makes it the right default.
    it "inherits the chat's --model when both tiers name the same provider" do
      expect(tier_of(summarizer_for(model: "qwen3-coder:30b")).model).to eq("qwen3-coder:30b")
    end

    it "honors an explicit --summarizer-model over the tier provider's default" do
      expect(tier_of(summarizer_for(summarizer_model: "qwen3:8b")).model).to eq("qwen3:8b")
    end

    it "honors an explicit --summarizer-model over the chat's own model" do
      expect(tier_of(summarizer_for(model: "qwen3-coder:30b", summarizer_model: "gemma3:12b")).model)
        .to eq("gemma3:12b")
    end

    # Resolved through Backend#provider's own PROVIDERS set, not a second copy,
    # so the two flags cannot drift about what a provider name means. The
    # refusal names WHICH flag was wrong -- "provider" and "summarizer provider"
    # are different mistakes to make.
    it "refuses an unknown summarizer provider by name, naming the valid set" do
      expect { tier_of(summarizer_for(summarizer_provider: "notreal")) }
        .to raise_error(Lain::CLI::UnknownProvider,
                        /unknown summarizer provider "notreal", expected one of.*anthropic.*ollama/m)
    end

    it "still names the chat flag when --provider is the wrong one" do
      expect { summarizer_for(provider: "gemini").provider }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown provider "gemini"/)
    end

    it "defaults the token ceiling to Oracle::Model::DEFAULT_MAX_TOKENS" do
      expect(tier_of(summarizer_for).instance_variable_get(:@max_tokens))
        .to eq(Lain::Oracle::Model::DEFAULT_MAX_TOKENS)
    end

    it "honors --summarizer-max-tokens" do
      expect(tier_of(summarizer_for(summarizer_max_tokens: 256)).instance_variable_get(:@max_tokens)).to eq(256)
    end

    # 0 is TRUTHY in Ruby, so #knob's `||` never falls back for it: a zero or
    # negative ceiling reaches Request#max_tokens, which only does Integer()
    # with no range check, and the provider 400s. Oracle::Eager's task boundary
    # then swallows that BY DESIGN, so the only symptom a user ever sees is
    # "compaction quietly stopped summarizing" -- exactly the silent failure
    # this card exists to end. Refused at the seam, the shape
    # {Lain::Compaction.validate_keep_last} already uses for keep_last.
    it "refuses a non-positive summarizer ceiling rather than 400ing silently later" do
      expect { summarizer_for(summarizer_max_tokens: 0) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /--summarizer-max-tokens must be positive, got 0/)
      expect { summarizer_for(summarizer_max_tokens: -1) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /got -1/)
    end

    # Named Lain error, not Head's bare ArgumentError: a bad flag is user error
    # and the exe's `rescue Lain::Error` is what turns it into a clean
    # Thor::Error instead of a backtrace -- {MissingAPIKey}'s own reasoning.
    it "raises a Lain::Error for a bad ceiling (so the exe presents it cleanly)" do
      expect(Lain::CLI::Backend::InvalidCeiling).to be < Lain::Error
    end

    # `--provider` refuses on EVERY run, because #provider always runs. The
    # summarizer flags did not: under --no-compact #tool_observer answers the
    # Null, #summary_oracle is never built, and #validated never ran -- so a
    # typo was accepted in exactly one configuration. An asymmetry a user hits
    # in only one mode is one they misread, so both flags are refused at
    # CONSTRUCTION, which is the one path every command takes.
    describe "under --no-compact, where no summarizer tier is ever built" do
      it "still refuses a typo'd --summarizer-provider" do
        expect { summarizer_for(compact: false, summarizer_provider: "notreal") }
          .to raise_error(Lain::CLI::UnknownProvider, /unknown summarizer provider "notreal"/)
      end

      it "still refuses a non-positive --summarizer-max-tokens" do
        expect { summarizer_for(compact: false, summarizer_max_tokens: 0) }
          .to raise_error(Lain::CLI::Backend::InvalidCeiling)
      end

      it "builds normally when both flags are well-formed" do
        expect(summarizer_for(compact: false).tool_observer).to be_a(Lain::Agent::ToolRunner::Observer::Null)
      end
    end

    # The bug this card fixes: a summarizer call is a model call, and a model
    # call that does not reach the Journal is spend the bench cannot see.
    it "journals a Telemetry::OracleAnswer carrying the model and a non-empty usage" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
      backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      Sync { backend.send(:summary_oracle).ask(source: "a tool result").await }

      expect(answers.last.oracle_digest).to eq(Lain::Oracle::Summarize.definition.digest)
      expect(answers.last.model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(answers.last.usage).not_to be_empty
      expect(answers.last.usage).to include("input_tokens" => 12, "output_tokens" => 7)
      expect(answers.last.question).to include("a tool result")
    end

    # Nothing orders #tool_observer (which builds the one Eager, and with it the
    # oracle) against #pipeline_source (which binds the run's journal):
    # CompactionMount happens to reach the journal first only because a Hash
    # literal evaluates left to right. A wrap that captured its destination at
    # construction would hold Channel::Null for the whole run and journal
    # nothing, with nothing raising -- so the destination is resolved per EVENT.
    it "records a summary fired through an Eager built BEFORE the journal was bound" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)
      oracle = backend.eager.oracle
      backend.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)

      Sync { oracle.ask(source: "a tool result").await }

      expect(answers.size).to eq(1)
    end

    # And with no journal bound at all -- a bench path that never calls
    # #pipeline_source -- the wrap still answers, into the Null channel.
    it "answers with no journal bound at all, sending the record nowhere" do
      backend = summarizer_for
      allow(backend).to receive(:summarizer_provider).and_return(answering_provider)

      answer = Sync { backend.send(:summary_oracle).ask(source: "a tool result").await }

      expect(answer.summary).to eq("it listed three files")
    end
  end

  # AC: --temperature 0 --seed 7 reach the sampler extra (Request#extra), but
  # NOT the Request digest -- a sampler knob is not a prompt.
  describe "temperature and seed threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def render(**options)
      backend_for(max_tokens: 1024, **options).context.render(timeline:, toolset: Lain::Toolset.new)
    end

    it "carries options.temperature 0 and options.seed 7 into the encoded Ollama payload" do
      request = render(provider: "ollama", model: nil, temperature: 0, seed: 7)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to include(temperature: 0, seed: 7)
    end

    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = render(provider: "ollama", model: nil, temperature: 0, seed: 7)
      plain = render(provider: "ollama", model: nil, temperature: nil, seed: nil)
      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end

    it "omits absent sampler keys entirely (0 is present, nil is not)" do
      request = render(provider: "ollama", model: nil, temperature: 0, seed: nil)
      payload = Lain::Provider::Ollama.new.encode(request)
      expect(payload[:options]).to eq(temperature: 0)
    end
  end

  # T11 AC: the two throughput knobs reach the wire the same way temperature
  # and seed do -- through #sampler_extra, so an UNSET flag leaves the options
  # hash untouched. Defaulting num_batch inside the encoder instead would put
  # an `options` key on every ollama request in the suite; the third example is
  # what pins that it did not happen.
  describe "num_batch and num_ctx threading" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    def payload_for(**options)
      request = backend_for(max_tokens: 1024, provider: "ollama", model: nil, **options)
                .context.render(timeline:, toolset: Lain::Toolset.new)
      Lain::Provider::Ollama.new.encode(request)
    end

    it "carries an operator-set batch size into the encoded request options" do
      expect(payload_for(num_batch: 2048)[:options]).to eq(num_batch: 2048)
    end

    it "carries an operator-set context length into the encoded request options" do
      expect(payload_for(num_ctx: 8192)[:options]).to eq(num_ctx: 8192)
    end

    it "emits no options key at all when no sampler flag was given" do
      expect(payload_for.key?(:options)).to be(false)
    end

    # A sampler knob is not a prompt: the same cache-identity claim temperature
    # and seed already carry, restated for the two keys that are new here.
    it "renders a Request whose cache_payload is identical to the flagless render" do
      tuned = backend_for(max_tokens: 1024, provider: "ollama", model: nil, num_batch: 2048, num_ctx: 8192)
              .context.render(timeline:, toolset: Lain::Toolset.new)
      plain = backend_for(max_tokens: 1024, provider: "ollama", model: nil)
              .context.render(timeline:, toolset: Lain::Toolset.new)

      expect(tuned.cache_payload).to eq(plain.cache_payload)
      expect(tuned).to have_same_digest_as(plain)
    end
  end
end
