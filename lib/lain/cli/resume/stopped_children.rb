# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # The children a resumed chain left stopped, split into the ones the resumed chat can resume
      # and the ones it cannot, each named in a notice for the human, who is who tells the parent.
      #
      # A stop is resumable from what it left on disk: a checkout's snapshot, or the directory it
      # was kept in, a researcher's own or a plan scope's spike. A stop that leased no checkout has
      # nothing to put back, and resumes fresh.
      class StoppedChildren
        # @param stops [Array<Telemetry::ChildStopped>] every stop the chain never resumed
        # @param chat [String, nil] the resumed chat's own chain identity
        def initialize(stops, chat:)
          @chat = chat
          resumable, @unresumable = stops.map { |stop| [stop, why_not(stop)] }.partition { |_, why| why.nil? }
          @resumable = resumable.map(&:first)
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
            "#{@unresumable.map { |stop, why| "#{named(stop)}, as #{why}" }.join("; ")}"
        end

        def why_not(stop)
          if stop.parent != @chat then "the child it stopped under has ended"
          elsif stop.kept then kept_gone(stop.lease_path)
          elsif stop.lease_path && stop.snapshot.nil? then "it kept no snapshot"
          end
        end

        def kept_gone(dir)
          Tools::Subagent::Kept.gone(dir) unless dir && File.directory?(dir)
        end

        def counted(stops) = "#{stops.size} stopped #{"child".pluralize(stops.size)}"

        def named(stop) = stop.role ? "#{stop.label} (#{stop.role})" : stop.label
      end
    end
  end
end
