# frozen_string_literal: true

# One sign-off partition's gate, folded from journaled decisions the way landing and the queue read it.
module GateViewOf
  # @param records [Enumerable<Hash, String>] journal lines or records
  # @param current [String, nil] the artifact's digest now
  # @param epic_slug [String]
  # @param stage [String]
  # @param issue_id [String, nil]
  # @return [Lain::Epic::GateView]
  def gate_view_of(records, current:, epic_slug:, stage:, issue_id: nil)
    partition = Lain::Epic::SignoffQueue::Partition.new(epic_slug:, stage:, issue_id:)
    Lain::Epic::Signoff.from_journal(records).view(partition, current:)
  end
end

RSpec.configure { |config| config.include(GateViewOf) }
