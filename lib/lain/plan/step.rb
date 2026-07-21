# frozen_string_literal: true

module Lain
  module Plan
    SIZES = %w[S M L].freeze
    STATUSES = %w[pending active done failed].freeze

    # The characters each field reserves for the plan-markdown grammar (see
    # Document): an id is wrapped in `backticks`, a criteria_digest in `{braces}`,
    # and every step is one line -- so an id may hold no backtick or line break, a
    # criteria_digest no closing brace or line break. A title is free text at the
    # tail of the line, so it may hold no line break, no leading or trailing
    # whitespace (the parser trims), and may not END in a ` {...}` group (that
    # tail is the criteria-digest slot). A value that breaks these is refused at
    # construction, so the markdown round-trip is total -- same digest OR a loud
    # rejection naming the offending value, never a silent mismatch.
    ID_RESERVED = /[`\r\n]/
    CRITERIA_RESERVED = /[}\r\n]/
    TITLE_BRACE_SUFFIX = /\s\{[^}]*\}\z/
    TITLE_RULES = [
      ["a step title cannot be empty", ->(title) { title == "" }],
      ["a step title is one line and cannot contain a line break", ->(title) { title.match?(/[\r\n]/) }],
      ["a step title cannot have leading or trailing whitespace (the markdown grammar trims it)",
       ->(title) { title != title.strip }],
      ["a step title cannot end in a ` {...}` group (it collides with the criteria-digest grammar)",
       ->(title) { title.match?(TITLE_BRACE_SUFFIX) }]
    ].freeze

    class MalformedStep < Error; end

    # One planned step. `size` is the S/M/L effort class; `status` is one of
    # STATUSES; `criteria_digest` optionally references a {Gherkin::Criteria}
    # that attests the step is done. Interned Strings and a nil-or-interned
    # digest, so the value is Ractor-shareable. Fields that would break the
    # markdown grammar are refused loudly here (MalformedStep), which is what
    # makes .parse_markdown a total round-trip.
    Step = Data.define(:id, :title, :size, :status, :criteria_digest) do
      def initialize(id:, title:, size:, status: "pending", criteria_digest: nil)
        super(id: clean_id(id), title: clean_title(title),
              size: one_of(size, SIZES, "size"), status: one_of(status, STATUSES, "status"),
              criteria_digest: clean_criteria(criteria_digest))
      end

      # A new step at `status`, everything else preserved. The Document swaps its
      # handle; nothing mutates.
      def with_status(status)
        self.class.new(id:, title:, size:, status:, criteria_digest:)
      end

      # Plain-hash wire form for {Canonical}; String keys, sorted downstream. The
      # criteria_digest key is always present (nil when unset) so the shape is
      # stable across steps.
      def canonical
        { "id" => id, "title" => title, "size" => size, "status" => status, "criteria_digest" => criteria_digest }
      end

      private

      def clean_id(id)
        id = id.to_s
        reserved!(id, "step id", ID_RESERVED, "the `id` backtick delimiters")
        -id
      end

      def clean_criteria(criteria_digest)
        criteria_digest = criteria_digest&.to_s
        reserved!(criteria_digest, "criteria_digest", CRITERIA_RESERVED, "the {criteria} braces") if criteria_digest
        criteria_digest.nil? ? nil : -criteria_digest
      end

      def clean_title(title)
        title = title.to_s
        broken = TITLE_RULES.find { |_message, predicate| predicate.call(title) }
        raise MalformedStep, "#{broken.first} (got #{title.inspect})" if broken

        -title
      end

      def reserved!(value, field, pattern, grammar)
        return unless value.match?(pattern)

        raise MalformedStep, "#{field} #{value.inspect} contains a character reserved for #{grammar}"
      end

      # Intern `value` if it is one of `allowed`, else fail loudly naming both.
      def one_of(value, allowed, kind)
        value = value.to_s
        unless allowed.include?(value)
          raise ArgumentError, "unknown #{kind} #{value.inspect} (expected #{allowed.join("/")})"
        end

        -value
      end
    end
  end
end
