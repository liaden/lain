# frozen_string_literal: true

# WHOSE ollama, asked of one value. The loopback arm and the hosted one answered
# the same eleven messages from two classes that shared no code; this file asks
# both sets of questions of the single value that replaced them, and the shared
# group below is still the only written-down copy of the message set.
RSpec.describe Lain::Provider::Ollama::Deployment do
  # WHY THIS FILE CARRIES ITS OWN SHAREABILITY CHECKS. `GenericBuild` hands the
  # SAME dummy to every member, and the only dummy this constructor accepts for
  # both members at once is `nil` -- so the sweep in
  # `spec/value_object_shareability_spec.rb` reaches the LOOPBACK arm and never
  # the hosted one. Three examples here stand in for the slot the hosted arm
  # does not occupy: the shared group's "holds no reachable mutable state" and
  # "answers headers that are themselves deeply frozen", plus "holds no
  # reachable mutable state even when handed an unfrozen key" below. All three
  # were confirmed to fail under mutation. Do not "restore coverage" by
  # loosening the key refusal -- the refusal is the point, and the sweep is the
  # weaker of the two guards.

  # Unfrozen ON PURPOSE. A literal in this `frozen_string_literal: true` file is
  # already frozen, which makes the `.freeze` in the credential path look
  # load-bearing when nothing would notice its removal. Real callers pass
  # `ENV["OLLAMA_API_KEY"]`, which is not frozen -- and stored as given it makes
  # `Ractor.shareable?` answer false.
  let(:key) { +"sk-ollama-not-a-real-key" }

  # Unset, not merely absent: a developer with the variable exported would
  # otherwise measure their own machine's width instead of the default.
  around { |example| with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => nil, &example) }

  describe "the loopback arm" do
    subject(:deployment) { described_class.local }

    it_behaves_like "an ollama deployment", counterpart: -> { described_class.cloud(api_key: +"sk-counterpart") }

    it "dials the base the transport already defaults to" do
      expect(deployment.api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
    end

    it "carries no authorization: a loopback server asks for none" do
      expect(deployment.headers).to eq({})
    end

    it "is local, which is what admission and the secret-read oracle both read" do
      expect(deployment.local?).to be(true)
    end

    it "claims a loaded-runner endpoint, because /api/ps means something here" do
      expect(deployment.runner_status?).to be(true)
    end

    it "claims a model-metadata endpoint, because /api/show answers here" do
      expect(deployment.model_metadata?).to be(true)
    end

    # The restatement guarantee, pinned against a LITERAL. Pinned against
    # `Provider::Ollama::CAPABILITIES` it would compare a value with itself,
    # since that constant now reads back from here.
    it "restates the arm's capability list unchanged" do
      expect(deployment.capabilities).to eq(%i[streaming structured_output])
    end

    # A deployment states what the WIRE can do. `:thinking` is a property of
    # the model file -- one server serves models that have it beside models
    # that do not -- so it is answered per model by
    # `Provider::Ollama#model_capabilities` and there is one source for it.
    it "makes no provider-wide claim about thinking, which is per model" do
      expect(deployment.capabilities).not_to include(:thinking)
    end

    # The delegation itself, stated separately so the pair above cannot silently
    # become the same assertion twice: what an outside reader asks the PROVIDER
    # for is what this deployment answers.
    it "is what a bare provider answers when asked for its capabilities" do
      expect(Lain::Provider::Ollama.new.capabilities).to eq(deployment.capabilities)
    end

    it "does not cache, which is the honest flat-cost answer for a local server" do
      expect(deployment.cache_profile).to eq(Lain::CacheProfile::NO_CACHING)
    end

    # Six minutes of a model thinking is this arm's honest shape, and the
    # vendored 300/3 envelope is what the whole ollama suite is measured
    # against.
    it "leaves the vendored envelope exactly where it was" do
      expect([deployment.request_timeout, deployment.max_retries]).to eq([300, 3])
    end

    # nil, not 1: `Provider::Admission.build` already answers 1 for a local
    # endpoint, and a DECLARED 1 here would take precedence over the locality
    # rule and hide it. "Nobody said" is the true answer.
    it "declares no admission width, leaving the locality rule in charge" do
      expect(deployment.admission_width).to be_nil
    end

    # A width belongs to a metered plan. Refused rather than dropped: a keyword
    # a constructor accepts and then ignores is how a caller's mistake becomes
    # invisible at the one site that could have caught it.
    it "refuses to be built with an admission width, which only a metered plan has" do
      expect { described_class.new(admission_width: 3) }.to raise_error(ArgumentError, /width/)
    end

    it "writes the loopback base onto a configuration" do
      config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
      expect(config.ollama_api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
    end

    it "writes the vendored envelope onto a configuration, moving no measurement" do
      config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
      expect([config.request_timeout, config.max_retries]).to eq([300, 3])
    end

    it "writes no api key onto a fresh configuration" do
      config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
      expect(config.ollama_api_key).to be_nil
    end

    # THE EXAMPLE THAT SHOULD HAVE CAUGHT IT. The version above asserts against
    # a fresh Configuration, which is the one state where a stray key cannot
    # exist -- so it read as a guard while being blind to the only thing it
    # guarded against. A loopback config carrying an ollama.com Bearer sends
    # that key, in plaintext, to whatever is listening on port 11434. Clearing
    # the key is therefore something the loopback arm must DO, not merely
    # something it declines to write.
    it "clears an api key another deployment left on a configuration it is handed" do
      leaked = described_class.cloud(api_key: +"sk-must-not-survive")
      config = leaked.apply(Lain::Provider::HTTP::Configuration.new)
      expect(deployment.apply(config).ollama_api_key).to be_nil
    end

    it "does not leave the cloud base behind either, so the key and the base cannot disagree" do
      leaked = described_class.cloud(api_key: +"sk-must-not-survive")
      config = leaked.apply(Lain::Provider::HTTP::Configuration.new)
      expect(deployment.apply(config).ollama_api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
    end

    it "is equal to another loopback arm, because there is one loopback server to talk about" do
      expect(described_class.local).to eq(described_class.local)
    end
  end

  describe "the hosted arm" do
    subject(:deployment) { described_class.cloud(api_key: key) }

    it_behaves_like "an ollama deployment", counterpart: -> { described_class.local }

    describe "refusing to exist without a key" do
      it "names the environment variable an operator actually sets" do
        expect { described_class.cloud(api_key: nil) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      it "says where a key comes from, so the refusal is actionable" do
        expect { described_class.cloud(api_key: nil) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
      end

      # `Configuration`'s generated setter blanks a whitespace-only String to
      # nil, so a key refused only there would already have been written as an
      # `Authorization: Bearer ` with nothing after it. The refusal has to be
      # here, at construction, where there is still something to refuse.
      it "refuses a key that is only whitespace, not just a nil one" do
        expect { described_class.cloud(api_key: "   ") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      # "is not set" is a claim about the environment, and it is FALSE for every
      # case below. The nbsp one is the sharp edge: the operator runs
      # `echo $OLLAMA_API_KEY`, sees a character sitting there, and is told the
      # variable is unset.
      it "does not claim the variable is unset when it holds only whitespace" do
        expect { described_class.cloud(api_key: "\u00A0") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /only whitespace/)
      end

      it "does not claim the variable is unset when it holds a non-String" do
        expect { described_class.cloud(api_key: 12_345) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /Integer/)
      end

      it "says the variable is not set only when it really is nil" do
        expect { described_class.cloud(api_key: nil) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /is not set/)
      end

      it "does not say \"is not set\" about a blank key" do
        expect { described_class.cloud(api_key: "   ") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /^(?!.*is not set).*$/m)
      end

      it "names where a key comes from whatever the reason for the refusal" do
        expect { described_class.cloud(api_key: :sk_real) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
      end

      it "is a Lain::Error, so the exe's rescue maps it instead of dumping a trace" do
        expect(Lain::Provider::Ollama::Deployment::MissingAPIKey.new).to be_a(Lain::Error)
      end

      # The bare constructor is a door too, and it is the one `Data#with` opens.
      # A key that reached the wire through it would be refused nowhere.
      it "refuses an unusable key through the bare constructor as well as the factory" do
        expect { described_class.new(api_key: "sk-paste\r\nCANARY9876") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey)
      end

      it "refuses an unusable key through Data#with, which rebuilds through the constructor" do
        expect { deployment.with(api_key: "sk-paste\r\nCANARY9876") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey)
      end
    end

    # BLOCKER: an interior line break is not SURROUNDING whitespace, so the trim
    # leaves it in place and `Bearer sk-real\r\nCANARY` reaches Net::HTTP, which
    # raises a bare `ArgumentError` -- not a {Lain::Error}, so it escapes
    # `wrapping_errors` and every rescue in the codebase, carrying THE LIVE KEY
    # in its message past every redaction guard on the object -- none of which
    # can reach a String that has already left it.
    #
    # The realistic input is a key copied from a soft-wrapped web page or read
    # from a CRLF file -- the same settings page the refusal points at.
    describe "refusing a key that cannot go in a header" do
      # `\r\n`, `\r` and `\n` each on their own: the adapter refuses all three,
      # and a fix that pattern-matched only the pair would leave two open. The
      # tab and NUL are here because the same header rule refuses every control
      # character, not only the line breaks that motivated the finding.
      {
        "an interior CRLF" => "sk-paste\r\nCANARY9876",
        "an interior CR" => "sk-paste\rCANARY9876",
        "an interior LF" => "sk-paste\nCANARY9876",
        "an interior tab" => "sk-paste\tCANARY9876",
        "an interior NUL" => "sk-paste\u0000CANARY9876"
      }.each do |description, hostile|
        it "refuses #{description}, naming the variable" do
          expect { described_class.cloud(api_key: hostile) }
            .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
        end

        # THE POINT OF THE WHOLE FINDING. A refusal that quotes the value it
        # refused has only moved the leak out of the adapter's ArgumentError and
        # into our own exception -- which is worse, because ours is the one
        # callers are told to rescue, log and report.
        it "puts no fragment of #{description}'s key in the message" do
          expect { described_class.cloud(api_key: hostile) }
            .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey) do |error|
              expect(error.message).not_to include("CANARY9876")
              expect(error.message).not_to include("sk-paste")
            end
        end
      end

      # Already closed by the trim, because `[[:space:]]` covers `\r`. Pinned so
      # a future rewrite of the trim cannot quietly reopen it while the interior
      # cases go on passing.
      it "accepts a trailing CR, which the surrounding-space trim strips today" do
        expect { described_class.cloud(api_key: "sk-real\r") }.not_to raise_error
      end

      it "keeps a key a header can actually carry" do
        expect { described_class.cloud(api_key: "sk-ollama-perfectly-ordinary") }.not_to raise_error
      end

      it "does not claim the variable is unset when it holds an unusable key" do
        expect { described_class.cloud(api_key: "sk-paste\r\nCANARY9876") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /^(?!.*is not set).*$/m)
      end

      it "names the line break as the problem, so the operator knows what to look for" do
        expect { described_class.cloud(api_key: "sk-paste\r\nCANARY9876") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /line break|control character/)
      end

      it "still says where a key comes from, so this refusal is as actionable as the others" do
        expect { described_class.cloud(api_key: "sk-paste\r\nCANARY9876") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
      end

      # The end-to-end statement: with the refusal at construction there is no
      # instance to ask for headers, so the bare ArgumentError that escapes
      # every rescue is unreachable through this door rather than merely
      # unlikely.
      it "never lets a CR/LF key reach the header builder at all" do
        expect { described_class.cloud(api_key: "sk-paste\r\nCANARY9876").headers }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey)
      end
    end

    it "dials ollama.com, the cloud base for the same native endpoints" do
      expect(deployment.api_base).to eq("https://ollama.com")
    end

    it "carries the key as a Bearer authorization" do
      expect(deployment.headers).to eq("Authorization" => "Bearer #{key}")
    end

    it "is not local, so nothing may treat it as a machine-local read" do
      expect(deployment.local?).to be(false)
    end

    # `/api/ps` lists LOADED RUNNERS. That is a concept a serverless host does
    # not have, and probing it would reach VCR's gate unstubbed rather than
    # answer a window.
    it "claims no loaded-runner endpoint" do
      expect(deployment.runner_status?).to be(false)
    end

    # `CLI::ChatLaunch#call` forces `Backend#num_ctx`, and `NumCtx#tokens`
    # reaches `trained_context_tokens` -> a POST to `/api/show`. Whether that
    # endpoint answers on ollama.com at all is unverified, so `--num-ctx N` must
    # not fire a live request to find out at launch.
    it "claims no model-metadata endpoint either, and says so separately" do
      expect(deployment.model_metadata?).to be(false)
    end

    # ONE list, not two literals that happen to agree -- which is what the
    # two-class version had, and what an `eq` here would now be comparing with
    # itself. Stated by IDENTITY, so it still says something: an arm that
    # filtered or duped the shared list would be answering its own copy again,
    # and the cut on the provider axis is only clean while it does not.
    it "reads its capability list from the one list both arms share, not a copy of it" do
      expect(deployment.capabilities).to equal(described_class.local.capabilities)
    end

    # The pricing page meters "cached input tokens" separately, which is
    # suggestive and is not evidence, and the native response carries only a
    # flat `prompt_eval_count`. Declaring a capability this path cannot
    # demonstrate is the exact lie the capability set exists to catch.
    it "does not claim prompt_caching, which nothing has yet demonstrated" do
      expect(deployment.capabilities).not_to include(:prompt_caching)
    end

    it "declares no caching until something measures one" do
      expect(deployment.cache_profile).to eq(Lain::CacheProfile::NO_CACHING)
    end

    describe "the retry envelope" do
      # The local 300s exists for a server loading a model into VRAM and then
      # thinking for six minutes. A hosted endpoint silent that long is
      # rate-limited or down, and against a plan with two rolling quotas a 429
      # is the ordinary case -- so this arm trades patience for attempts.
      it "is the deployment's own, not the loopback arm's six-minute budget" do
        local = described_class.local
        expect([deployment.request_timeout, deployment.max_retries])
          .not_to eq([local.request_timeout, local.max_retries])
      end

      it "waits less than the loopback arm and tries more often" do
        local = described_class.local
        expect(deployment.request_timeout).to be < local.request_timeout
        expect(deployment.max_retries).to be > local.max_retries
      end
    end

    describe "admission width" do
      it "defaults to one, which is safe on every plan including Free" do
        expect(deployment.admission_width).to eq(1)
      end

      it "is raised by LAIN_OLLAMA_CLOUD_CONCURRENCY, the way every other width in lain is set" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "3") do
          expect(described_class.cloud(api_key: key).admission_width).to eq(3)
        end
      end

      # Loud on a typo, per the house rule: a misspelt width that silently meant
      # 1 would look exactly like admission working.
      it "refuses a width that is not a number, naming the variable" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "three") do
          expect { described_class.cloud(api_key: key) }
            .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
        end
      end

      # `0` unbounds admission process-wide via LAIN_PROVIDER_CONCURRENCY; here
      # it would mean "no concurrent models at all", which is not a thing to ask
      # a quota-metered plan for.
      it "refuses a width below one" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "0") do
          expect { described_class.cloud(api_key: key) }
            .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
        end
      end

      # Bare `Integer("0x10")` reads a hex literal and answers 16. Without this
      # example the explicit base could be dropped and every other one stays
      # green.
      it "refuses a hex literal rather than reading it as sixteen" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "0x10") do
          expect { described_class.cloud(api_key: key) }
            .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
        end
      end

      it "refuses a decimal rather than truncating it" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "3.7") do
          expect { described_class.cloud(api_key: key) }
            .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
        end
      end

      # The same Unicode blank the key path refuses: `String#strip` would keep
      # it, leaving `Integer()` to raise a message naming neither the variable
      # nor a remedy.
      it "treats a non-breaking space variable as unset, the same as the key path does" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "\u00A0") do
          expect(described_class.cloud(api_key: key).admission_width).to eq(1)
        end
      end

      it "ignores an empty variable the same as an unset one" do
        with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "") do
          expect(described_class.cloud(api_key: key).admission_width).to eq(1)
        end
      end
    end

    describe "#apply" do
      subject(:config) { deployment.apply(Lain::Provider::HTTP::Configuration.new) }

      it "writes the cloud base" do
        expect(config.ollama_api_base).to eq("https://ollama.com")
      end

      it "writes the key, which is what Transport#headers will read" do
        expect(config.ollama_api_key).to eq(key)
      end

      it "writes the deployment's own retry envelope" do
        expect([config.request_timeout, config.max_retries])
          .to eq([deployment.request_timeout, deployment.max_retries])
      end

      it "does not leave the loopback arm's six-minute envelope in place" do
        local = described_class.local
        expect([config.request_timeout, config.max_retries])
          .not_to eq([local.request_timeout, local.max_retries])
      end
    end

    describe "the key it was handed" do
      # A key read from a file or a .env line arrives with a trailing newline.
      # Interpolated raw it becomes `Bearer sk-real\n`, and Net::HTTP raises
      # `ArgumentError: header field value cannot include CR/LF` from inside the
      # adapter -- naming neither OLLAMA_API_KEY nor a remedy.
      it "strips surrounding whitespace before it ever reaches a header" do
        built = described_class.cloud(api_key: "  sk-from-a-file\n")
        expect(built.headers).to eq("Authorization" => "Bearer sk-from-a-file")
      end

      it "stores the stripped key, so the header and the configuration agree" do
        built = described_class.cloud(api_key: "  sk-from-a-file\n")
        expect(built.api_key).to eq("sk-from-a-file")
      end

      it "carries no CR or LF into the header value, whatever it was handed" do
        built = described_class.cloud(api_key: "sk-real\r\n")
        expect(built.headers.fetch("Authorization")).not_to match(/[\r\n]/)
      end

      # `String#strip` does not remove U+00A0, so a key copied out of a web page
      # -- the very settings page the refusal points at -- can be non-breaking
      # space only, pass the blank check, and reach the wire as a bare `Bearer`.
      it "refuses a key that is only a non-breaking space, which String#strip keeps" do
        expect { described_class.cloud(api_key: "\u00A0") }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      it "strips a non-breaking space from around a real key" do
        expect(described_class.cloud(api_key: "\u00A0sk-real\u00A0").api_key).to eq("sk-real")
      end

      # The width parse is deliberately loud on a typo. A credential deserves at
      # least as much: coerced with `to_s`, a Hash reaches the wire as
      # `Bearer {a: 1}` and comes back 401, which names nothing.
      it "refuses a key that is not a String rather than coercing it" do
        expect { described_class.cloud(api_key: { a: 1 }) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      it "refuses a Symbol key" do
        expect { described_class.cloud(api_key: :sk_real) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      it "refuses a numeric key" do
        expect { described_class.cloud(api_key: 12_345) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      # The mutation that proved this was missing: drop the `.freeze` and every
      # other example stays green, because a literal key is already frozen.
      it "holds no reachable mutable state even when handed an unfrozen key" do
        expect(Ractor.shareable?(described_class.cloud(api_key: +"sk-mutable"))).to be(true)
      end

      it "does not freeze the caller's own String, which is not ours to freeze" do
        caller_key = +"sk-mutable"
        described_class.cloud(api_key: caller_key)
        expect(caller_key).not_to be_frozen
      end
    end

    it "carries the key as a Bearer authorization whose parts are all frozen Strings" do
      expect(deployment.headers.to_a.flatten).to all(be_a(String).and(be_frozen))
    end
  end

  # Pinned by DEFINITION, not by value. `/api/ps` reports a SERVED window and
  # `/api/show` the GGUF's trained maximum; both predicates agree with locality
  # on both arms today, so no value assertion can tell an honest implementation
  # from `alias model_metadata? runner_status?`. A third deployment answering
  # one and not the other is the case this protects.
  it "answers the two probe predicates from two separate definitions" do
    expect(described_class.instance_method(:model_metadata?).original_name).to eq(:model_metadata?)
  end

  # A crashed example prints its subject, and `Data` renders every member, so
  # the default would put a live credential into the suite's output and into any
  # log line that inspects a provider -- the wound
  # `Provider::HTTP::Configuration` already closed once, in both directions.
  #
  # FOUR renderers, not one, and they fail in different directions:
  # `#inspect`/`#to_s` are the printers; `pretty_print` is what `pp` reaches
  # for, walking members itself; a differ that walks INSTANCE VARIABLES reaches
  # the memoized header Hash without going through any of them (super_diff
  # 0.19.0 does exactly that, and rendered a live Bearer into a CI log); and
  # `#to_h`/`#deconstruct_keys` are what `Data` hands out for free, which is the
  # pair that would carry a key into the NDJSON Journal.
  describe "never echoing the key" do
    subject(:deployment) { described_class.cloud(api_key: key) }

    it "still says what it is when inspected" do
      expect(deployment.inspect).to include("Deployment")
    end

    it "does not echo the key from inspect" do
      expect(deployment.inspect).not_to include(key)
    end

    it "does not echo the key from to_s either, which Data aliases to inspect" do
      expect(deployment.to_s).not_to include(key)
    end

    it "does not echo the key from pretty_inspect" do
      expect(deployment.pretty_inspect).not_to include(key)
    end

    it "does not echo the key through PP, which is what `pp` reaches for" do
      expect(PP.pp(deployment, +"")).not_to include(key)
    end

    it "keeps the memoized header Hash out of reach of a differ that walks ivars" do
      expect(deployment.instance_variables).not_to include(:@headers)
    end

    it "leaves nothing among its instance variables that carries the key" do
      leaking = deployment.instance_variables.select do |ivar|
        deployment.instance_variable_get(ivar).inspect.include?(key)
      end
      expect(leaking).to be_empty
    end

    it "still says what it is when pretty-printed" do
      expect(deployment.pretty_inspect).to include("Deployment")
    end

    # `Data` supplies `#to_h` for free, and a Journal record is a Hash. This is
    # the guard the two-class version did not have.
    it "does not hand the key out through to_h, which Data supplies for free" do
      expect(deployment.to_h.values.map(&:inspect).join).not_to include(key)
    end

    it "still names both members in to_h, so the redaction is not a deletion" do
      expect(deployment.to_h.keys).to eq(%i[api_key admission_width])
    end

    it "redacts visibly rather than silently, so a reader knows a value was withheld" do
      expect(deployment.to_h.fetch(:api_key)).to eq("[REDACTED]")
    end

    it "honours to_h's block form, which Hash callers rely on" do
      expect(deployment.to_h { |name, value| [name.to_s, value] })
        .to eq("api_key" => "[REDACTED]", "admission_width" => 1)
    end

    # Pattern matching is the other door `Data` opens, and `in {api_key:}` binds
    # whatever `#deconstruct_keys` answers.
    it "does not hand the key out through a pattern match" do
      deployment => { api_key: }
      expect(api_key).not_to eq(key)
    end

    it "answers only the keys a pattern match asked for" do
      expect(deployment.deconstruct_keys(%i[admission_width])).to eq(admission_width: 1)
    end

    # `Data` opens TWO destructuring doors. Closing `#deconstruct_keys` alone
    # leaves `in [key, _]` binding the live value, which is the same leak
    # arriving through the pattern nobody wrote the guard for.
    it "does not hand the key out through an array pattern either" do
      deployment => [shown, _width]
      expect(shown).to eq("[REDACTED]")
    end

    # THE MUTANT THIS CLOSES: `def with(**kw) = self.class.new(**to_h.merge(kw))`
    # routes `#with` through the REDACTED to_h, replacing every credential with
    # the literal "[REDACTED]" -- which `#credential` accepts, since it is
    # neither blank nor control characters. The shipped failure is
    # authenticating as `Bearer [REDACTED]`, and it survives every other example
    # in this group because none of them calls `with` on a value that kept one.
    it "keeps the real key across #with, which redaction must not have reached" do
      expect(deployment.with(admission_width: 2).api_key).to eq(key)
    end

    it "keeps the real key on the wire across #with, not the redacted stand-in" do
      expect(deployment.with(admission_width: 2).headers.fetch("Authorization")).to eq("Bearer #{key}")
    end

    # The loopback arm has no key, and saying it holds a redacted one would be a
    # lie in the other direction.
    it "says the loopback arm's absent key is nil rather than redacted" do
      expect(described_class.local.to_h).to eq(api_key: nil, admission_width: nil)
    end

    # Value semantics are what `Data` is for, and a redacted `#to_h` must not
    # cost them: `==` and `#hash` are C-level and read the members directly.
    it "still compares by value, which the redaction must not have cost" do
      expect(described_class.cloud(api_key: key)).to eq(described_class.cloud(api_key: key))
    end

    it "still distinguishes two different keys, so the redaction is a view and not the value" do
      expect(described_class.cloud(api_key: key)).not_to eq(described_class.cloud(api_key: +"sk-different"))
    end

    it "still hashes by value, so a Set or a Hash key keeps working" do
      pair = [described_class.cloud(api_key: key), described_class.cloud(api_key: key)]
      expect(pair.uniq.size).to eq(1)
    end
  end
end
