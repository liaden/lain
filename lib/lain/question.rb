# frozen_string_literal: true

module Lain
  Question = Data.define(:id, :body, :options, :arity)

  # One question in a set: a stable id, a markdown body, a closed option list,
  # and the arity that says how many of those options may be chosen.
  #
  # The body is MARKDOWN and that is the point -- a table, a fenced diff, or a
  # mermaid block is often what makes a question answerable -- so it is stored
  # verbatim and never rewritten. Verbatim includes a CR: a CRLF body is kept as
  # written, so a line splitter downstream sees the bytes the author sent. An
  # empty option list is not a degenerate case: it IS the free-text question,
  # and {#free_text?} names it.
  #
  # Arity is first-class DATA rather than a derived detail, because the answer
  # document has to be readable both ways: a renderer needs to know which mark
  # to draw, and a parser (and the editor keymap above it) has to recover "one
  # of these" from "any of these" out of the text alone.
  #
  # Reopened rather than folded into a `Data.define` block: a constant or a
  # `class` keyword written inside that block binds to the enclosing module --
  # here `Lain` -- and not to the Data class, however natural
  # `Question::MAX_BODY` looks from the call site (see {Request::SYSTEM_PREFIX}
  # for the same trap). Reopening puts the constants, the guard, and the nested
  # {Option} where they read, and where every method below finds them by
  # ordinary lexical lookup.
  class Question
    SINGLE = "single"
    MULTI = "multi"
    # Closed, and closed in both directions: the renderer draws one mark per
    # arity and the parser reads one arity per mark, so a third value would be a
    # question nothing downstream could draw or read back.
    ARITIES = [SINGLE, MULTI].freeze

    # Every free field is REFUSED above its maximum, never truncated.
    # {Adjudicator}'s evidence clamps because it is one NDJSON line; a question
    # body is markdown a human edits, and a clamp can land mid-fence -- which is
    # the one shape {Fence} exists to refuse, and truncation would introduce it
    # here, silently. Clamping belongs at a journal render, where the bytes are
    # displayed rather than answered.
    #
    # 64KiB is far past any question a human reads in one buffer. An id is a
    # join key and a label is one line beside a checkbox, so both are bounded
    # far tighter -- and {Set::MAX_SET} bounds the serialized whole, which is
    # the quantity that actually reaches the request.
    MAX_BODY = 64 * 1024
    MAX_ID = 256
    MAX_LABEL = 1024

    # An id is rendered inline into the answer document, inside a code span and
    # on one line, so neither the delimiter nor a line break may appear in one.
    # These are the same three characters {Epic::ID_RESERVED} reserves, and the
    # duplication is deliberate: the shared markdown-identifier object that both
    # files should depend on does not exist yet, so each states the rule and
    # this comment is where the agreement between them is recorded.
    #
    # `fetch`ed on purpose, as {Epic::Issue#reserved!} does: growing
    # ID_RESERVED without saying which grammar the new character belongs to
    # fails loudly instead of mislabelling it.
    ID_RESERVED = /[`\r\n\u{200B}-\u{200D}\u{2060}\u{FEFF}]/
    ID_GRAMMARS = { "`" => "the code span the document renders an id inside",
                    "\r" => "the one-line question heading",
                    "\n" => "the one-line question heading",
                    "​" => "an id a human can see",
                    "‌" => "an id a human can see",
                    "‍" => "an id a human can see",
                    "⁠" => "an id a human can see",
                    "﻿" => "an id a human can see" }.freeze
    # A code span drops ONE leading and ONE trailing space from its content, so
    # a padded id renders as text that reads back as a DIFFERENT id -- and
    # {Rules.distinct!} would never see the collision, because it compares the
    # bytes as given rather than as rendered.
    ID_PADDED = /\A[[:space:]]|[[:space:]]\z/
    LINE_BREAK = /[\r\n]/

    # CommonMark's fenced-code-block rule, and exactly as much of it as a
    # balance check needs.
    #
    # NOT "count the ``` lines". A fence opens on a run of three or MORE
    # backticks or tildes and closes only on a run of the SAME character at
    # least as long, carrying no info string -- so a ```` fence legally holds a
    # ``` line, and marker-counting would refuse the very bodies this chunk
    # exists to carry. A false refusal is worse than the bug: a fenced diff and
    # a mermaid block are the point.
    module Fence
      # Which fence is open and where it was opened, so a refusal can name the
      # line whoever wrote the body has to go fix.
      Opened = Data.define(:marker, :line)

      # Up to three leading spaces; a fourth would make it an indented code
      # block rather than a fence.
      MARKER = /\A {0,3}(?<marker>`{3,}|~{3,})(?<info>.*)\z/
      BLANK = /\A[[:space:]]*\z/

      module_function

      # The fence still open at the end of +text+, or nil when every fence
      # closes.
      def unclosed(text)
        text.lines.each_with_index.inject(nil) do |opened, (line, index)|
          fence = MARKER.match(line.chomp)
          fence.nil? ? opened : step(opened, fence, index + 1)
        end
      end

      def step(opened, fence, line)
        return opener(fence, line) if opened.nil?

        closes?(opened, fence) ? nil : opened
      end

      # A backtick fence's info string may hold no backtick. That one rule is
      # what keeps a one-line code span (```x```) from reading as an opener.
      def opener(fence, line)
        marker = fence[:marker]
        return nil if marker.start_with?("`") && fence[:info].include?("`")

        Opened.new(marker:, line:)
      end

      def closes?(opened, fence)
        marker = fence[:marker]
        marker[0] == opened.marker[0] && marker.length >= opened.marker.length && fence[:info].match?(BLANK)
      end

      private_class_method :step, :opener, :closes?
    end

    # The construction rules this unit's values share, in one place because
    # {Option}, {Set}, and the answer values apply the same ones to different
    # fields. Ids, labels, and arities go through {.normalized}, i.e. through
    # Canonical: Canonical is what will eventually hash them, so a value that
    # constructs but cannot be content-addressed is refused here rather than
    # raising later out of a digest -- and the interning it does on the way is
    # what keeps these values `Ractor.shareable?` (a bare `Symbol#to_s` or an
    # interpolation hands back a MUTABLE String).
    module Rules
      module_function

      # Canonical reads a Symbol key and a String key as the SAME message, so a
      # body handed over as written and the same body read back off an event
      # (where `Canonical.normalize` has made every key a String) build the same
      # value here. What Canonical does NOT do is resolve a Hash holding both --
      # it raises, and so does {.ambiguous!}, because silently reading one of
      # them would build a value that cannot be content-addressed a moment
      # later. `Hash#to_h` with a block was the first attempt and is exactly the
      # wrong tool: it takes the last writer, with no signal.
      def string_keyed(body, subject)
        raise ArgumentError, "#{subject} must be a Hash (got #{body.class})" unless body.is_a?(Hash)

        body.each_with_object({}) do |(key, value), keyed|
          string_key = key.to_s
          ambiguous!(string_key, subject) if keyed.key?(string_key)
          keyed[string_key] = value
        end
      end

      def ambiguous!(key, subject)
        raise ArgumentError, "#{subject} holds #{key.inspect} as both a String and a Symbol key -- the same " \
                             "ambiguity Canonical.normalize refuses, and reading either one would build a " \
                             "value that cannot be content-addressed"
      end

      # Named, because a bare `fetch` reports "key not found" and says neither
      # what was being built nor what it did hold -- which tells an operator
      # holding a five-question set from a model nothing at all.
      def required(fields, key, subject)
        fields.fetch(key) do
          raise ArgumentError, "#{subject} must name #{key.inspect}, and holds #{fields.keys.inspect}"
        end
      end

      # `to_s` on an Array or a Hash is `inspect` output, whose format moves
      # between Ruby versions -- so a body coerced that way would
      # content-address differently on a different runtime, which is the one
      # thing Canonical exists to prevent. Symbol is accepted because
      # `arity: :multi` is an ordinary caller spelling; everything else is
      # refused by name.
      def textual(value, field)
        raise ArgumentError, "#{field} cannot be nil" if value.nil?
        return value.to_s if value.is_a?(String) || value.is_a?(Symbol)

        raise ArgumentError, "#{field} must be a String or a Symbol (got #{value.class}) -- anything else " \
                             "reaches Canonical as #inspect output, whose format moves between Ruby versions"
      end

      def normalized(value, field)
        Canonical.normalize(textual(value, field))
      rescue Canonical::UnsupportedType => e
        raise ArgumentError, "#{field} cannot be content-addressed: #{e.message}"
      end

      # Canonical's UTF-8 rule, restated HERE and only here, for one reason:
      # `Canonical.normalize` interns what it returns (`-@`), and interning a
      # 64KiB body -- unique by construction, never compared as a Hash key --
      # both pays a full-string hash on every construct and pins those bytes in
      # the process-wide fstring table for good. Ids, labels, and arities still
      # go through Canonical, where interning is exactly right. The rule itself
      # must not drift, and does not: a body refused here is a body Canonical
      # would refuse, and there is a spec for it.
      def prose(value, field)
        text = textual(value, field)
        encoded = text.encoding == Encoding::UTF_8 ? text : text.encode(Encoding::UTF_8)
        raise ArgumentError, "#{field} is not valid UTF-8" unless encoded.valid_encoding?

        encoded.dup.freeze
      rescue EncodingError => e
        raise ArgumentError, "#{field} is not convertible to UTF-8: #{e.message}"
      end

      def identifier(value, field, maximum)
        id = bounded(normalized(value, field), field, maximum)
        reserved!(id, field)
        padded!(id, field)
        id
      end

      def reserved!(id, field)
        offender = id[ID_RESERVED]
        return if offender.nil?

        raise ArgumentError, "#{field} #{id.inspect} contains #{offender.inspect}, a character reserved for " \
                             "#{ID_GRAMMARS.fetch(offender)}"
      end

      def padded!(id, field)
        return unless id.match?(ID_PADDED)

        raise ArgumentError, "#{field} #{id.inspect} is padded with whitespace -- refused rather than trimmed, " \
                             "because a code span drops one leading and one trailing space and the id would " \
                             "read back as a different one"
      end

      def one_line(value, field, maximum)
        line = bounded(normalized(value, field), field, maximum)
        raise ArgumentError, "#{field} #{line.inspect} is one line and cannot hold a line break" if
          line.match?(LINE_BREAK)

        line
      end

      def bounded(value, field, maximum)
        return value if value.bytesize <= maximum

        raise ArgumentError, "#{field} is #{value.bytesize} bytes, beyond the #{maximum}-byte maximum -- " \
                             "refused rather than truncated"
      end

      def fenced!(body, field)
        opened = Fence.unclosed(body)
        return body if opened.nil?

        raise ArgumentError, "#{field} opens a #{opened.marker.inspect} fence at line #{opened.line} and never " \
                             "closes it -- the document a human answers in would render every option below " \
                             "that line as code"
      end

      # Asserted rather than ducked, for {Epic::Issue#clean_edges}' reason:
      # `Array()` would read a lone option Hash as no options at all.
      def array!(value, subject)
        return value if value.is_a?(Array)

        raise ArgumentError, "#{subject} must be an Array (got #{value.inspect})"
      end

      # ONE member policy for both lists in this unit: a member arrives BUILT.
      # `from_body` is the documented way in from raw data, and it is where the
      # per-field messages live -- so accepting a raw Hash here too would mean
      # two doors into one value with two error vocabularies, which is what
      # {Question} and {Set} used to disagree about.
      def members!(list, klass, subject)
        members = array!(list, subject)
        stranger = members.find { |member| !member.is_a?(klass) }
        return members if stranger.nil?

        raise ArgumentError, "#{subject} must hold #{klass} values, got a #{stranger.class} -- build it with " \
                             "#{klass}.from_body first"
      end

      # The join-key rule, shared because every downstream reader -- the answer
      # document's parser, the answer set, the editor keymap above it -- joins
      # an answer to what it answers BY ID. A duplicate is not a cosmetic
      # defect: it is a join that silently picks one.
      def distinct!(ids, subject)
        duplicated = ids.tally.find { |_id, count| count > 1 }
        return if duplicated.nil?

        raise ArgumentError, "#{subject} must have distinct ids, and #{duplicated.first.inspect} is used " \
                             "#{duplicated.last} times"
      end
    end

    # Validated on a throwaway carrier that is checked and discarded, so the
    # frozen value never carries ActiveModel's ivars (see {Lain::Guard}). Only
    # the field-shaped rules live here; "these two options share an id" is a
    # rule about a LIST and reads better as the raise it is.
    class Fields < Guard
      attribute :id
      attribute :body
      attribute :arity
      validates :id, presence: { message: "must name the question, got blank" }
      validates :body, presence: { message: "must be the markdown a human answers, got blank" }
      validates :arity, inclusion: { in: ARITIES, message: "must be one of #{ARITIES.join("/")}, got %<value>s" }
    end

    Option = Data.define(:id, :label)

    # One choice on one question: the id an answer cites, and the one-line label
    # a human reads beside a checkbox.
    class Option
      # The label occupies a whole line of the answer document, so a line break
      # in it would silently become a second, unowned line of grammar.
      class Fields < Guard
        attribute :id
        attribute :label
        validates :id, presence: { message: "must name the option, got blank" }
        validates :label, presence: { message: "must be the text a human reads, got blank" }
      end

      def self.from_body(body)
        fields = Rules.string_keyed(body, "an option body")
        new(id: Rules.required(fields, "id", "an option body"),
            label: Rules.required(fields, "label", "an option body"))
      end

      def initialize(id:, label:)
        fields = { id: Rules.identifier(id, "an option id", MAX_ID),
                   label: Rules.one_line(label, "an option label", MAX_LABEL) }
        Fields.check!(**fields)
        super(**fields)
      end

      def to_body = { "id" => id, "label" => label }
    end

    # The way in from raw data -- a model's tool input, or an event body read
    # back off the Timeline. Both defaults are the permissive reading of an
    # under-specified body: no options is free text, and one choice is what a
    # lone list of options means to a reader who was told nothing else. Unknown
    # keys are ignored on purpose, so a richer event body still rebuilds the
    # question; a wrong-typed or ambiguous known key is not.
    def self.from_body(body)
      fields = Rules.string_keyed(body, "a question body")
      new(id: Rules.required(fields, "id", "a question body"),
          body: Rules.required(fields, "body", "a question body"),
          arity: fields.fetch("arity", SINGLE), options: options_in(fields))
    end

    def self.options_in(fields)
      Rules.array!(fields.fetch("options", []), "a question's options").map { |option| Option.from_body(option) }
    end
    private_class_method :options_in

    def initialize(id:, body:, options: [], arity: SINGLE)
      fields = { id: Rules.identifier(id, "a question id", MAX_ID), body: markdown(body),
                 arity: Rules.normalized(arity, "a question arity") }
      Fields.check!(**fields)
      super(**fields, options: choices(options))
    end

    # A question with no options is answered in prose. That is a real arm of the
    # design and not a missing option list: some questions have no closed set,
    # and the arity above governs the options it does not have.
    def free_text? = options.empty?
    def single? = arity == SINGLE
    def multi? = arity == MULTI

    # Plain wire form: String keys, every field always present so the shape is
    # stable across questions. A fresh COPY at every level -- the caller that
    # emits this as an event body adds its own keys beside ours (the one-line
    # summary the inbox reads), and mutating what it is handed must not reach
    # this value. The String leaves are the frozen ones this question holds.
    def to_body
      { "id" => id, "body" => body, "arity" => arity, "options" => options.map(&:to_body) }
    end

    private

    def markdown(body)
      text = Rules.bounded(Rules.prose(body, "a question body"), "a question body", MAX_BODY)
      Rules.fenced!(text, "a question body")
    end

    # Option order is meaning -- it is the order a human reads them in -- so the
    # list is preserved rather than sorted, unlike an edge set. Copied rather
    # than frozen in place, as {Epic::Issue#clean_edges} does: the caller keeps
    # ownership of the Array it handed over, and our member stays immutable.
    def choices(options)
      built = Rules.members!(options, Option, "a question's options")
      Rules.distinct!(built.map(&:id), "a question's options")
      built.dup.freeze
    end
  end
end

require_relative "question/set"
