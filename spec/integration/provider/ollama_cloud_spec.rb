# frozen_string_literal: true

# Hits Ollama Cloud with a REAL key against somebody's metered subscription.
# Skipped unless LAIN_OLLAMA_CLOUD=1 *and* OLLAMA_API_KEY is set -- see
# spec/support/ollama_cloud_tag.rb, which copies :api_integration's posture
# rather than :ollama's, because these cost money and :ollama examples do not.
#
#   LAIN_OLLAMA_CLOUD=1 OLLAMA_API_KEY=... bundle exec rspec spec/integration/provider/ollama_cloud_spec.rb
#
# WHAT ONE RUN SPENDS, deliberately counted, because a cost comment that is
# itself sloppy is worse than none: **three billable completions** -- one for
# the smoke round trip, two for the agent turn (the tool call and the follow-up
# that consumes its result) -- plus **two requests that perform no inference at
# all**, one `/api/show` and one 401. The second `/api/show` example makes no
# request whatsoever: it returns on the deployment's own predicates before it
# reaches a transport, which is the very thing it exists to pin. The saturation
# example below spends thirty-two more and is behind a SECOND gate for that
# reason.
#
# THE CREDENTIAL CONSTRAINT, and it is why some assertions look indirect.
# `Transport#headers` RETURNS a plain `{"Authorization" => "Bearer <key>"}`
# Hash. Once a caller holds that value no `#inspect`/`#pretty_print`/
# `#instance_variables` override can redact it, so a failing expectation on
# those headers -- or on any structure containing them -- renders the live
# Bearer into rspec's failure output and from there into a terminal someone
# scrolls back through. `Deployment`'s own comment records the same
# limitation. This is the first spec in the repo that holds a real key, so it
# asserts on PRESENCE, SHAPE, or the deployment's own declaration, and never on
# the header Hash itself.
#
# The reference document is the deliverable this file supports, not the other
# way round: references/ollama/cloud.md carries the full seventeen-model sweep
# and the 429 header vocabulary, dated and with the method stated. This file
# pins the handful of those findings that are cheap enough to re-verify.
RSpec.describe Lain::Provider::Ollama, :ollama_cloud do
  subject(:provider) { described_class.cloud(api_key: ENV.fetch("OLLAMA_API_KEY")) }

  let(:model) { Lain::CLI::Backend::OllamaTier::CLOUD_DEFAULT_MODEL }

  # `think` is set LOW on every request here for a reason that is about money,
  # not about reasoning quality: gpt-oss emits an analysis channel whether or
  # not one is asked for, `think: false` does not suppress it (measured
  # 2026-08-24 -- see cloud.md), and `num_predict` is not among
  # Ollama::Encoding::SAMPLER_KEYS, so there is no way to cap output length
  # through a Request at all. Low reasoning is the only lever this arm has over
  # what a live example costs.
  def chat(prompt, **overrides)
    request = Lain::Request.new(
      model:, max_tokens: 256, stream: false,
      extra: { "temperature" => 0, "seed" => 42, "think" => "low" },
      messages: [{ "role" => "user", "content" => prompt }],
      **overrides
    )
    provider.complete(request)
  end

  # ---- layer 1: smoke -- the Response contract holds against the cloud host --

  describe "a plain /api/chat round trip against ollama.com" do
    it "decodes into a neutral Response with the contract intact" do
      response = chat("Reply with exactly the word: pong")

      expect(response).to be_a(Lain::Response)
      expect(response).to stop_with(:end_turn)
      expect(response.text).to be_a(String)
      expect(response.text).not_to be_empty

      # Same gate as the local arm: a Symbol key here would mean the decoder
      # leaked its own construction shape onto the Timeline. Worth re-asserting
      # on the cloud host because it is a different server build entirely --
      # `x-build-commit` differs from anything a local `ollama serve` reports.
      response.content.each do |block|
        expect(block).to be_a(Hash)
        expect(block.keys).to all(be_a(String))
        expect(block["type"]).to be_a(String)
      end

      # Populated from prompt_eval_count / eval_count. The cloud host sends a
      # NARROWER metrics set than a local server -- `total_duration` only, with
      # no load/prompt_eval/eval duration siblings -- so this is the one place
      # that proves the decoder does not depend on the absent ones.
      expect(response.usage.input_tokens).to be > 0
      expect(response.usage.output_tokens).to be > 0
    end
  end

  # ---- layer 2: what /api/show answers, and why lain does not ask ------------
  #
  # This layer replaces the local spec's temperature-0 determinism probe, which
  # has no honest counterpart here: three warm same-seed runs against
  # gpt-oss:20b-cloud produced THREE DISTINCT completions (measured 2026-08-24,
  # recorded in cloud.md). Ollama Cloud is a batched multi-tenant backend and
  # greedy decoding does not survive it. The response is to pin the invariant
  # that is actually TRUE and say so, not to mark a determinism example pending
  # -- a false determinism claim poisons every bench conclusion built on this
  # arm. What is true is the contract in
  # layer 1; what replaces layer 2 is the finding below, which costs nothing.
  describe "/api/show on the cloud host" do
    let(:transport) do
      config = Lain::Provider::HTTP::Configuration.new
      described_class::Deployment.cloud(api_key: ENV.fetch("OLLAMA_API_KEY")).apply(config)
      described_class::Transport.new(config)
    end

    # The plan refused to ASSUME this endpoint answered off-loopback. It does.
    it "answers, and reports the GGUF trained maximum rather than a served window" do
      body = transport.model_details(model).body
      trained = body.fetch("model_info").fetch("gptoss.context_length")

      # The key is namespaced by `general.architecture`, which is what makes it
      # GGUF KV metadata read out of the model file rather than a runtime
      # figure a serverless host could even have -- there is no per-caller
      # runner here whose num_ctx this could be describing.
      expect(body.fetch("model_info").fetch("general.architecture")).to eq("gptoss")
      expect(trained).to be_an(Integer)

      # 128Ki, against the 128,000 the shipped table records from Ollama's
      # published "128K" label. The table's figure is the conservative one and
      # stays the denominator; this one is a ceiling for refusing a flag. If
      # this literal ever moves, that is a finding for cloud.md, not a number
      # to relax -- cloud.md's sweep covers sixteen further models, two of
      # which report LESS than the table claims.
      expect(trained).to eq(131_072)
      expect(trained).to be > Lain::ContextWindow::CLOUD_WINDOWS.fetch(model)
    end

    # The gap this card was asked to establish the evidence for, pinned so the
    # one-line follow-up that closes it has something to turn red. `/api/show`
    # answers (above), but the deployment declares it does not, so the cloud arm
    # performs NO `--num-ctx` refusal: a `--num-ctx 500000` against a 128k model
    # is accepted in silence. Flipping `model_metadata?` is out of this spec's scope.
    it "is not asked by the provider, because the deployment declares it absent" do
      deployment = described_class::Deployment.cloud(api_key: ENV.fetch("OLLAMA_API_KEY"))

      expect(deployment.model_metadata?).to be(false)
      # nil WITHOUT a round trip -- #trained_context_tokens returns on the
      # predicate before it reaches the transport.
      expect(provider.trained_context_tokens(model)).to be_nil
      # And the denominator stays nil too, for the separate and correct reason
      # that a serverless host has no loaded-runner concept for /api/ps.
      expect(deployment.runner_status?).to be(false)
      expect(provider.context_window_tokens(model)).to be_nil
    end
  end

  # ---- layer 3: end-to-end -- a real tool-call turn through the Agent --------

  describe "a live cloud tool-call turn through the Agent" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) do
      Lain::Context.new(model:, max_tokens: 256, stream: false,
                        extra: { "temperature" => 0, "seed" => 42, "think" => "low" })
    end
    # BUDGETED, and on this arm that is not belt-and-braces. Without one the
    # Agent takes Budget::DEFAULT_MAX_ITERATIONS = 25, and the `max_tokens: 256`
    # above is DECORATIVE -- `max_tokens` appears nowhere in
    # `ollama/encoding.rb`, so nothing caps a turn's output (this file's
    # preamble records that finding; it applies here too). A reasoning-native
    # model told "You must call the echo tool" can therefore re-call it up to
    # twenty-five times against somebody's metered plan, on a subscription
    # whose own header promises four concurrent. Three is one more than the two
    # a healthy turn needs, so it bounds the blast radius without making a
    # slow-but-correct run fail.
    let(:agent) { Lain::Agent.new(provider:, toolset:, context:, budget: Lain::Agent::Budget.new(max_iterations: 3)) }

    it "calls echo, lands the result in one user turn, and settles" do
      agent.ask('Use the echo tool to echo back the word "pong". You must call the echo tool.')

      turns = agent.timeline.to_a

      tool_uses = turns.flat_map(&:content).select { |block| block["type"] == "tool_use" }
      expect(tool_uses.map { |block| block["name"] }).to include("echo")

      # Ollama's native wire has no tool-call id -- the provider SYNTHESIZES
      # one on decode -- and its `arguments` is an object, not a JSON String.
      # Both only cross a real cloud wire here.
      tool_uses.each { |block| expect(block["input"]).to be_a(Hash) }

      result_turns = turns.select { |turn| turn.content.any? { |block| block["type"] == "tool_result" } }
      expect(result_turns.size).to eq(1)
      expect(result_turns.first.role).to eq("user")

      results = result_turns.first.content.select { |block| block["type"] == "tool_result" }
      expect(results.map { |block| block["tool_use_id"] }).to match_array(tool_uses.map { |block| block["id"] })

      expect(agent).to be_done
    end
  end

  # ---- layer 4: what a REAL refusal says --------------------------------------

  describe "a syntactically valid but wrong key" do
    # Forty digits. Deliberately NOT the real key, and deliberately not near it:
    # this is the one example whose failure output could otherwise carry a live
    # credential, and the fix is to hold a fake one rather than to redact.
    subject(:provider) { described_class.cloud(api_key: "9" * 40) }

    it "raises a provider error naming the authentication failure, not an unknown one" do
      request = Lain::Request.new(model:, max_tokens: 32, stream: false,
                                  messages: [{ "role" => "user", "content" => "hi" }])

      expect { provider.complete(request) }
        .to raise_error(described_class::APIStatusError) { |error|
          expect(error.status).to eq(401)
          # ollama.com's own body is the single word `{"error":"Unauthorized"}`,
          # with no `www-authenticate` header to elaborate. Whichever sentence
          # survives the mapping, it must name the credential rather than
          # degrade into "An unknown error occurred" -- the failure already closed
          # on the local arm, re-asserted here because this arm's 401 is the
          # ordinary first-run mistake.
          expect(error.message).to match(/unauthorized|api key|credential/i)
        }
    end
  end

  # ---- layer 5: the rate-limit vocabulary -------------------------------------
  #
  # Establishing this was this arm's one genuinely expensive question, and the answer
  # is recorded verbatim in cloud.md. The headline: a 200 carries NO rate-limit
  # headers, but a 429 carries FIVE that never appear on success, so absence on
  # the success path proved nothing -- which is exactly why this was not
  # inferred from the earlier measurement.
  describe "how a rate-limit refusal is handled" do
    # Free, and the half worth re-running on every opt-in: if RateLimitError
    # ever leaves this list, a 429 stops being retried and starts surfacing on
    # the first attempt against a plan whose refusals are ORDINARY.
    it "retries a 429 rather than surfacing it, through the vendored stack" do
      stack = Lain::Provider::HTTP::Connection::MiddlewareStack.new(
        nil, Lain::Provider::HTTP::Configuration.new, sink: Lain::Sink::Null.new, log_level: :info
      )

      expect(stack.send(:retry_exceptions)).to include(Lain::Provider::HTTP::RateLimitError)
    end

    # Both knobs stay nil, and cloud.md now says why with evidence rather than
    # with caution: ollama.com sends `Retry-After` (integer seconds) and no
    # `RateLimit-Reset` at all, and faraday-retry's DEFAULT
    # `rate_limit_retry_header` is already `Retry-After`. Naming a header here
    # would replace a working default with a guess, and there is no reset
    # header to name.
    it "leaves the reset-header knobs unset, which is what makes Retry-After work" do
      config = Lain::Provider::HTTP::Configuration.new
      described_class::Deployment.cloud(api_key: ENV.fetch("OLLAMA_API_KEY")).apply(config)

      expect(config.rate_limit_reset_header).to be_nil
      expect(config.header_parser_block).to be_nil
    end

    # SECOND GATE, and not a disguised pending. :ollama_cloud gates on cost;
    # this gates on a different cost -- it deliberately saturates the
    # subscription's concurrency so that other work against the same key is
    # refused while it runs, which is not something an ordinary opt-in run
    # should do to somebody's plan. The header names it asserts are already
    # recorded in cloud.md; this exists so a reader can re-derive them.
    #
    #   LAIN_OLLAMA_CLOUD=1 LAIN_OLLAMA_CLOUD_SATURATE=1 OLLAMA_API_KEY=... bundle exec rspec ...
    #
    # It speaks Net::HTTP directly rather than going through the provider, and
    # that is the point: the provider RETRIES a 429 by design, so driving this
    # through it would either hide the refusal or spend five Retry-After sleeps
    # per thread rediscovering it. A characterization harness is allowed to
    # hold the wire that the library is built to hide.
    it "receives concurrency-shaped headers on the refusal itself", if: ENV["LAIN_OLLAMA_CLOUD_SATURATE"] == "1" do
      refusals = saturate(32)

      expect(refusals).not_to be_empty, "32 concurrent requests drew no 429 -- either the plan's " \
                                        "concurrency allowance grew or the endpoint stopped refusing; " \
                                        "re-measure and update references/ollama/cloud.md"

      headers = refusals.first
      expect(headers).to include("retry-after", "x-ratelimit-active",
                                 "x-ratelimit-max-concurrent", "x-ratelimit-queued",
                                 "x-ratelimit-queue-limit")
      # Seconds, not an HTTP-date -- which is the form faraday-retry's default
      # parser falls through to `.to_f` on, and why no header_parser_block is
      # needed above.
      expect(headers.fetch("retry-after")).to match(/\A\d+\z/)
      # There is deliberately no assertion that a RESET header is absent: it is
      # a negative about somebody else's server that a future deploy may
      # falsify, and cloud.md dates the observation instead.
    end

    # Returns the header Hash of every refused response. Nothing here touches a
    # credential beyond putting it in the outbound header, and no expectation
    # is ever written against that header (see this file's preamble).
    def saturate(fanout)
      responses = Array.new(fanout)
      threads = Array.new(fanout) do |i|
        Thread.new { responses[i] = post }
      end
      threads.each(&:join)

      responses.compact.select { |res| res.code == "429" }.map { |res| res.each_header.to_h }
    end

    # One eval token each, so the burst is bounded by the plan's admission gate
    # rather than by what it spends.
    def burst_body
      JSON.generate({ "model" => model, "stream" => false,
                      "messages" => [{ "role" => "user", "content" => "hi" }],
                      "options" => { "num_predict" => 1, "temperature" => 0 } })
    end

    def chat_uri = URI("#{described_class::Deployment::CLOUD_API_BASE}/api/chat")

    def post
      uri = chat_uri
      http = Net::HTTP.new(uri.host, 443)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 120
      http.start { |conn| conn.request(burst_request(uri)) }
    end

    def burst_request(uri)
      request = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      request["Authorization"] = "Bearer #{ENV.fetch("OLLAMA_API_KEY")}"
      request.body = burst_body
      request
    end
  end
end
