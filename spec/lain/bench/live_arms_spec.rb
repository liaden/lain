# frozen_string_literal: true

# Which topologies each live comparison puts side by side.
#
# There are TWO rosters here and they answer different questions, which is why
# they are separate builders rather than one list that grew. `.build` is the
# ORCHESTRATION comparison `lain bench arms` runs -- single-thread against three
# richer topologies over one flat task suite. `.altitude` is the DECOMPOSITION
# comparison `lain bench altitude` runs -- the same work entered at four
# different heights on {Lain::Arm::Ladder}.
RSpec.describe Lain::Bench::LiveArms do
  # The seams the altitude arms need and the orchestration arms do not: a
  # planner, an issue actor and its fleet, and one already-built driver per epic
  # entry. Scripted here -- nothing in this file resolves a provider.
  let(:seams) do
    described_class::Seams.new(
      planner: ->(*, **) { "Subject: lib/order.rb\n" },
      actors: ->(*, **) { raise "no actor is launched in this spec" },
      supervisor: Object.new, progressive: Object.new, hands_off: Object.new,
      slug: "demo", records: -> { [] }
    )
  end

  def altitude = described_class.altitude(seams:)

  describe ".altitude — the four rungs, in ladder order" do
    # Scenario: the report compares four arms. Their ORDER is the ladder's, so
    # a reader scanning the report walks from the cheapest entry to the richest
    # rather than in whatever order a Hash happened to yield.
    it "builds one-shot, plan-only and both epic entries, lowest rung first" do
      expect(altitude.map(&:name)).to eq(%w[one-shot plan-only epic-progressive epic-hands-off])
    end

    it "enters the ladder one rung higher each time, the two epic entries alike" do
      expect(altitude.map { |arm| arm.rungs.first }).to eq(%w[implementation issue_plan research research])
    end

    # The two epic entries differ in WHO answers the gates and in nothing else,
    # so they must walk the same rungs -- the confound a bench comparing them
    # cannot introduce.
    it "has the two epic entries walk identical rungs" do
      progressive, hands_off = altitude.last(2)

      expect(progressive.rungs).to eq(hands_off.rungs)
    end

    # One instrument for every arm: a comparison is only a comparison if the
    # clock and the price book are shared, which is {Arm::Instrument}'s whole
    # reason for existing.
    it "measures every arm with one shared instrument" do
      instruments = altitude.map { |arm| arm.instance_variable_get(:@instrument) }

      expect(instruments.uniq.size).to eq(1)
    end

    it "prices every arm through the book it was given" do
      book = Lain::PriceBook.new(prices: {}, fallback: Lain::Price.per_mtok(input: 0, output: 0,
                                                                            cache_creation: 0, cache_read: 0))

      instrument = described_class.altitude(seams:, price_book: book)
                                  .first.instance_variable_get(:@instrument)

      expect(instrument.price_book).to be(book)
    end
  end

  # The orchestration roster is a DIFFERENT question, and `lain bench arms` and
  # its report spec pin it. Adding the altitude arms to it would silently change
  # what that command compares and what it costs to run.
  describe ".build — the orchestration roster" do
    it "answers exactly the four orchestration arms, the control first" do
      expect(described_class.build.map(&:name))
        .to eq(%w[single-thread orchestrator-worker dual-ledger adaptive-router])
    end

    it "carries none of the altitude arms" do
      expect(described_class.build.map(&:name)).not_to include("one-shot", "plan-only")
    end

    # `.altitude`'s rule, and for its reason: a comparison is only a comparison
    # if the clock and the price book are shared. The fourth arm takes the same
    # instrument rather than building its own.
    it "measures every arm with one shared instrument" do
      instruments = described_class.build.map { |arm| arm.instance_variable_get(:@instrument) }

      expect(instruments.uniq.size).to eq(1)
    end

    it "prices every arm through the book it was given" do
      book = Lain::PriceBook.new(prices: {}, fallback: Lain::Price.per_mtok(input: 0, output: 0,
                                                                            cache_creation: 0, cache_read: 0))
      books = described_class.build(price_book: book)
                             .map { |arm| arm.instance_variable_get(:@instrument).price_book }

      expect(books.uniq).to eq([book])
    end
  end

  # WHICH MODEL EACH CHILD RUNS UNDER. Two claims: the capable branch is
  # WHATEVER THE BACKEND RESOLVED, so `--model` moves this arm like the other
  # three; and the split is a property of the task rather than a number tuned to
  # this corpus.
  #
  # The pin matters as much as the policy: an earlier attempt built its long
  # task as `"a" * (THRESHOLD + 1)`, which passes for every threshold and so
  # pinned nothing. These read the COMMITTED suite instead.
  describe ".default_router — the routing policy" do
    def suite = Lain::Bench::ArmTasks.new(fixture_path: File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml"))

    def capable = "claude-sonnet-4"

    def routed(prompt) = described_class.default_router(capable).ask(task: prompt).await.model

    it "answers both models over the committed suite, so the fourth arm is not one model wearing two names" do
      expect(suite.map { |task| routed(task.prompt) }.tally)
        .to eq(capable => 5, described_class::CHEAP_MODEL => 3)
    end

    # The blocker this card was sent back for: the capable branch used to name an
    # absolute id, so an operator asking for sonnet bought opus on five of eight
    # tasks while the report header still said sonnet.
    it "keeps the capable branch on the model the backend resolved, whatever that is" do
      expect(routed("Rename the method in lib/a.rb, lib/b.rb and lib/c.rb.")).to eq(capable)
    end

    it "sends a task naming one file to the cheap sibling" do
      expect(routed("Fix the off-by-one in lib/report.rb.")).to eq(described_class::CHEAP_MODEL)
    end

    it "sends a task naming no file at all to the cheap sibling" do
      expect(routed("Explain what this project does.")).to eq(described_class::CHEAP_MODEL)
    end

    # The case against a length threshold, as an example rather than a comment:
    # on this very suite the two orderings DISAGREE, so a number tuned to bisect
    # it buys the cheap model for the widest task.
    it "disagrees with task length on this very suite, which no threshold on length can" do
      by_length = suite.sort_by { |task| task.prompt.length }
      shortest = by_length.first
      cheapest_routed = by_length.select { |task| routed(task.prompt) == described_class::CHEAP_MODEL }

      expect(routed(shortest.prompt)).to eq(capable)
      expect(cheapest_routed.map { |task| task.prompt.length }.min).to be > shortest.prompt.length
    end

    # The reason rides on the answer and is read back HERE, not from a journal:
    # Arm::AdaptiveRouter journals its Telemetry::OracleAnswer onto a run-local
    # Channel that Arm::Instrument#price then drains totally, so no routing
    # record reaches the experiment record today. Teeing it to the Driver's
    # journal is somebody's card, not this example's claim.
    it "says what it counted, not merely what it chose" do
      expect(described_class.default_router(capable).ask(task: "touch lib/a.rb and lib/b.rb").await.reason)
        .to include("2")
    end

    # LOUDLY, AND AT ASSEMBLY. `--provider ollama` is advertised and resolves a
    # model the cheap sibling means nothing to; the alternative to refusing is
    # asking a qwen3 endpoint for an Anthropic id on the fourth arm, after three
    # have billed.
    describe "a backend it cannot route" do
      it "refuses a model outside the family the cheap sibling belongs to" do
        expect { described_class.build(model: "qwen3:4b") }
          .to raise_error(described_class::UnroutableBackend, /qwen3:4b/)
      end

      # `--cheap-model` is the operator's way out now, not a Ruby-only `router:`
      # kwarg nobody can spell on a command line.
      it "names both ways out of that refusal" do
        expect { described_class.build(model: "qwen3:4b") }
          .to raise_error(described_class::UnroutableBackend, /--model.*--cheap-model/m)
      end

      # The other collapse, and it is not a provider problem: routing the cheap
      # sibling TO the cheap sibling puts both branches on one model, which is
      # the control billed twice under two names.
      it "refuses a backend already resolved to the cheap sibling itself" do
        expect { described_class.build(model: described_class::CHEAP_MODEL) }
          .to raise_error(described_class::UnroutableBackend)
      end

      it "builds the roster anyway when the caller brings its own tier" do
        router = Lain::Oracle::Heuristic.new(definition: Lain::Oracle::Router.definition,
                                             predicate: ->(*) { { "model" => "qwen3:0.6b", "template" => "" } })

        expect(described_class.build(model: "qwen3:4b", router:).map(&:name)).to include("adaptive-router")
      end
    end

    # `--cheap-model` names the sibling literally, so a backend the built-in
    # constant means nothing to still gets a routing arm.
    describe "a named --cheap-model" do
      def routed(model, task, cheap_model:)
        described_class.default_router(model, cheap_model:).ask(task:).await.model
      end

      it "sends a single-file task to the named cheap model" do
        expect(routed("qwen3-coder:30b", "Fix the off-by-one in lib/report.rb.", cheap_model: "qwen3:4b"))
          .to eq("qwen3:4b")
      end

      it "leaves a task spread across files on the capable model" do
        expect(routed("qwen3-coder:30b", "Rename the method in lib/a.rb, lib/b.rb and lib/c.rb.",
                      cheap_model: "qwen3:4b"))
          .to eq("qwen3-coder:30b")
      end

      it "refuses naming --cheap-model when the backend is not Claude and none was given" do
        expect { described_class.default_router("qwen3-coder:30b") }
          .to raise_error(described_class::UnroutableBackend, /--cheap-model/)
      end

      it "refuses a --cheap-model equal to the capable model, as running the control twice" do
        expect { described_class.default_router("qwen3:4b", cheap_model: "qwen3:4b") }
          .to raise_error(described_class::UnroutableBackend, /control twice/)
      end

      it "keeps the built-in cheap model on a Claude backend when --cheap-model is unset" do
        expect(described_class.default_router("claude-sonnet-4").ask(task: "Fix lib/x.rb.").await.model)
          .to eq(described_class::CHEAP_MODEL)
      end
    end
  end

  # THE ARM IS NOT INERT, and that is proven against the REAL spawn seam rather
  # than by reading. The first attempt at this wiring came back green while the
  # seam swallowed `model:` into an anonymous `**`, so the routed arm and the
  # control were the same program over the same Context -- and against a real
  # provider at temperature > 0 two identical arms differ by SAMPLING NOISE,
  # which reads as a finding rather than as a duplicate.
  #
  # So the assertion is on what the PROVIDER was asked for, which is the only
  # place the difference is unfakeable.
  describe "the fourth arm, driven through the real spawn seam" do
    let(:provider) do
      Lain::Provider::Mock.new(
        responses: [text_response("FILE lib/report.rb
done
END", model: "claude-sonnet-4",
      usage: Lain::Usage.new(input_tokens: 10, output_tokens: 5))]
      )
    end

    # The one object the seam takes, built from the flag hash the way every
    # other Backend spec builds it. Nothing here resolves a live provider.
    let(:backend) do
      Lain::CLI::Backend.new({ provider: "anthropic",
                               max_tokens: Lain::Bench::SpawnSeam::DEFAULT_MAX_TOKENS })
    end

    let(:seam) { Lain::Bench::SpawnSeam.new(backend:, provider:, tools: Lain::Bench::Harness::NO_TOOLS) }
    let(:arms) { described_class.build }

    def grader
      Lain::Grader::Fixture.new("any") { |fixture| fixture.check("ran") { |timeline| timeline.to_a.any? } }
    end

    # What the provider was actually asked for BY THIS RUN. The Mock records
    # every request it ever saw, so an example driving two arms would otherwise
    # read the first arm's requests back as the second's.
    def models_asked(name, task)
      seen = provider.requests.size
      arms.find { |arm| arm.name == name }.run(task, spawn_seam: seam, grader:)
      provider.requests.drop(seen).map(&:model)
    end

    def single_file = "Fix the off-by-one in lib/report.rb."
    def spread = "Rename the method in lib/a.rb, lib/b.rb and lib/c.rb."

    it "asks for a different model than the control does, on the very same task" do
      expect(models_asked("adaptive-router", single_file)).not_to eq(models_asked("single-thread", single_file))
    end

    it "asks for the cheap model on a single-file task" do
      expect(models_asked("adaptive-router", single_file)).to eq([described_class::CHEAP_MODEL])
    end

    # NOT A PIN ON THE SEAM, and labelled so nobody reads it as one: the capable
    # branch IS the backend's model, so this example stays green against a seam
    # that drops `model:` entirely. Its claim is the other one -- that the
    # capable branch does not depart from what the operator asked for.
    it "leaves a task spread across files on the backend's own model" do
      expect(models_asked("adaptive-router", spread)).to eq([backend.model])
    end

    # The control's half of the claim. Without it, "the two arms differ" passes
    # just as well for a control that had itself started routing.
    it "leaves the control arm on the backend's own model, whatever the task names" do
      expect(models_asked("single-thread", single_file) + models_asked("single-thread", spread))
        .to eq([backend.model, backend.model])
    end
  end

  # The pin the deletability map used to carry. simplify-03's `adaptive_router`
  # row asserted the arm was reachable from nothing and pinned this marker as a
  # SIDE EFFECT of that; wiring the arm removes the row, so the marker needs a
  # home that is about the claim rather than about a deletion.
  #
  # The label-to-filename mapping is safe HERE and nowhere else in this file:
  # each of `.build`'s arms is one class in one file named for it. `.altitude`'s
  # two epic entries are both `arm/epic.rb`, which is exactly why this is scoped
  # to `.build` rather than to every arm the module can name.
  describe "the four-arm claim ARCHITECTURE.md makes" do
    def architecture = File.read(File.expand_path("../../../ARCHITECTURE.md", __dir__))

    it "lists exactly the files .build's arms are classes in" do
      # Anchored on the sentence, not on the document's first brace list: the
      # unanchored spelling was correct today and silently retargetable.
      listed = architecture[%r{Four arms ship \(`arm/\{(.+?)\}\.rb`}, 1].split(",").map(&:strip)

      expect(listed).to eq(described_class.build.map { |arm| arm.name.tr("-", "_") })
    end
  end
end
