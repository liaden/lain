# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      # WHICH policy a stage runs under, read off `[epics.gates]` and built from
      # one dependencies value.
      #
      # {Policy} is how a verdict is reached; this is the choosing. The pair is
      # kept apart because the choice is a WIRING concern -- it reads config,
      # knows every seam any policy could want, and refuses combinations that
      # cannot be built -- while a policy knows only its own surface.
      #
      # == One dependencies value, per-policy seam declarations
      #
      # The family's constructors disagree ({Policy::Interactive} takes an asker,
      # {Policy::HandsOff} does not, {Policy::Adjudicated} takes a `role_spawn`,
      # a `brief` and a journal it can read back), so the factory takes the
      # UNION once as {Deps} and each
      # {Recipe} declares which members it actually needs. The declaration is
      # DATA rather than a constructor's arity, which is what makes the refusal
      # possible at all: an `adjudicated` stage configured in a session that
      # never wired a `role_spawn` is named at wiring time -- stage, policy, and
      # missing seam -- instead of NoMethodError-ing on the first overnight gate
      # with nobody watching.
      #
      # A blanket "every seam present" check would be simpler and wrong: it would
      # force every session to wire an adjudicator's spawn seam just to run
      # `hands_off`. Per-policy is the whole point, and a spec pins the pair.
      #
      # == The name set lives HERE, once
      #
      # {Config::Epics::Gates} validates a configured policy name by asking
      # {known?}, rather than keeping a second list of its own. That is an
      # upward dependency (config.rb loads twelfth in lain.rb's manifest, this
      # subtree forty-ninth) and it is deliberate: the lookup happens inside
      # {Config.load}, long after both are loaded, and it buys the property that
      # widening the family is a one-line edit in this file. Two lists would
      # drift, and the drift's shape is a config that loads and then refuses to
      # build.
      module Policies
        # A configured policy name nothing in the catalog answers to. Config
        # refuses these at load, so this is the factory answering for the config
        # ducks it did not parse -- a {Lain::Error} rather than the bare KeyError
        # a plain `fetch` would raise past `exe/lain`'s mapping.
        class Unknown < Error; end

        # A policy configured into a session that never wired what it needs.
        class MissingSeam < Error; end

        # A seam that is PRESENT and cannot do what its policy needs of it --
        # the `journal:` an adjudicated gate must also be able to read back.
        # Distinct from {MissingSeam} because the fix is different: one says
        # wire it, this one says wire something else.
        class UnusableSeam < Error; end

        # A {Recipe} declaring a seam {Deps} has no reader for. Refused at
        # CONSTRUCTION, because the alternative is that {Recipe#build} --- the
        # one method whose whole job is to refuse by name --- dies on
        # `public_send` with an unnamed NoMethodError while trying to name it.
        # A spec over the shipped rows would not have covered this: rows are
        # added by hand, and the row that first declared a seam beyond
        # `queue`/`asker` (`adjudicated`) landed a card after this check did.
        class UnknownSeam < Error; end

        # Every collaborator any policy in the family could want, passed as ONE
        # value so a caller wires a session once instead of per stage.
        #
        # `role_spawn` and `brief` are the adjudication seams and default to nil
        # -- a session with no meta-agent wiring is the normal case, and nil here
        # is a fact ("this session cannot spawn"), not an oversight. The other
        # three are required keywords: a caller must SAY it has no asker
        # (`asker: nil`) rather than forget one, because forgetting is exactly
        # how a gate ends up unable to ask anybody anything.
        Deps = Data.define(:queue, :asker, :journal, :role_spawn, :brief) do
          def initialize(queue:, asker:, journal:, role_spawn: nil, brief: nil)
            super
          end
        end

        # One policy's entry in the catalog: the seams it needs, and how to build
        # it from them. Both members are data, so adding a policy is adding a row.
        Recipe = Data.define(:seams, :builder) do
          # @raise [UnknownSeam] when a declared seam is not a {Deps} member
          def initialize(seams:, builder:)
            seams = seams.map(&:to_sym).freeze
            unknown = seams - Deps.members
            raise UnknownSeam, unknown_message(unknown) unless unknown.empty?

            super
          end

          # @param deps [Deps] the session's wiring
          # @param stage [#to_s] which stage asked, named in a refusal
          # @param policy [String] the configured name, named in a refusal
          # @return [Policy]
          # @raise [MissingSeam] naming every seam this recipe needs and deps lacks
          def build(deps, stage:, policy:)
            # `nil?`, not falsiness: the contract {Deps} documents is that the
            # adjudication seams are NIL-able, so a seam deliberately wired to
            # `false` is wired.
            missing = seams.select { |seam| deps.public_send(seam).nil? }
            raise MissingSeam, missing_message(missing, stage, policy) unless missing.empty?

            construct(deps, stage, policy)
          end

          private

          # A policy that refused its OWN construction -- a seam that is there
          # and cannot do the job ({Policy::Adjudicated::UnreadableJournal}).
          # Re-raised with the stage on it because only the factory knows which
          # `[epics.gates]` line asked, and a startup refusal that cannot name
          # the stage sends an operator to the wrong one. Scoped to this one
          # call rather than the whole method, so it can never swallow the
          # refusal {#build} raises itself.
          def construct(deps, stage, policy)
            builder.call(deps)
          rescue Error => e
            raise UnusableSeam, "epic stage #{stage.to_s.inspect} is configured for the #{policy.inspect} " \
                                "gate policy, but #{e.message}"
          end

          def unknown_message(unknown)
            "a gate policy recipe declares #{unknown.join(", ")}, which the dependencies value does not " \
              "carry (its seams are #{Deps.members.join(", ")})"
          end

          # Only the ABSENT seams are named, so the sentence has to say
          # "missing" rather than "needs": a recipe wanting queue and role_spawn
          # against a session holding a live queue is missing one of the two,
          # and claiming it wired neither would send a reader to the wrong seam.
          def missing_message(missing, stage, policy)
            "epic stage #{stage.to_s.inspect} is configured for the #{policy.inspect} gate policy, " \
              "but this session is missing #{missing.join(", ")}"
          end
        end

        # Name -> recipe. Widening the family is this table plus the policy
        # itself; {Config::Epics::Gates} reads its valid names from here.
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
          # The one row that wants the adjudication seams, which is what the
          # per-policy declaration was for: a session running `hands_off`
          # overnight still wires no spawn, and a session that names this
          # policy without one is refused at startup by NAME.
          Policy::Adjudicated::NAME => Recipe.new(
            seams: %i[queue journal role_spawn brief],
            builder: lambda { |deps|
              Policy::Adjudicated.new(role_spawn: deps.role_spawn, brief: deps.brief,
                                      journal: deps.journal, queue: deps.queue)
            }
          )
        }.freeze

        # What a stage with no `[epics.gates]` entry runs under. The same string
        # {Gate#call} already journals un-wrapped, so defaulting relabels nothing.
        DEFAULT = Policy::Interactive::NAME

        # @return [Array<String>] every configurable policy name
        def self.names = CATALOG.keys

        # @param name [Object] a configured value, of any type -- membership is
        #   tested against the known STRINGS directly, so an Integer simply is
        #   not one ({Config::Epics::HOME_VALUES}'s posture)
        def self.known?(name) = CATALOG.key?(name)

        # Build the policy this stage runs under.
        #
        # @param stage [#to_s] an {Epic::Stage} or its name
        # @param config [#gate_policy_for] the loaded {Lain::Config}
        # @param deps [Deps] the session's wiring
        # @return [Policy]
        # @raise [Unknown] when config names a policy the catalog has no recipe for
        # @raise [MissingSeam] when the recipe needs a seam `deps` left nil
        def self.for(stage:, config:, deps:)
          policy = config.gate_policy_for(stage)
          recipe(policy, stage).build(deps, stage:, policy:)
        end

        # The whole pipeline, resolved eagerly -- and the method a session
        # should wire through.
        #
        # {.for} alone refuses LATE by construction, because it is asked one
        # stage at a time: a session that left `asker` nil and runs
        # `implementation` interactively builds research, epic_plan and
        # issue_plan without complaint, then refuses when the implementation
        # gate arrives -- hours in, unattended, which is the exact failure this
        # module exists to prevent. Resolving every stage up front is what turns
        # it into a startup refusal.
        #
        # @param config [#gate_policy_for] the loaded {Lain::Config}
        # @param deps [Deps] the session's wiring
        # @return [Hash{String => Policy}] frozen, keyed by stage in pipeline order
        # @raise [Unknown, MissingSeam] for ANY stage, before the session runs
        def self.for_all(config:, deps:)
          Epic::STAGES.to_h { |stage| [stage, self.for(stage:, config:, deps:)] }.freeze
        end

        def self.recipe(policy, stage)
          CATALOG.fetch(policy) do
            raise Unknown, "epic stage #{stage.to_s.inspect} is configured for the unknown gate policy " \
                           "#{policy.inspect} (known policies: #{names.join(", ")})"
          end
        end
        private_class_method :recipe
      end
    end
  end
end
