# frozen_string_literal: true

# Both matchers accept the same "journal" shapes every reader in the codebase
# already tolerates: a StringIO (read non-destructively via #string, the
# `journal_io.string.each_line` idiom used ~79 times), a raw NDJSON String, or
# any other IO (rewound and #read once). Parsing itself is NOT reimplemented
# here -- Lain::Journal.parse/.records already own "what is a valid record"
# (Hash-or-NDJSON-line in, string-keyed Hash or nil out), so these matchers
# defer to the same code the library uses to read its own journals.
module JournalMatcherSupport
  module_function

  def lines_of(journal)
    text(journal).each_line.map(&:chomp)
  end

  def text(journal)
    return journal.string if journal.respond_to?(:string)
    return journal if journal.is_a?(String)
    return journal.tap(&:rewind).read if journal.respond_to?(:read)

    # Loud failure over a silent to_s coercion: a wrong-shaped argument here is
    # a spec bug, and (say) 42.to_s would "parse" as one invalid NDJSON line
    # instead of pointing at the real mistake.
    raise ArgumentError, "journal must be an IO or String, got #{journal.class}"
  end
end

# The `io.string.each_line.map { JSON.parse(_1) }` idiom (~79 sites), phrased
# as `expect(journal).to be_valid_ndjson` -- every line is one complete,
# independently parseable JSON object. On failure, names the OFFENDING LINE
# verbatim (not just "line 3 failed") and its 1-based position.
RSpec::Matchers.define :be_valid_ndjson do
  match do |journal|
    @lines = JournalMatcherSupport.lines_of(journal)
    @bad_index = @lines.index { |line| Lain::Journal.parse(line).nil? }
    @bad_index.nil?
  end

  failure_message do
    "expected every line to be valid NDJSON (one parseable JSON object per line), " \
      "but line #{@bad_index + 1} of #{@lines.size} did not parse: #{@lines[@bad_index].inspect}"
  end

  failure_message_when_negated do
    "expected at least one line to be invalid NDJSON, but all #{@lines.size} lines parsed cleanly"
  end
end

# `include_journal_record(type, **attrs)` -- true when the journal (StringIO,
# its underlying String, or a raw NDJSON String) holds at least one record of
# `type` whose fields include `attrs`. Foreign/unparseable lines are skipped,
# same as every real reader (Handler::Recorded, Ledger::Index) via
# Lain::Journal.records.
RSpec::Matchers.define :include_journal_record do |type, **attrs|
  match do |journal|
    @lines = JournalMatcherSupport.lines_of(journal)
    @typed = Lain::Journal.records(@lines, type:).to_a
    string_attrs = attrs.transform_keys(&:to_s)
    # find, not any?: the negated failure message must cite the record that
    # actually matched, which need not be the first record of this type.
    @matched = @typed.find { |record| string_attrs.all? { |key, value| record[key] == value } }
    !@matched.nil?
  end

  failure_message do
    if @typed.empty?
      types_seen = @lines.filter_map { |line| Lain::Journal.parse(line)&.fetch("type", nil) }.uniq
      "expected a #{type.inspect} record in the journal, but found none among #{@lines.size} " \
        "line(s) (types seen: #{types_seen.inspect})"
    else
      "expected a #{type.inspect} record matching #{attrs.inspect}, but none of the " \
        "#{@typed.size} record(s) of that type did -- closest: #{@typed.first.inspect}"
    end
  end

  failure_message_when_negated do
    "expected no #{type.inspect} record matching #{attrs.inspect}, but found one: #{@matched.inspect}"
  end
end
