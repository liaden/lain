# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # The children a resumed chain left stopped, split into the ones the resumed chat can resume
      # and the ones it cannot, each named in a notice for the human, who is who tells the parent.
      class StoppedChildren
        # @param stops [Array<Telemetry::ChildStopped>] every stop the chain never resumed
        # @param chat [String, nil] the resumed chat's own chain identity
        def initialize(stops, chat:)
          @resumable, @unresumable = stops.partition { |stop| !stop.kept && stop.parent == chat }
        end

        # @return [Array<Telemetry::ChildStopped>] the stops the chat's own spawners can take up
        attr_reader :resumable

        # @return [Array<String>]
        def notices = [resumable_notice, unresumable_notice].compact

        private

        def resumable_notice
          return if @resumable.empty?

          "#{counted(@resumable)} can be resumed: #{@resumable.map { |stop| named(stop) }.join(", ")}"
        end

        def unresumable_notice
          return if @unresumable.empty?

          "#{counted(@unresumable)} cannot be resumed: " \
            "#{@unresumable.map { |stop| "#{named(stop)}, as #{why_not(stop)}" }.join("; ")}"
        end

        def why_not(stop)
          stop.kept ? "its directory was confined by the run that leased it" : "the child it stopped under has ended"
        end

        def counted(stops) = "#{stops.size} stopped #{"child".pluralize(stops.size)}"

        def named(stop) = stop.role ? "#{stop.label} (#{stop.role})" : stop.label
      end
    end
  end
end
