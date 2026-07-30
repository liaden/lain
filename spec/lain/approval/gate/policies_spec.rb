# frozen_string_literal: true

require "stringio"

# Policies is the factory between `[epics.gates]` and the Policy family: config
# names a policy per stage, one dependencies value carries every seam any policy
# could need, and the factory refuses loudly when the two do not line up.
RSpec.describe Lain::Approval::Gate::Policies do
  def artifact(digest: "blake3:plan", question: "Approve the epic plan? Reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  # The ask_human-shaped duck Interactive delegates to (policy_spec's helper).
  def scripted_asker(&resolver)
    Object.new.tap do |asker|
      asker.define_singleton_method(:ask) do |question|
        Lain::Promise.new.tap { |promise| yield(promise, question) }
      end
    end
  end

  def config_with(**gates)
    Lain::Config.new(
      epics: Lain::Config::Epics.new(
        home: :xdg, gates: Lain::Config::Epics::Gates.new(table: gates.transform_keys(&:to_s))
      )
    )
  end

  let(:plan) { artifact }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:gate) { Lain::Approval::Gate.new(journal:, timeout: 0.5) }
  let(:queue) { Lain::Approval::SignoffQueue.new }
  let(:asked) { [] }
  let(:asker) do
    questions = asked
    scripted_asker do |promise, question|
      questions << question
      promise.resolve(Lain::Approval::Gate::Answer.approve("human"))
    end
  end
  let(:deps) { described_class::Deps.new(queue:, asker:, journal:) }

  def decide(policy, stage:, epic_slug: "alpha")
    Sync { policy.decide(plan, gate:, stage:, epic_slug:) }
  end

  describe "per-stage policies resolve from config" do
    let(:config) { config_with(research: "hands_off", epic_plan: "deferred") }

    it "builds a HandsOff for a stage the table names hands_off" do
      expect(described_class.for(stage: "research", config:, deps:))
        .to be_a(Lain::Approval::Gate::Policy::HandsOff)
    end

    it "builds a Deferred for a stage the table names deferred" do
      expect(described_class.for(stage: "epic_plan", config:, deps:))
        .to be_a(Lain::Approval::Gate::Policy::Deferred)
    end

    # "holding the injected queue", asked behaviourally: a deferral parks onto
    # THAT queue, which no ivar peek could prove and a wrong wiring would fail.
    it "hands the Deferred the injected queue -- the deferral parks there" do
      decide(described_class.for(stage: "epic_plan", config:, deps:), stage: "epic_plan")

      expect(queue.parked("alpha", "epic_plan").size).to eq(1)
    end

    it "hands the Interactive the injected asker -- the question reaches it" do
      decide(described_class.for(stage: "issue_plan", config:, deps:), stage: "issue_plan")

      expect(asked).to eq([plan.gate_question])
    end

    it "defaults an unnamed stage to Interactive" do
      expect(described_class.for(stage: "issue_plan", config:, deps:))
        .to be_a(Lain::Approval::Gate::Policy::Interactive)
    end

    it "defaults every stage to Interactive when no config names any" do
      built = Lain::Epic::STAGES.map { |stage| described_class.for(stage:, config: Lain::Config.empty, deps:) }

      expect(built).to all(be_a(Lain::Approval::Gate::Policy::Interactive))
    end

    it "accepts a Stage value as readily as its name" do
      expect(described_class.for(stage: Lain::Epic::Stage.new("research"), config:, deps:))
        .to be_a(Lain::Approval::Gate::Policy::HandsOff)
    end
  end

  describe "the catalog" do
    it "names exactly the policies this card ships" do
      expect(described_class.names).to contain_exactly("interactive", "hands_off", "deferred")
    end

    it "defaults to interactive, the label Gate's own un-wrapped path journals" do
      expect(described_class::DEFAULT).to eq(Lain::Approval::Gate::DEFAULT_POLICY)
    end

    it "agrees with what Config validates against -- one list, widened in one place" do
      expect(described_class.names.all? { |name| described_class.known?(name) }).to be(true)
    end

    # Every declared seam has to be a reader on Deps, or the refusal path would
    # itself NoMethodError on the seam it was trying to name.
    it "declares only seams the dependencies value actually carries" do
      declared = described_class::CATALOG.values.flat_map(&:seams).uniq

      expect(declared - described_class::Deps.members).to be_empty
    end
  end

  describe "a policy whose seams are nil in deps" do
    # The requirement is DATA, per policy: hands_off needs no asker and builds
    # without one, while interactive at the same stage with the same deps
    # refuses. A blanket "all seams present" check passes the first and fails
    # the second, so this pair is what pins the per-policy declaration.
    it "builds a policy that does not declare the missing seam" do
      askerless = described_class::Deps.new(queue:, asker: nil, journal:)

      expect(described_class.for(stage: "research", config: config_with(research: "hands_off"), deps: askerless))
        .to be_a(Lain::Approval::Gate::Policy::HandsOff)
    end

    it "refuses a policy that does declare it, naming the stage, the policy, and the seam" do
      askerless = described_class::Deps.new(queue:, asker: nil, journal:)

      expect { described_class.for(stage: "research", config: config_with(research: "interactive"), deps: askerless) }
        .to raise_error(described_class::MissingSeam) do |error|
          expect(error.message).to include("research")
          expect(error.message).to include("interactive")
          expect(error.message).to include("asker")
        end
    end

    # The Gherkin's literal case (`role_spawn`), exercised through the same
    # Recipe every catalog entry is -- the mechanism, not a stubbed factory.
    # T14's Adjudicated is one more Recipe with these seams declared.
    it "names role_spawn for a recipe that declares it" do
      recipe = described_class::Recipe.new(seams: %i[queue role_spawn brief],
                                           builder: ->(_deps) { raise "must not be built" })

      expect { recipe.build(deps, stage: "epic_plan", policy: "adjudicated") }
        .to raise_error(described_class::MissingSeam) do |error|
          expect(error.message).to include("epic_plan")
          expect(error.message).to include("adjudicated")
          expect(error.message).to include("role_spawn")
        end
    end

    it "names every missing seam in one pass, not just the first" do
      recipe = described_class::Recipe.new(seams: %i[role_spawn brief],
                                           builder: ->(_deps) { raise "must not be built" })

      expect { recipe.build(deps, stage: "epic_plan", policy: "adjudicated") }
        .to raise_error(/role_spawn.*brief/m)
    end

    it "builds through the recipe, handing it the whole dependencies value" do
      recipe = described_class::Recipe.new(seams: %i[queue journal], builder: ->(wiring) { [wiring] })

      expect(recipe.build(deps, stage: "epic_plan", policy: "whatever")).to eq([deps])
    end

    # Panel NIT: "which needs role_spawn -- this session wired none" is false
    # twice over when the queue IS wired. The message may only claim what is
    # actually missing.
    it "says what is missing rather than claiming nothing was wired" do
      recipe = described_class::Recipe.new(seams: %i[queue role_spawn], builder: ->(*) {})

      expect { recipe.build(deps, stage: "epic_plan", policy: "adjudicated") }
        .to raise_error(described_class::MissingSeam) do |error|
          expect(error.message).to include("is missing role_spawn")
          expect(error.message).not_to include("none")
        end
    end

    # Panel NIT: the rule this class documents is "nil-able", so nil is the test.
    # A seam deliberately wired to `false` is wired.
    it "treats a seam wired to false as present -- the rule is nil, not falsiness" do
      falsey = described_class::Deps.new(queue: false, asker:, journal:)
      recipe = described_class::Recipe.new(seams: %i[queue], builder: ->(wiring) { [wiring.queue] })

      expect(recipe.build(falsey, stage: "research", policy: "hands_off")).to eq([false])
    end
  end

  # Panel Fix 1: a seam name Deps has no reader for made the refusal path itself
  # die unnamed (`NoMethodError: undefined method 'askr'`) inside the one method
  # whose whole job is to refuse BY NAME. T14 adds a fourth catalog row by hand,
  # so the guard belongs in the constructor rather than in a spec over the three
  # rows that ship today.
  describe "a recipe declaring a seam the dependencies value does not carry" do
    it "refuses at construction, naming the typo and the members that exist" do
      expect { described_class::Recipe.new(seams: %i[askr], builder: ->(*) {}) }
        .to raise_error(described_class::UnknownSeam) do |error|
          expect(error.message).to include("askr")
          expect(error.message).to include("asker")
        end
    end

    it "names every unknown seam in one pass, not just the first" do
      expect { described_class::Recipe.new(seams: %i[askr rolespawn], builder: ->(*) {}) }
        .to raise_error(/askr.*rolespawn/m)
    end

    it "accepts every member Deps actually carries" do
      expect { described_class::Recipe.new(seams: described_class::Deps.members, builder: ->(*) {}) }
        .not_to raise_error
    end

    it "is a Lain::Error, so exe/lain's mapping catches it" do
      expect(described_class::UnknownSeam.ancestors).to include(Lain::Error)
    end
  end

  # Panel Fix 3: `.for` is per-stage, so a session whose `implementation` policy
  # needs a seam it never wired builds the first three stages happily and
  # refuses hours in, unattended -- the very failure this class's doc claims to
  # prevent. Resolving the whole pipeline up front is what pays that claim.
  describe ".for_all" do
    it "resolves every stage in the pipeline, in pipeline order" do
      built = described_class.for_all(config: config_with(research: "hands_off"), deps:)

      expect(built.keys).to eq(Lain::Epic::STAGES)
    end

    it "gives each stage the policy its config names, and interactive elsewhere" do
      built = described_class.for_all(config: config_with(research: "hands_off", epic_plan: "deferred"), deps:)

      expect(built.values.map(&:name)).to eq(%w[hands_off deferred interactive interactive])
    end

    it "refuses at wiring time for a seam only a LATER stage needs" do
      askerless = described_class::Deps.new(queue:, asker: nil, journal:)
      config = config_with(research: "hands_off", epic_plan: "hands_off", issue_plan: "hands_off")

      expect { described_class.for_all(config:, deps: askerless) }
        .to raise_error(described_class::MissingSeam) do |error|
          expect(error.message).to include("implementation")
          expect(error.message).to include("asker")
        end
    end

    # The point of the pair: `.for` alone is happy to build the early stages of
    # exactly the session `.for_all` refuses, which is why late is the defect.
    it "refuses a session whose earlier stages .for would have built without complaint" do
      askerless = described_class::Deps.new(queue:, asker: nil, journal:)
      config = config_with(research: "hands_off", epic_plan: "hands_off", issue_plan: "hands_off")

      expect(described_class.for(stage: "research", config:, deps: askerless))
        .to be_a(Lain::Approval::Gate::Policy::HandsOff)
    end

    it "hands back a frozen map, so a caller cannot edit the session's wiring" do
      expect(described_class.for_all(config: Lain::Config.empty, deps:)).to be_frozen
    end
  end

  describe "a policy name outside the catalog" do
    # Config refuses these at load, so this is the factory answering for the
    # config ducks it does NOT parse -- loud, and a Lain::Error rather than the
    # bare KeyError a plain fetch would raise.
    it "refuses, naming the stage, the name, and the known policies" do
      config = Object.new
      config.define_singleton_method(:gate_policy_for) { |_stage| "signoff" }

      expect { described_class.for(stage: "research", config:, deps:) }
        .to raise_error(described_class::Unknown) do |error|
          expect(error.message).to include("signoff")
          expect(error.message).to include("research")
          expect(error.message).to include("hands_off")
        end
    end

    it "is a Lain::Error, so exe/lain's mapping catches it" do
      expect(described_class::Unknown.ancestors).to include(Lain::Error)
      expect(described_class::MissingSeam.ancestors).to include(Lain::Error)
    end
  end

  describe "the dependencies value" do
    it "is frozen -- one value passed around, never mutated by a recipe" do
      expect(deps).to be_frozen
    end

    it "leaves the adjudication seams nil by default" do
      expect([deps.role_spawn, deps.brief]).to eq([nil, nil])
    end

    it "carries the adjudication seams when a caller fills them" do
      spawn = ->(*) {}
      filled = described_class::Deps.new(queue:, asker:, journal:, role_spawn: spawn, brief: ->(*) { "" })

      expect(filled.role_spawn).to equal(spawn)
    end
  end
end
