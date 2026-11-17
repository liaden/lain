# frozen_string_literal: true

# Stands in for a daemon connection that answers session.list from the records
# a spec adds, and remembers what it was asked and whether it was hung up on.
class SessionListing
  attr_reader :records, :asked

  # @param records [Array<Lain::LiveSessions::Record>] shared, so a spec may add to it later
  def initialize(records = [])
    @records = records
    @asked = []
    @stopped = false
  end

  # @return [Array<Hash>] the records as session.list sends them
  def call(method)
    @asked << method
    records.map(&:to_h)
  end

  def stop = @stopped = true

  def stopped? = @stopped
end
