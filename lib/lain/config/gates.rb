# frozen_string_literal: true

module Lain
  class Config
    class Epics
      # The `[epics.gates]` sub-table: which {Approval::Gate::Policy} each epic
      # stage's gates run under (`epic_plan = "deferred"`). BOTH sides of the
      # mapping are closed sets, so both are refused at load rather than
      # discovered at the first overnight gate.
      #
      # The allowed VALUES are not spelled here: {Approval::Gate::Policies.known?}
      # answers, so widening the policy family is one edit in the factory rather
      # than two that can disagree. That reference is resolved at CALL time,
      # which is why it does not invert lain.rb's load order.
      #
      # Absence means interactive everywhere, so {#policy_for} is total and no
      # caller writes a nil guard.
      Gates = Data.define(:table)

      class Gates
        # Reopened for {Epics}'s reason: constants and nested classes inside a
        # `Data.define do ... end` block are scoped to the enclosing module.

        # The sub-table as `config.toml` spells it, which is how every refusal
        # here names it.
        TABLE = "[epics.gates]"

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
        # guard total: storing the Hash as handed deferred a typo'd policy name
        # to an unnamed NoMethodError inside {Config#gate_policy_for} -- no path,
        # no key, and a stack frame away from the mistake.
        def self.coerce(gates) = gates.is_a?(self) ? gates : from(gates)

        # @return [Gates] the value an absent sub-table yields
        def self.empty = EMPTY

        # Shared by {.from}, which names the config file, and by {#initialize},
        # which cannot and passes nil.
        #
        # @raise [Config::Refusal]
        def self.check!(table, path: nil)
          raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)
          # An empty table has nothing to judge, and answering HERE -- before
          # either closed set is read -- is what lets {EMPTY} be built while this
          # file loads (see the note at {Config::EMPTY}). Every non-empty table
          # arrives through {Config.load}, long after both sets exist.
          return if table.empty?

          unknown = table.keys - Epic::STAGES
          # Loud rather than ignored: a silently dropped `reserch = "deferred"`
          # leaves that stage interactive, so an unattended run wedges on a gate
          # nobody is there to answer.
          raise unknown_stages(unknown, path:) unless unknown.empty?

          # A value of the wrong TYPE fails the membership test rather than
          # being coerced first, {Epics.invalid_home}'s posture.
          unnamed = table.values.reject { |policy| Approval::Gate::Policies.known?(policy) }
          raise unknown_policies(unnamed, path:) unless unnamed.empty?
        end

        # The pipeline itself is the correction, rather than a key list: a stage
        # name is only wrong relative to the order it sits in.
        #
        # @return [Config::Refusal]
        def self.unknown_stages(keys, path: nil)
          Refusal.new("has no stages #{keys.map(&:inspect).join(", ")}; " \
                      "the pipeline is #{Epic::STAGES.join(" -> ")}",
                      path:, table: TABLE, key: keys)
        end

        # The known set is read from {Approval::Gate::Policies} at CALL time, so
        # widening the policy family is one edit in the factory.
        #
        # @return [Config::Refusal]
        def self.unknown_policies(policies, path: nil)
          Refusal.new("names unknown gate policies #{policies.map(&:inspect).join(", ")}; " \
                      "known policies: #{Approval::Gate::Policies.names.join(", ")}",
                      path:, table: TABLE, value: policies)
        end

        private_class_method :unknown_stages, :unknown_policies

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
