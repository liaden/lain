# frozen_string_literal: true

module Lain
  class Config
    class Epics
      # The `[epics.gates]` sub-table: which {Approval::Gate::Policy} each epic
      # stage's gates run under (`epic_plan = "deferred"`). Its own small class
      # for {Epics}'s own reason -- it knows its keys, its allowed values, and
      # its errors -- and BOTH sides of the mapping are closed sets, so both are
      # refused at load rather than discovered at the first overnight gate.
      #
      # The allowed VALUES are not spelled here: {Approval::Gate::Policies.known?}
      # answers, so widening the policy family is one edit in the factory rather
      # than two that can disagree. That reference is resolved at CALL time,
      # which is why it does not invert lain.rb's load order.
      #
      # Absence means interactive everywhere, so {#policy_for} is total: a stage
      # nobody configured still gets a policy, and no caller writes a nil guard.
      Gates = Data.define(:table)

      class Gates
        # Reopened for {Epics}'s reason: constants and nested classes inside a
        # `Data.define do ... end` block are scoped to the enclosing module.

        # The three refusals share a shape -- a path that may be absent (a value
        # built directly rather than loaded) and a message naming the sub-table
        # -- so the prefix is spelled once here instead of three times.
        class Refusal < Error
          attr_reader :path

          def initialize(path, detail)
            @path = path
            prefix = path ? "#{path}: " : ""
            super("#{prefix}[epics.gates] #{detail}")
          end
        end

        # `gates` present but not a table (`gates = "deferred"`), the sibling of
        # {Epics::NotATable} and for its reason: `.keys` on a String is an
        # unnamed NoMethodError three frames from the file that caused it.
        class NotATable < Refusal
          attr_reader :value

          def initialize(value, path: nil)
            @value = value
            super(path, "must be a table, got #{value.class}: #{value.inspect}")
          end
        end

        # A stage name outside {Epic::STAGES}. Loud rather than ignored: a
        # silently dropped `reserch = "deferred"` leaves that stage interactive,
        # so an unattended run wedges on a gate nobody is there to answer.
        # `keys` matches {Epics::UnknownKeys}'s reader, and every unknown stage
        # is reported in one pass.
        class UnknownStages < Refusal
          attr_reader :keys

          def initialize(keys, path: nil)
            @keys = keys
            super(path, "has no stages #{keys.map(&:inspect).join(", ")}; " \
                        "the pipeline is #{Epic::STAGES.join(" -> ")}")
          end
        end

        # A policy name no recipe answers to -- including a value of the wrong
        # TYPE, which simply fails the membership test rather than being coerced
        # first ({Epics::InvalidHome}'s posture).
        class UnknownPolicies < Refusal
          attr_reader :policies

          def initialize(policies, path: nil)
            @policies = policies
            super(path, "names unknown gate policies #{policies.map(&:inspect).join(", ")}; " \
                        "known policies: #{Approval::Gate::Policies.names.join(", ")}")
          end
        end

        # @param table [Object] whatever `[epics] gates` parsed to; nil when absent
        # @param path [String, nil] the config file, named in every refusal
        # @return [Gates]
        def self.from(table, path: nil)
          table = {} if table.nil?
          check!(table, path:)
          new(table:)
        end

        # A caller that is not {.from} may reasonably hand a plain Hash, or nil
        # for "none configured". Coercing here is what makes {Epics#initialize}'s
        # guard total: a typo'd policy name in a hand-built value raises
        # {UnknownPolicies} naming it, where storing the Hash as handed deferred
        # the failure to an unnamed NoMethodError inside {Config#gate_policy_for}
        # -- no path, no key, and a stack frame away from the mistake.
        def self.coerce(gates) = gates.is_a?(self) ? gates : from(gates)

        # @return [Gates] the value an absent sub-table yields
        def self.empty = EMPTY

        # The closed-set checks, shared by {.from} (which names the config file)
        # and by {#initialize} (which cannot, and passes nil).
        #
        # @raise [NotATable, UnknownStages, UnknownPolicies]
        def self.check!(table, path: nil)
          raise NotATable.new(table, path:) unless table.is_a?(Hash)
          # An empty table has no key and no value to judge, so it is vacuously
          # valid -- and answering HERE, before either closed set is read, is
          # also what lets {EMPTY} be built while this file loads (see the note
          # at {Config::EMPTY}). Every non-empty table arrives through
          # {Config.load}, long after both sets exist.
          return if table.empty?

          unknown = table.keys - Epic::STAGES
          raise UnknownStages.new(unknown, path:) unless unknown.empty?

          unnamed = table.values.reject { |policy| Approval::Gate::Policies.known?(policy) }
          raise UnknownPolicies.new(unnamed, path:) unless unnamed.empty?
        end

        # Validated in the value's own constructor as well as in {.from}, the
        # {Epics#initialize} precedent: a typo that CONSTRUCTS would reach
        # {Approval::Gate::Policies.for} as an unbuildable name.
        def initialize(table:)
          self.class.check!(table)

          # Interned and re-frozen rather than stored as handed over: the caller's
          # Hash is theirs to keep mutating, and this value rides inside a
          # Ractor-shareable {Config}.
          super(table: table.to_h { |stage, policy| [-stage, -policy] }.freeze)
        end

        # Total by construction -- an unconfigured stage runs the default.
        #
        # @param stage [#to_s] an {Epic::Stage} or its name
        # @return [String] the policy name that stage's gates run under
        def policy_for(stage) = table.fetch(stage.to_s, Approval::Gate::Policies::DEFAULT)

        EMPTY = new(table: {}).freeze
        private_constant :EMPTY
      end
    end
  end
end
