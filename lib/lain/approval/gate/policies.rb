# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # WHICH policy a stage runs under, read off `epics` gates and built
      # from one dependencies value. {Policy} is how a verdict is reached; this
      # is the choosing, kept apart because choosing is a WIRING concern.
      #
      # == One dependencies value, per-policy seam declarations
      #
      # The family's constructors disagree, so the factory takes the UNION once
      # as {Deps} and each {Recipe} declares which members it needs. That
      # declaration is DATA rather than a constructor's arity, which is what
      # makes the refusal possible: an `adjudicated` stage in a session that
      # never wired a `role_spawn` is named at WIRING time -- stage, policy and
      # missing seam -- instead of NoMethodError-ing on the first overnight gate
      # with nobody watching.
      #
      # A blanket "every seam present" check would be simpler and wrong: it
      # would force every session to wire an adjudicator's spawn seam just to
      # run `hands_off`.
      #
      # == The name set lives HERE, once
      #
      # {Config::Epics::Gates} validates a configured policy name by asking
      # {known?} rather than keeping a second list. That is an UPWARD dependency
      # and it is deliberate: the lookup happens inside {Config.load}, long
      # after both are loaded, and it buys the property that widening the family
      # is a one-line edit here. Two lists would drift, and the drift's shape is
      # a config that loads and then refuses to build.
      module Policies
        # Every refusal this factory makes, as one class. Four bespoke errors
        # for a four-entry catalog read as four things a caller might rescue
        # apart, and nothing ever did -- `exe/lain` maps {Lain::Error} and no
        # site in `lib/` names one of the four. {Config::Refusal}'s posture,
        # one subsystem over: the sentence is what sends an operator to a line
        # of `epics` gates, and the class name was never the part doing that.
        #
        # What the four carried that a reader still needs is WHICH entry and
        # WHY, so the stage, the policy and the seams are attributes and
        # {#kind} keeps the four apart for anyone who does want to branch on
        # one. The distinction that earns its keep is `:missing_seam` against
        # `:unusable_seam`: one says wire it, the other says wire something
        # else, and the fix differs.
        class Refusal < Error
          # @return [Symbol] `:unknown_policy`, `:missing_seam`,
          #   `:unusable_seam`, or `:unknown_seam` -- the last being a recipe
          #   ROW written wrong rather than a session wired wrong
          attr_reader :kind
          # @return [String, nil] the `epics` gates stage that asked
          attr_reader :stage
          # @return [String, nil] the configured policy name
          attr_reader :policy
          # @return [Array<String>] the seams this refusal is about
          attr_reader :seams

          # Config refuses these at load, so this is the factory answering for
          # the config ducks it did not parse -- a {Lain::Error} rather than the
          # bare KeyError a plain `fetch` would raise past `exe/lain`'s mapping.
          def self.unknown_policy(policy, stage:, known:)
            new("epic stage #{stage.to_s.inspect} is configured for the unknown gate policy " \
                "#{policy.inspect} (known policies: #{known.join(", ")})",
                kind: :unknown_policy, stage:, policy:)
          end

          # A policy configured into a session that never wired what it needs.
          # Only the ABSENT seams are named, so the sentence says "missing"
          # rather than "needs": claiming a session wired neither of two seams
          # when it wired one would send a reader to the wrong one.
          def self.missing_seam(missing, stage:, policy:)
            new("epic stage #{stage.to_s.inspect} is configured for the #{policy.inspect} gate " \
                "policy, but this session is missing #{missing.join(", ")}",
                kind: :missing_seam, stage:, policy:, seams: missing)
          end

          # A seam that is PRESENT and cannot do what its policy needs of it.
          def self.unusable_seam(detail, stage:, policy:)
            new("epic stage #{stage.to_s.inspect} is configured for the #{policy.inspect} " \
                "gate policy, but #{detail}",
                kind: :unusable_seam, stage:, policy:)
          end

          # Refused at CONSTRUCTION, because the alternative is that
          # {Recipe#build} -- the one method whose whole job is to refuse by
          # name -- dies on `public_send` with an unnamed NoMethodError while
          # trying to name it. A spec over the shipped rows would not have
          # covered this: rows are added by hand.
          def self.unknown_seam(unknown, known:)
            new("a gate policy recipe declares #{unknown.join(", ")}, which the dependencies " \
                "value does not carry (its seams are #{known.join(", ")})",
                kind: :unknown_seam, seams: unknown)
          end

          # MESSAGE FIRST, on {Config::Refusal}'s shape, because `raise Refusal,
          # "detail"` is a live idiom in this codebase (`cli/backend/ollama_tier.rb`,
          # `cli/chat_launch.rb`) and Ruby routes it to `.new` with one positional.
          # A leading `kind` would take the sentence as the discriminator and
          # leave the refusal rendering as a bare class name -- discarding the
          # operator sentence this class exists to carry. `kind:` stays REQUIRED
          # so that idiom fails loudly at its own line rather than building a
          # refusal that cannot say which one it is.
          def initialize(message, kind:, stage: nil, policy: nil, seams: [])
            @kind = kind
            @stage = stage&.to_s
            @policy = policy
            @seams = seams.map(&:to_s).freeze
            super(message)
          end
        end

        # Every collaborator any policy could want, as ONE value so a caller
        # wires a session once instead of per stage.
        #
        # `role_spawn` and `brief` default to nil -- a session with no
        # meta-agent wiring is the normal case, and nil is a fact there, not an
        # oversight. The other three are REQUIRED keywords: a caller must SAY it
        # has no asker rather than forget one, because forgetting is exactly how
        # a gate ends up unable to ask anybody anything.
        Deps = Data.define(:queue, :asker, :journal, :role_spawn, :brief) do
          def initialize(queue:, asker:, journal:, role_spawn: nil, brief: nil)
            super
          end

          # The same wiring, for a stage this session will never put to its
          # asker: a session with none is handed {Nobody} there, so that stage
          # still builds and every OTHER seam it needs is still checked.
          def unasked = asker.nil? ? with(asker: Nobody) : self
        end

        # The asker of a session that has none, standing in only for the stages
        # {.for_all} was told this session does not decide. Refusing rather
        # than answering, so a caller that reached for one of those policies
        # anyway gets a named refusal and never a verdict nobody gave.
        module Nobody
          UNASKED = "this session has nobody to put a gate's question to, and was built to decide other stages"

          def self.ask(_question) = raise(Refusal.new(UNASKED, kind: :missing_seam, seams: ["asker"]))
        end

        # The seams a policy needs and how to build it from them. Both members
        # are data, so adding a policy is adding a row.
        Recipe = Data.define(:seams, :builder) do
          # @raise [Refusal] `:unknown_seam` when a declared seam is not a {Deps} member
          def initialize(seams:, builder:)
            seams = seams.map(&:to_sym).freeze
            unknown = seams - Deps.members
            raise Refusal.unknown_seam(unknown, known: Deps.members) unless unknown.empty?

            super
          end

          # @param deps [Deps] the session's wiring
          # @param stage [#to_s] which stage asked, named in a refusal
          # @param policy [String] the configured name, named in a refusal
          # @return [Policy]
          # @raise [Refusal] `:missing_seam`, naming every seam this recipe
          #   needs and deps lacks
          def build(deps, stage:, policy:)
            missing = missing(deps)
            raise Refusal.missing_seam(missing, stage:, policy:) unless missing.empty?

            construct(deps, stage, policy)
          end

          # @param deps [Deps] the session's wiring
          # @return [Boolean] whether that wiring carries every seam this needs
          def runs_on?(deps) = missing(deps).empty?

          private

          # `nil?`, not falsiness: {Deps} documents the adjudication seams as
          # NIL-able, so a seam deliberately wired to `false` is wired.
          def missing(deps) = seams.select { |seam| deps.public_send(seam).nil? }

          # A policy that refused its OWN construction. Re-raised with the
          # stage on it because only the factory knows which `epics` gates
          # line asked, and a startup refusal that cannot name the stage sends
          # an operator to the wrong one. Scoped to this ONE call, so it can
          # never swallow the refusal {#build} raises itself.
          def construct(deps, stage, policy)
            builder.call(deps)
          rescue Error => e
            raise Refusal.unusable_seam(e.message, stage:, policy:)
          end
        end

        # Widening the family is this table plus the policy itself;
        # {Config::Epics::Gates} reads its valid names from here.
        CATALOG = {
          Policy::Interactive::NAME => Recipe.new(
            seams: %i[asker queue],
            builder: ->(deps) { Policy::Interactive.new(asker: deps.asker, queue: deps.queue) }
          ),
          Policy::HandsOff::NAME => Recipe.new(
            seams: %i[queue],
            builder: ->(deps) { Policy::HandsOff.new(queue: deps.queue) }
          ),
          Policy::Deferred::NAME => Recipe.new(
            seams: %i[queue],
            builder: ->(deps) { Policy::Deferred.new(queue: deps.queue) }
          ),
          # The one row wanting the adjudication seams -- what the per-policy
          # declaration was for: a session running `hands_off` overnight still
          # wires no spawn, and one naming this policy without a spawn is
          # refused at startup, by NAME.
          Policy::Adjudicated::NAME => Recipe.new(
            seams: %i[queue journal role_spawn brief],
            builder: lambda { |deps|
              Policy::Adjudicated.new(role_spawn: deps.role_spawn, brief: deps.brief,
                                      journal: deps.journal, queue: deps.queue)
            }
          )
        }.freeze

        # The same string {Gate#call} already journals un-wrapped, so defaulting
        # relabels nothing.
        DEFAULT = Policy::Interactive::NAME

        # @return [Array<String>] every configurable policy name
        def self.names = CATALOG.keys

        # The policies a session wired this way could run at all, which is what
        # a refusal names as the way forward.
        #
        # @param deps [Deps] the session's wiring
        # @return [Array<String>] catalog names, in catalog order
        def self.runnable(deps) = CATALOG.select { |_name, recipe| recipe.runs_on?(deps) }.keys

        # @param name [Object] a configured value, of any type -- membership is
        #   tested against the known STRINGS directly, so an Integer simply is
        #   not one
        def self.known?(name) = CATALOG.key?(name)

        # Build the policy this stage runs under.
        #
        # @param stage [#to_s] an {Epic::Stage} or its name
        # @param config [#gate_policy_for] the loaded {Lain::Config}
        # @param deps [Deps] the session's wiring
        # @return [Policy]
        # @raise [Refusal] `:unknown_policy` when config names a policy the
        #   catalog has no recipe for, `:missing_seam` when the recipe needs a
        #   seam `deps` left nil
        def self.for(stage:, config:, deps:)
          policy = config.gate_policy_for(stage)
          recipe(policy, stage).build(deps, stage:, policy:)
        end

        # The whole pipeline, resolved eagerly -- and the method a session
        # should wire through.
        #
        # {.for} alone refuses LATE, because it is asked one stage at a time: a
        # session that left `asker` nil builds research, epic_plan and
        # issue_plan without complaint, then refuses when the implementation
        # gate arrives -- hours in, unattended, the exact failure this module
        # exists to prevent. Resolving every stage up front makes it a startup
        # refusal.
        #
        # == Except the asker, for the stages a session will not decide
        #
        # A missing role spawn is a process wired wrong, and is refused for
        # every stage. A missing asker is a fact about where the session runs
        # -- no terminal -- and it matters only at a stage that asks. A
        # one-stage session (`lain epic submit`) says which stage it decides in
        # `asking:`, so an unattended `hands_off` submit is not refused over a
        # stage it was never going to reach; the stages outside it are built
        # over {Nobody} with every other seam still checked. The default is
        # every stage, which is the long session this method exists for.
        #
        # @param config [#gate_policy_for] the loaded {Lain::Config}
        # @param deps [Deps] the session's wiring
        # @param asking [Array<String>] the stages this session will put to its
        #   asker, when it has one
        # @return [Hash{String => Policy}] frozen, keyed by stage in pipeline order
        # @raise [Refusal] for ANY stage, before the session runs
        # @raise [Epic::UnknownStage] when `asking` names a stage the pipeline
        #   does not hold -- a typo there would silently stop every stage asking
        def self.for_all(config:, deps:, asking: Epic::STAGES)
          unknown = asking - Epic::STAGES
          unless unknown.empty?
            raise Epic::UnknownStage, "asking names #{unknown.join(", ")}, which the pipeline does not hold " \
                                      "(its stages are #{Epic::STAGES.join(", ")})"
          end

          Epic::STAGES.to_h do |stage|
            [stage, self.for(stage:, config:, deps: asking.include?(stage) ? deps : deps.unasked)]
          end.freeze
        end

        def self.recipe(policy, stage)
          CATALOG.fetch(policy) { raise Refusal.unknown_policy(policy, stage:, known: names) }
        end
        private_class_method :recipe
      end
    end
  end
end
