# frozen_string_literal: true

# Hits a REAL local Ollama server. Skipped unless LAIN_OLLAMA=1, and skipped
# (never failed) when the server is down or qwen3:4b is not pulled -- see
# spec/support/ollama_tag.rb for the gating + reachability pre-check. These cost
# no money (local inference) but are nondeterministic and slow, so they run only
# on request:
#
#   LAIN_OLLAMA=1 bundle exec rspec spec/integration/provider/ollama_spec.rb
#
# Their job is what a stub cannot cover: that the native /api/chat contract holds
# against the real server, that temperature-0 reproducibility is what the corpus
# says it is (not what we wish), and that a real qwen3:4b tool-call turn round-
# trips through the Agent loop.
RSpec.describe Lain::Provider::Ollama, :ollama do
  subject(:provider) { described_class.new(api_base: OLLAMA_API_BASE) }

  let(:model) { described_class::DEFAULT_MODEL }

  # Non-streaming keeps these deterministic-as-possible and side-steps NDJSON
  # reassembly timing; the streaming path has its own unit coverage. `max_tokens`
  # is required by Request but Ollama has no equivalent knob on /api/chat -- it is
  # carried for the neutral Request contract, not sent (see Ollama::Encoding).
  def chat(prompt, extra: { "temperature" => 0, "seed" => 42 }, **overrides)
    request = Lain::Request.new(
      model:, max_tokens: 256, stream: false, extra:,
      messages: [{ "role" => "user", "content" => prompt }],
      **overrides
    )
    provider.complete(request)
  end

  # ---- layer 1: smoke -- the Response contract holds against the real server --

  describe "a plain /api/chat round trip" do
    it "decodes into a neutral Response with the contract intact" do
      response = chat("Reply with exactly the word: pong")

      expect(response).to be_a(Lain::Response)
      # stop_reason is normalized off done_reason ("stop" -> :end_turn), NOT left
      # as a raw wire string (corpus: done_reason has no enum entry for tool turns).
      expect(response).to stop_with(:end_turn)
      expect(response.text).to be_a(String)
      expect(response.text).not_to be_empty

      # Every content block is a string-keyed Hash -- a Symbol key here would mean
      # the decoder leaked its own construction shape onto the Timeline.
      response.content.each do |block|
        expect(block).to be_a(Hash)
        expect(block.keys).to all(be_a(String))
        expect(block["type"]).to be_a(String)
      end

      # Usage is populated from prompt_eval_count / eval_count, not left zero.
      expect(response.usage.input_tokens).to be > 0
      expect(response.usage.output_tokens).to be > 0
    end
  end

  # ---- layer 2: determinism probe -- MEASURED, not assumed --------------------
  #
  # temperature: 0 makes the sampler greedy (always the top logit); the seed is
  # then a no-op and determinism comes from greedy decoding itself, not the seed
  # (references/ollama/api-chat.md, "Determinism" section). But greedy decoding is
  # NOT provably airtight: GPU float non-associativity and the batch size a request
  # lands in can perturb the argmax (corpus + issues #586/#5321). The one caveat
  # with teeth here is #5321: the FIRST run after a model load can differ from
  # runs 2+, which are stable among themselves. So we warm up once (discarded),
  # THEN measure N=3 within the same warm load generation -- the reliable regime.
  #
  # This spec pins what is TRUE for this environment. If the three still diverge
  # when the server is reachable, that is a real finding, not a flake to paper
  # over: a false determinism claim poisons every bench conclusion built on this
  # arm. In that case pin the weaker invariant the corpus documents (e.g. runs are
  # stable per warm load) and record it honestly in docs/ollama.md -- do NOT mark
  # this pending. (Escalation trigger, T21: seeded runs differing.)
  describe "temperature-0 reproducibility" do
    it "produces identical text across three warm same-seed runs" do
      prompt = "In one short sentence, describe what a compiler does."

      chat(prompt) # warm-up: discard the first-run-after-load divergence (#5321).
      texts = Array.new(3) { chat(prompt).text }

      expect(texts.uniq.size).to eq(1),
                                 "expected 3 identical warm temperature-0 runs, got " \
                                 "#{texts.uniq.size} distinct outputs:\n#{texts.uniq.map(&:inspect).join("\n")}"
    end
  end

  # ---- layer 3: end-to-end -- a real tool-call turn through the Agent ---------
  #
  # qwen3:4b is a small model; whether it emits a tool_call for a given prompt is
  # only observable live. The prompt is shaped per the corpus's tool-calling
  # guidance: name the tool, state the argument, and instruct the call explicitly.
  # If qwen3:4b will not call the tool reliably, do NOT loosen the assertion into
  # flakiness -- escalate with the transcript; model choice may need qwen3:8b
  # (Joel's call, T21 escalation trigger).
  describe "a live tool-call turn through the Agent" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) do
      Lain::Context.new(model:, max_tokens: 256, stream: false,
                        extra: { "temperature" => 0, "seed" => 42 })
    end
    let(:agent) { Lain::Agent.new(provider:, toolset:, context:) }

    it "calls echo, lands the result in one user turn, and settles" do
      agent.ask('Use the echo tool to echo back the word "pong". You must call the echo tool.')

      turns = agent.timeline.to_a

      # The tool was actually invoked by the model.
      tool_uses = turns.flat_map(&:content).select { |block| block["type"] == "tool_use" }
      expect(tool_uses.map { |block| block["name"] }).to include("echo")

      # Gate 5: tool_use input is a parsed Hash, never a JSON String -- and this
      # is the one place Ollama's native `arguments` object crosses a real,
      # unmocked wire (cf. the analogous live assertion in anthropic_spec.rb).
      tool_uses.each { |block| expect(block["input"]).to be_a(Hash) }

      # Gate 2: every tool_result lands in exactly ONE user turn.
      result_turns = turns.select { |turn| turn.content.any? { |block| block["type"] == "tool_result" } }
      expect(result_turns.size).to eq(1)
      expect(result_turns.first.role).to eq("user")

      # Gate 4: each result's tool_use_id matches a call's id. Ollama's wire has
      # no tool-call id -- the provider SYNTHESIZES one on decode -- so only a
      # live round trip proves the synthetic id survives into result matching.
      results = result_turns.first.content.select { |block| block["type"] == "tool_result" }
      expect(results.map { |block| block["tool_use_id"] }).to match_array(tool_uses.map { |block| block["id"] })

      # And the loop reached its terminal state rather than spinning (gate-6-shaped:
      # `done?` is the state machine's own predicate; `settled?` is private).
      expect(agent).to be_done
    end
  end
end
