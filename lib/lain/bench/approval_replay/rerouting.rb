# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # The line {Report} and {Score} both print for an arm that re-routes the judge's denials.
      module Rerouting
        # @param arm [Arm]
        # @param rows [Enumerable<Row>] that arm's
        # @param indent [String]
        # @return [Array<String>] how many calls the arm took from the judge, and how many prompts it
        #   added over the same arm with the judge's denials applied; none for an arm that re-routes nothing
        def self.lines(arm, rows, indent:)
          return [] if arm.denied.empty?

          moved = rows.count(&:rerouted)
          ["#{indent}re-routed past the judge: #{counted(moved, "call")}, " \
           "#{counted(rows.count(&:extra_prompt), "extra prompt")}"]
        end

        def self.counted(count, noun) = "#{count} #{noun.pluralize(count)}"
        private_class_method :counted
      end
    end
  end
end
