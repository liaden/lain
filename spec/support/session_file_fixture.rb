# frozen_string_literal: true

# A finished session as a resume reads it: header, one record per turn, then the close that names the head.
module SessionFileFixture
  def write_session_file(path, header:, timeline:)
    records = [header, *timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) },
               Lain::Telemetry::SessionClosed.new(head: timeline.head_digest, reason: :exit).to_journal]
    File.write(path, records.map { |record| "#{JSON.generate(record)}\n" }.join)
    path
  end
end

RSpec.configure { |config| config.include(SessionFileFixture) }
