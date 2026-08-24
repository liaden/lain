# frozen_string_literal: true

# The hosted arm. Everything the local arm gets for free -- no key, no auth
# header, an unbounded server, a loaded-runner endpoint to probe -- stops being
# true here, and this file is where each of those inversions is stated.
RSpec.describe Lain::Provider::Ollama::Deployment::Cloud do
  subject(:deployment) { described_class.new(api_key: key) }

  # WHY THIS FILE CARRIES ITS OWN SHAREABILITY CHECKS. `GenericBuild` hands the
  # SAME dummy to every member, and no dummy is both a valid String key and a
  # valid width ("x" fails the width parse, 1 fails the key type), so `Cloud`
  # sits in `spec/value_object_shareability_spec.rb`'s `unreached` set rather
  # than its `built` one -- named, not skipped, which is that sweep's stated
  # posture for a constructor no generic dummy satisfies. Three examples here
  # stand in for the slot: the shared group's "holds no reachable mutable
  # state" and "answers headers that are themselves deeply frozen", plus
  # "holds no reachable mutable state even when handed an unfrozen key" below.
  # All three were confirmed to fail under mutation. Do not "restore coverage"
  # by loosening the key refusal -- the refusal is the point, and
  # the sweep is the weaker of the two guards.

  # Unfrozen ON PURPOSE. A literal in this `frozen_string_literal: true` file
  # is already frozen, which makes the `.dup.freeze` in `#initialize` look
  # load-bearing when nothing would notice its removal. Real callers pass
  # `ENV["OLLAMA_API_KEY"]`, which is not frozen -- and stored as given it
  # makes `Ractor.shareable?` answer false.
  let(:key) { +"sk-ollama-not-a-real-key" }

  # Unset, not merely absent: a developer with the variable exported would
  # otherwise measure their own machine's width instead of the default.
  around { |example| with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => nil, &example) }

  it_behaves_like "an ollama deployment",
                  counterpart: -> { Lain::Provider::Ollama::Deployment::Local.new }

  describe "refusing to exist without a key" do
    it "names the environment variable an operator actually sets" do
      expect { described_class.new(api_key: nil) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    it "says where a key comes from, so the refusal is actionable" do
      expect { described_class.new(api_key: nil) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
    end

    # `Configuration`'s generated setter blanks a whitespace-only String to
    # nil, so a key refused only there would already have been written as an
    # `Authorization: Bearer ` with nothing after it. The refusal has to be
    # here, at construction, where there is still something to refuse.
    it "refuses a key that is only whitespace, not just a nil one" do
      expect { described_class.new(api_key: "   ") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    # "is not set" is a claim about the environment, and it is FALSE for every
    # case below. The nbsp one is the sharp edge: the operator runs
    # `echo $OLLAMA_API_KEY`, sees a character sitting there, and is told the
    # variable is unset -- the same misdirection SF1 removed from the header,
    # arriving through the message instead.
    it "does not claim the variable is unset when it holds only whitespace" do
      expect { described_class.new(api_key: "\u00A0") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /only whitespace/)
    end

    it "does not claim the variable is unset when it holds a non-String" do
      expect { described_class.new(api_key: 12_345) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /Integer/)
    end

    it "says the variable is not set only when it really is nil" do
      expect { described_class.new(api_key: nil) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /is not set/)
    end

    it "does not say \"is not set\" about a blank key" do
      expect { described_class.new(api_key: "   ") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /^(?!.*is not set).*$/m)
    end

    it "names where a key comes from whatever the reason for the refusal" do
      expect { described_class.new(api_key: :sk_real) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
    end

    it "is a Lain::Error, so the exe's rescue maps it instead of dumping a trace" do
      expect(Lain::Provider::Ollama::Deployment::MissingAPIKey.new).to be_a(Lain::Error)
    end
  end

  # BLOCKER: an interior line break is not SURROUNDING whitespace, so the trim
  # leaves it in place and `Bearer sk-real\r\nCANARY` reaches Net::HTTP, which
  # raises a bare `ArgumentError` -- not a {Lain::Error}, so it escapes
  # `wrapping_errors` and every rescue in the codebase, carrying THE LIVE KEY
  # in its message past all three redaction guards (`#inspect`,
  # `#pretty_print`, `Configuration#instance_variables`).
  #
  # The realistic input is a key copied from a soft-wrapped web page or read
  # from a CRLF file -- the same settings page the refusal points at. The block
  # above closes only the leading/trailing case, which is the case nobody hits;
  # this one closes the case they do.
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
        expect { described_class.new(api_key: hostile) }
          .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
      end

      # THE POINT OF THE WHOLE FINDING. A refusal that quotes the value it
      # refused has only moved the leak out of the adapter's ArgumentError and
      # into our own exception -- which is worse, because ours is the one
      # callers are told to rescue, log and report.
      it "puts no fragment of #{description}'s key in the message" do
        expect { described_class.new(api_key: hostile) }
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
      expect { described_class.new(api_key: "sk-real\r") }.not_to raise_error
    end

    it "keeps a key a header can actually carry" do
      expect { described_class.new(api_key: "sk-ollama-perfectly-ordinary") }.not_to raise_error
    end

    # The refusal must say what is WRONG, not merely that something is. "is not
    # set" would send an operator who can SEE the value to look in the wrong
    # place -- the misdirection the block above exists to prevent, arriving
    # through a different branch.
    it "does not claim the variable is unset when it holds an unusable key" do
      expect { described_class.new(api_key: "sk-paste\r\nCANARY9876") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /^(?!.*is not set).*$/m)
    end

    it "names the line break as the problem, so the operator knows what to look for" do
      expect { described_class.new(api_key: "sk-paste\r\nCANARY9876") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /line break|control character/)
    end

    it "still says where a key comes from, so this refusal is as actionable as the others" do
      expect { described_class.new(api_key: "sk-paste\r\nCANARY9876") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, %r{ollama\.com/settings/keys})
    end

    # The end-to-end statement: with the refusal at construction there is no
    # instance to ask for headers, so the bare ArgumentError that escapes every
    # rescue is unreachable through this door rather than merely unlikely.
    it "never lets a CR/LF key reach the header builder at all" do
      expect { described_class.new(api_key: "sk-paste\r\nCANARY9876").headers }
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

  # `CLI::Backend#initialize` calls `num_ctx` eagerly, and `NumCtx#tokens`
  # reaches `trained_context_tokens` -> a POST to `/api/show`. Whether that
  # endpoint answers on ollama.com at all is one of the three facts this plan
  # refuses to assume, so `--num-ctx N` must not fire a live request to find
  # out at launch.
  it "claims no model-metadata endpoint either, and says so separately" do
    expect(deployment.model_metadata?).to be(false)
  end

  it "answers the same capability list as the local arm, because the wire is the same" do
    expect(deployment.capabilities).to eq(Lain::Provider::Ollama::Deployment::Local.new.capabilities)
  end

  # Open decision 1: the pricing page meters "cached input tokens" separately,
  # which is suggestive and is not evidence, and the native response carries
  # only a flat `prompt_eval_count`. Declaring a capability this path cannot
  # demonstrate is the exact lie the capability set exists to catch.
  it "does not claim prompt_caching, which nothing has yet demonstrated" do
    expect(deployment.capabilities).not_to include(:prompt_caching)
  end

  it "declares no caching until something measures one" do
    expect(deployment.cache_profile).to eq(Lain::CacheProfile::NO_CACHING)
  end

  describe "the retry envelope" do
    # The local 300s exists for a server loading a model into VRAM and then
    # thinking for six minutes. A hosted endpoint silent that long is rate-
    # limited or down, and against a plan with two rolling quotas a 429 is the
    # ordinary case -- so this arm trades patience for attempts.
    it "is the deployment's own, not the local arm's six-minute budget" do
      local = Lain::Provider::Ollama::Deployment::Local.new
      expect([deployment.request_timeout, deployment.max_retries])
        .not_to eq([local.request_timeout, local.max_retries])
    end

    it "waits less than the local arm and tries more often" do
      local = Lain::Provider::Ollama::Deployment::Local.new
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
        expect(described_class.new(api_key: key).admission_width).to eq(3)
      end
    end

    # Loud on a typo, per the house rule: a misspelt width that silently meant
    # 1 would look exactly like admission working.
    it "refuses a width that is not a number, naming the variable" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "three") do
        expect { described_class.new(api_key: key) }
          .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
      end
    end

    # `0` unbounds admission process-wide via LAIN_PROVIDER_CONCURRENCY; here
    # it would mean "no concurrent models at all", which is not a thing to ask
    # a quota-metered plan for.
    it "refuses a width below one" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "0") do
        expect { described_class.new(api_key: key) }
          .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
      end
    end

    # Bare `Integer("0x10")` reads a hex literal and answers 16. Without this
    # example the explicit base could be dropped and every other one stays
    # green.
    it "refuses a hex literal rather than reading it as sixteen" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "0x10") do
        expect { described_class.new(api_key: key) }
          .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
      end
    end

    it "refuses a decimal rather than truncating it" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "3.7") do
        expect { described_class.new(api_key: key) }
          .to raise_error(Lain::Error, /LAIN_OLLAMA_CLOUD_CONCURRENCY/)
      end
    end

    # The same Unicode blank {Cloud} refuses in a key: `String#strip` would
    # keep it, leaving `Integer()` to raise a message naming neither the
    # variable nor a remedy.
    it "treats a non-breaking space variable as unset, the same as the key path does" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "\u00A0") do
        expect(described_class.new(api_key: key).admission_width).to eq(1)
      end
    end

    it "ignores an empty variable the same as an unset one" do
      with_env("LAIN_OLLAMA_CLOUD_CONCURRENCY" => "") do
        expect(described_class.new(api_key: key).admission_width).to eq(1)
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

    it "does not leave the local arm's six-minute envelope in place" do
      local = Lain::Provider::Ollama::Deployment::Local.new
      expect([config.request_timeout, config.max_retries])
        .not_to eq([local.request_timeout, local.max_retries])
    end
  end

  # A crashed example prints its subject, and `Data` renders every member, so
  # the default would put a live credential into the suite's output and into
  # any log line that inspects a provider -- the wound
  # `Provider::HTTP::Configuration` already closed once, in both directions.
  describe "never echoing the key" do
    it "still says what it is when inspected" do
      expect(deployment.inspect).to include("Cloud")
    end

    it "does not echo the key from inspect" do
      expect(deployment.inspect).not_to include(key)
    end

    it "does not echo the key from to_s either, which Data aliases to inspect" do
      expect(deployment.to_s).not_to include(key)
    end

    # `inspect` and `to_s` are not the only renderers. `pp`, `pretty_inspect`
    # and anything using PP go through `pretty_print`, which walks the members
    # itself and ignores an overridden `inspect` -- the same split
    # `Provider::HTTP::Configuration` had to close in BOTH directions.
    it "does not echo the key from pretty_inspect" do
      expect(deployment.pretty_inspect).not_to include(key)
    end

    it "does not echo the key through PP, which is what `pp` reaches for" do
      expect(PP.pp(deployment, +"")).not_to include(key)
    end

    it "still says what it is when pretty-printed" do
      expect(deployment.pretty_inspect).to include("Cloud")
    end
  end

  describe "the key it was handed" do
    # A key read from a file or a .env line arrives with a trailing newline.
    # Interpolated raw it becomes `Bearer sk-real\n`, and Net::HTTP raises
    # `ArgumentError: header field value cannot include CR/LF` from inside the
    # adapter -- naming neither OLLAMA_API_KEY nor a remedy.
    it "strips surrounding whitespace before it ever reaches a header" do
      built = described_class.new(api_key: "  sk-from-a-file\n")
      expect(built.headers).to eq("Authorization" => "Bearer sk-from-a-file")
    end

    it "stores the stripped key, so the header and the configuration agree" do
      built = described_class.new(api_key: "  sk-from-a-file\n")
      expect(built.api_key).to eq("sk-from-a-file")
    end

    it "carries no CR or LF into the header value, whatever it was handed" do
      built = described_class.new(api_key: "sk-real\r\n")
      expect(built.headers.fetch("Authorization")).not_to match(/[\r\n]/)
    end

    # `String#strip` does not remove U+00A0, so a key copied out of a web page
    # -- the very settings page the refusal points at -- can be non-breaking
    # space only, pass the blank check, and reach the wire as a bare `Bearer`.
    it "refuses a key that is only a non-breaking space, which String#strip keeps" do
      expect { described_class.new(api_key: "\u00A0") }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    it "strips a non-breaking space from around a real key" do
      expect(described_class.new(api_key: "\u00A0sk-real\u00A0").api_key).to eq("sk-real")
    end

    # `Cloud.width` two lines below is deliberately loud on a typo. A
    # credential deserves at least as much: coerced with `to_s`, a Hash
    # reaches the wire as `Bearer {a: 1}` and comes back 401, which names
    # nothing.
    it "refuses a key that is not a String rather than coercing it" do
      expect { described_class.new(api_key: { a: 1 }) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    it "refuses a Symbol key" do
      expect { described_class.new(api_key: :sk_real) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    it "refuses a numeric key" do
      expect { described_class.new(api_key: 12_345) }
        .to raise_error(Lain::Provider::Ollama::Deployment::MissingAPIKey, /OLLAMA_API_KEY/)
    end

    # The mutation that proved this was missing: drop `.dup.freeze` and every
    # other example stays green, because a literal key is already frozen.
    it "holds no reachable mutable state even when handed an unfrozen key" do
      expect(Ractor.shareable?(described_class.new(api_key: +"sk-mutable"))).to be(true)
    end

    it "does not freeze the caller's own String, which is not ours to freeze" do
      caller_key = +"sk-mutable"
      described_class.new(api_key: caller_key)
      expect(caller_key).not_to be_frozen
    end
  end

  it "carries the key as a Bearer authorization whose parts are all frozen Strings" do
    expect(deployment.headers.to_a.flatten).to all(be_a(String).and(be_frozen))
  end

  # Pinned by DEFINITION, not by value. Both predicates answer false here, so
  # no value assertion can tell an honest implementation from
  # `alias model_metadata? runner_status?` -- and a later tidy-up that
  # collapsed them would stay green while silently making the /api/show
  # decision follow the /api/ps one.
  it "answers the two probe predicates from two separate definitions" do
    expect(described_class.instance_method(:model_metadata?).original_name).to eq(:model_metadata?)
  end
end
