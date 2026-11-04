# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # The children a stop left resumable, each under the label a resume names it by, and the
      # record each stop leaves so a restarted run can hold them again. Fan-out siblings are fibers
      # under one reactor, and nothing here suspends, so no lock is taken.
      class Stops
        RESUMABLE = "It can be resumed from where it stopped: call subagent with %<call>s and " \
                    "iterations set to how many more iterations it may run."

        # The scope a resumed child runs under when its stop kept a lease: unconfined, as the
        # child was, and lending that lease rather than leasing afresh.
        Lending = Data.define(:leases) do
          def lend(_leases) = leases

          def env_over(home) = Session::Unconfined.env_over(home)

          def holds?(path) = Session::Unconfined.holds?(path)

          def reminders = Session::Unconfined.reminders
        end

        # A spawn nobody can resume, since only a model-dispatched call can name a label.
        module None
          def self.keeping(_stopped, _keep = nil) = ->(_head, _reason) { "" }
        end

        # @param label [String] what the parent asked to resume
        # @param held [Array<String>] the labels it could have named
        # @return [String] why the resume was refused
        def self.unknown(label, held)
          known = held.empty? ? "none is held" : "these are: #{held.map(&:inspect).join(", ")}"
          "no stopped child is labelled #{label.inspect}; #{known}"
        end

        # The stops a run's record holds that nothing resumed since. A resume's spawn names the
        # stop it continued as `resumed_from`, which is what retires it.
        #
        # @param records [Enumerable<String, Hash>] journal lines, oldest first
        # @return [Array<Telemetry::ChildStopped>]
        def self.from_journal(records)
          resumed = []
          stops = []
          Journal.records(records).each { |record| fold(record, resumed, stops) }
          stops.reject { |stop| resumed.include?(stop.spawn) }
        end

        def self.fold(record, resumed, stops)
          case record["type"]
          when "message" then resumed << record.dig("payload", "resumed_from") if record["kind"].to_s == "spawn"
          when "child_stopped" then stops << Telemetry.read(record)
          end
        end
        private_class_method :fold

        # @param role [String, nil] the role a {Choice} offers this spawner as, which a resume names
        # @param journal [#<<] where each stop's {Telemetry::ChildStopped} lands
        # @param lasting [Boolean] whether a later run can resume this spawner's stops, which only
        #   the run's own spawner can: a nested one goes with the child it lives in
        def initialize(role: nil, journal: Channel::Null.instance, lasting: true)
          @role = role
          @journal = journal
          @lasting = lasting
          @held = {}
        end

        # @param stopped [Stopped] the child, its head not yet known
        # @param keep [#call] keeps the child's lease live, answering it, or nil when it has none
        # @return [#call] `(head, reason)`: keeps the child at that head, records why it stopped,
        #   and answers the sentence that tells the parent how to resume it
        def keeping(stopped, keep)
          lambda do |head, reason|
            held = keep.call(lasting: @lasting)
            label = hold(held ? stopped.with(head:, lease: -> { Lending.new(leases: held) }) : stopped.with(head:))
            @journal << record(stopped, label, head, held, reason)
            resuming(label)
          end
        end

        # A restored stop is held under the chain it stopped under, and offered only to that chain.
        #
        # @param label [String] what the parent asked to resume
        # @param parent [String, nil] the asking chain's identity
        # @yieldparam held [Array<String>] the labels offered, when `label` is not one
        def fetch(label, parent: nil)
          offered = @held.select { |_, stopped| stopped.parent == parent }
          offered.fetch(label) { yield offered.keys }
        end

        def take(label) = @held.delete(label)

        # Holds a taken stop again, for a resume that could not start.
        #
        # @param stopped [Stopped] as {#take} answered it
        def give_back(stopped) = @held[stopped.label] = stopped

        # Holds the restored stops of this spawner's own role.
        #
        # @param restored [Array<Telemetry::ChildStopped>]
        # @yieldparam stop [Telemetry::ChildStopped]
        # @yieldreturn [Stopped] the child, built by the spawner that resumes it
        # @return [self]
        def restore(restored)
          restored.select { |stop| stop.role == @role }.each { |stop| hold(yield(stop)) }
          self
        end

        private

        def resuming(label)
          format(RESUMABLE, call: [("role: #{@role.inspect}" if @role), "resume: #{label.inspect}"].compact.join(", "))
        end

        # A second stop under one label takes a numbered one, so neither child shadows the other.
        def hold(stopped)
          label = (1..).lazy.map { |n| n == 1 ? stopped.label : "#{stopped.label}-#{n}" }.find { !@held.key?(_1) }
          @held[label] = stopped.with(label:)
          label
        end

        def record(stopped, label, head, held, reason)
          Telemetry::ChildStopped.new(spawn: stopped.spawn, label:, role: @role, head:, reason:, task: stopped.prompt,
                                      lease_path: held&.path || kept_dir(stopped.scope),
                                      ceiling: stopped.builder.budget.iterations, snapshot: held&.snapshot,
                                      parent: stopped.parent, kept: !kept_dir(stopped.scope).nil?)
        end

        def kept_dir(scope) = scope.respond_to?(:root) ? scope.root : nil
      end
    end
  end
end
