# frozen_string_literal: true

# Reads a journal the way a real reader does, through Lain::Journal.records, so a torn
# line is skipped rather than raising JSON::ParserError out of the spec.
module JournalRecords
  def journal_records(journal, type = nil)
    Lain::Journal.records(ndjson_lines(journal), type:).to_a
  end

  private

  def ndjson_lines(journal)
    case journal
    when Array, Enumerator then journal
    when Pathname then File.exist?(journal) ? File.readlines(journal) : []
    when String then string_lines(journal)
    else JournalMatcherSupport.lines_of(journal)
    end
  end

  # A String is NDJSON when it opens a record and a path otherwise; a path nothing wrote yet is no records.
  def string_lines(text)
    return text.lines if text.lstrip.start_with?("{")

    File.exist?(text) ? File.readlines(text) : []
  end
end

RSpec.configure { |config| config.include(JournalRecords) }
