# frozen_string_literal: true

# THE DEFECT. Asked what the session had spent, the agent invented a metrics
# table -- a wrong model name and fabricated memory/CPU/RTT figures -- while
# eight `turn_usage` records carrying the true answer sat in the journal it had
# just written. It was reachability, not honesty: nothing in the toolset
# could answer the question, so the model answered it anyway. These examples
# pin the true answer being reachable, and pin the report to the numbers the
# run actually accrued rather than to any number this tool could compute.
RSpec.describe Lain::Tools::SessionUsage do
  # A real Agent over a scripted provider, because the claim is about what the
  # RUN accrued: `Agent#usage` delegates to {Lain::Agent::Accounting}, which
  # folds each Response's usage into the monoid. Stubbing `#usage` would assert
  # the tool formats whatever it is handed and nothing about the seam that made
  # the defect possible.
  def agent_over(*responses)
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:),
                    toolset: Lain::Toolset.new([]),
                    context: Lain::Context.new(model: "test-model", max_tokens: 64))
  end

  def usage_response(text, **fields)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                       stop_reason: :end_turn, model: "test-model",
                       usage: Lain::Usage.new(**fields))
  end

  # The report as data: the label→value table it renders, so an example can say
  # WHICH quantities are named without also pinning the punctuation between
  # them.
  def rows(result)
    result.content.lines.drop(1).to_h do |line|
      label, value = line.split(":", 2)
      [label.strip, value.strip]
    end
  end

  def report_for(agent)
    described_class.new(usage: -> { agent.usage }).call({}, nil)
  end

  # ---- Scenario: the tool reports cumulative usage ---------------------------

  describe "an agent that has observed two responses" do
    let(:agent) do
      agent_over(usage_response("one", input_tokens: 10, output_tokens: 5,
                                       cache_creation_input_tokens: 3, cache_read_input_tokens: 40),
                 usage_response("two", input_tokens: 3, output_tokens: 2,
                                       cache_creation_input_tokens: 1, cache_read_input_tokens: 60))
    end

    before do
      agent.ask("first")
      agent.ask("second")
    end

    it "names input, output and both cache totals, each the monoid sum of the two responses" do
      expect(rows(report_for(agent))).to include("input" => "13", "output" => "7",
                                                 "cache creation" => "4", "cache read" => "100")
    end

    # The two derived quantities {Lain::Usage} owns, reported rather than left
    # for the model to add up -- an arithmetic step it takes is an arithmetic
    # step it can get wrong, which is the same failure class in miniature.
    it "reports the totals Usage derives, so the model never adds them itself" do
      expect(rows(report_for(agent))).to include("total input" => "117", "total" => "124")
    end

    it "reports the prompt cache hit ratio, the bench's first-class cache metric" do
      expect(rows(report_for(agent))).to include("cache hit ratio" => "85.5%")
    end

    # The whole label set, exactly. `include` above says the right quantities are
    # PRESENT; this says no other quantity is, which is the half that matters
    # here -- a dollar figure or a turn count added later would be a number this
    # run cannot know, and it would fail by name here rather than ship.
    it "names these quantities and no others -- no dollars, no turn count" do
      expect(rows(report_for(agent)).keys)
        .to eq(["input", "output", "cache creation", "cache read", "total input", "total", "cache hit ratio"])
    end

    it "succeeds rather than reporting an error result" do
      expect(report_for(agent)).to be_ok
    end
  end

  # ---- Scenario: a fresh run reports zero rather than refusing ---------------

  # Zero here is MEASURED, not defaulted: the Accounting of an agent that has
  # asked nothing really is `Usage.zero`. The distinction is the whole point --
  # a zero the tool invented because it could not reach the accounting would be
  # that same invention with better formatting, which is why nothing in the
  # implementation coalesces a missing collaborator to a zero.
  describe "an agent that has observed no responses" do
    it "reports zero tokens" do
      report = report_for(agent_over(usage_response("unused")))

      expect(report).to be_ok
      expect(rows(report)).to eq("input" => "0", "output" => "0", "cache creation" => "0", "cache read" => "0",
                                 "total input" => "0", "total" => "0", "cache hit ratio" => "0.0%")
    end
  end

  # ---- Scenario: a resumed run reports the RUN, and says so -----------------

  # {Lain::Agent::Accounting} starts at `Usage.zero` (accounting.rb:22) and
  # nothing in CLI::Wiring passes an `accounting:`, so `--resume` gives a fresh
  # ledger over a resumed Timeline. This tool therefore reports the RUN, not the
  # session lifetime.
  #
  # Pinned rather than left implicit because the failure mode is the same one: a
  # confidently formatted under-report is as wrong as a confidently formatted
  # invention, and the model would present it as lifetime spend on the strength
  # of the description alone. True session-lifetime accounting across a resume
  # is a separate change -- a ledger seeded from the resumed record -- and when
  # it lands, this example is what will fail and say so.
  describe "an agent resumed onto a timeline it did not build" do
    it "reports only what this run has spent, not the resumed timeline's history" do
      resumed = Lain::Timeline.empty(store: Lain::Store.new)
                              .commit(role: :user, content: [{ "type" => "text", "text" => "before the resume" }])
                              .commit(role: :assistant, content: [{ "type" => "text", "text" => "spent tokens" }])
      agent = Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: [usage_response("after")]),
                              toolset: Lain::Toolset.new([]),
                              context: Lain::Context.new(model: "test-model", max_tokens: 64),
                              timeline: resumed)

      expect(agent.timeline.length).to eq(2)
      expect(rows(report_for(agent))).to include("total" => "0")
    end
  end

  # ---- Scenario: an unwired tool refuses by name, and never answers zero -----

  # Promoted from the nil-agent probe. The escalation trigger is a claim
  # about this file -- never coalesce a missing thunk to Usage::ZERO -- and
  # until these examples existed it held only because `nil.usage` happens to
  # raise. A later `@usage&.call || Lain::Usage.zero` would have shipped green
  # with nothing in the suite to stop it, which is precisely the shape the
  # tool exists to remove, reintroduced inside the fix.
  describe "an instance with no accounting to read" do
    # SHAPED like the thunk Wiring actually ships -- `-> { @agent&.usage }` over
    # a slot #wire_agent has not assigned yet -- and not the bare `-> {}` this
    # used to use. The difference is not cosmetic: without the `&.` the real
    # seam raises NoMethodError INSIDE the lambda and never reaches the named
    # refusal, so a `-> {}` stand-in went on passing while the shipped path
    # handed the model `undefined method 'usage' for nil`. A double shaped
    # differently from the seam it stands for is a spec that passes for the
    # wrong reason.
    let(:unassigned_slot) do
      slot = nil
      -> { slot&.usage }
    end

    # The registry's construction-only builder is this arm: no Agent exists, so
    # there is no usage, and nil is what says so.
    it "refuses by name rather than answering zero when it holds no thunk at all" do
      expect { described_class.new(usage: nil).call({}, nil) }
        .to raise_error(described_class::Unwired, /cannot be read/)
    end

    # The other arm: a thunk over a slot that is still empty -- Wiring's
    # `-> { @agent&.usage }` read before #wire_agent has assigned it. No live
    # call can reach this, and it must still never answer a number.
    it "refuses by name rather than answering zero when the thunk resolves to nil" do
      expect { described_class.new(usage: unassigned_slot).call({}, nil) }
        .to raise_error(described_class::Unwired, /cannot be read/)
    end

    # The half that makes the two above mean something: the refusal must be
    # distinguishable from the honest zero of a fresh run. An `is_error` result
    # and an `ok` result reading `total: 0` are different answers, and a Null
    # Object over Usage.zero would collapse them into one.
    it "is distinguishable from the honest zero a fresh run reports" do
      fresh = report_for(agent_over(usage_response("unused")))

      expect(fresh).to be_ok
      expect(rows(fresh)).to include("total" => "0")
      expect { described_class.new(usage: unassigned_slot).call({}, nil) }.to raise_error(described_class::Unwired)
    end

    # It tells the MODEL not to guess. The refusal is only an improvement on a
    # fabricated zero if the thing that reads it knows no figure is on offer.
    it "tells the reader that no figure is available, rather than only that something broke" do
      message = begin
        described_class.new(usage: nil).call({}, nil)
      rescue described_class::Unwired => e
        e.message
      end

      expect(message).to match(/no figure is available/i)
      expect(message).to match(/do not estimate/i)
    end

    # What the MODEL actually sees, which is the only view that decides whether
    # this refusal is an improvement. {Lain::Effect::Handler::Live} turns a
    # raise into an error Result carrying `e.message` alone -- the class name is
    # stripped -- so an exception named `Unwired` buys nothing unless its
    # MESSAGE carries the reason. Driven through the real handler for that
    # reason: asserting on the exception alone would pass for a refusal the
    # model reads as `undefined method 'usage' for nil`.
    it "reaches the model as an error result that says why, not as a bare NoMethodError" do
      toolset = Lain::Toolset.new([described_class.new(usage: nil)])
      handler = Lain::Effect::Handler::Live.new(toolset:)

      result = handler.call(Lain::Effect::ToolCall.new(name: "session_usage", input: {}, tool_use_id: "t1"))

      expect(result).not_to be_ok
      expect(result.content).to match(/not wired to a running agent/i)
      expect(result.content).to match(/do not estimate/i)
      expect(result.content).not_to include("undefined method")
    end
  end

  # ---- The model-facing surface ---------------------------------------------

  describe "the model-facing surface" do
    subject(:tool) { described_class.new(usage: -> { Lain::Usage.zero }) }

    it "takes no arguments: the default nullary schema, no Input subclass" do
      expect(tool.input_schema).to eq(type: :object, properties: {}, required: [])
      expect(tool.input_model).to be_nil
    end

    # The description is the lever: a model that reads "tokens" here has no
    # reason to reach for a dollar figure the harness refuses to compute
    # ({Lain::Ledger} raises on an unpriced model, and the ollama-cloud arm has
    # no PriceBook entry at all).
    it "says tokens, and says it is not dollars" do
      expect(tool.description).to match(/token/i)
      expect(tool.description).to match(/dollar/i)
    end

    # The resume caveat has to live in the DESCRIPTION, because the description
    # is the only part of this tool the model reads before deciding what the
    # number means. See the resumed-agent example below for the behaviour it
    # describes; this pins that the model is told about it.
    # `/run/i` was the first spelling and it did NOT bite: it also matches
    # "running agent", which the pre-fix description already said, so the
    # assertion would have passed against the very wording it exists to catch.
    # The scope claim has to be matched by the phrase that STATES it.
    it "scopes itself to the run and warns that a resume excludes earlier spend" do
      expect(tool.description).to include("THIS RUN")
      expect(tool.description).to include("current run")
      expect(tool.description).to match(/resume/i)
    end

    # Reads one Usage value off the run's accounting and formats it: no Session
    # write-set mutation, no process-global state. TRUE_TOOLS in
    # spec/lain/tools/parallel_safety_spec.rb is the toolset-wide statement of
    # the same claim.
    it "is parallel-safe, and needs no approval gate" do
      expect(tool.parallel_safe?).to be(true)
      expect(tool.requires_approval?).to be(false)
    end
  end
end
