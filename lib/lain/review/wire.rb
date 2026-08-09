# frozen_string_literal: true

module Lain
  module Review
    # The edge between a value as it ARRIVES and a value as the journal stores
    # it: how it is normalized on the way in, and what a guard says when it
    # cannot be used. One module because it is one boundary -- every record here
    # crosses it, and a normalization rule and its refusal message are read
    # together or not at all.
    #
    # Every record interns BEFORE its guard runs, the epic tier's order and for
    # its reason: a ref object whose `#to_s` is blank passes a presence test on
    # the raw object and then names a revision nothing can resolve. The two
    # normalizations below differ in one respect that is not obvious from a
    # field's name, which is why they are named here rather than spelled out
    # inline in four records.
    #
    # Both leave nil ALONE. Coercing it to `""` would make every refusal message
    # describe a blank String the caller never passed, and the guards refuse nil
    # on their own terms anyway -- `presence:` and `inclusion:` both judge it --
    # so nothing is gained by erasing which one arrived.
    module Wire
      # A key, a ref, a name, a closed-set member: interned, and stripped of the
      # whitespace a wire adds around a token it never meant to carry. Without
      # the strip a `" reviewed "` off the wire misses its closed set and is
      # refused as an unknown spelling rather than read as the value it is.
      #
      # @param value [Object, nil]
      # @return [String, nil]
      def self.token(value) = value && -value.to_s.strip

      # A line of a document, or a human's own words: interned and NEVER
      # stripped. The leading indentation of an anchored line is precisely the
      # evidence a drift check compares, so trimming it would make two different
      # lines read as the same one.
      #
      # @param value [Object, nil]
      # @return [String, nil]
      def self.text(value) = value && -value.to_s

      # The named escapes git writes inside a quoted path; everything else it
      # spells in OCTAL, which is why `String#undump` cannot do this job.
      ESCAPES = { "a" => "\a", "b" => "\b", "f" => "\f", "n" => "\n",
                  "r" => "\r", "t" => "\t", "v" => "\v" }.freeze

      # GIT's C-quoting, undone -- and the emphasis is a contract, not colour.
      # This decodes exactly one wire format, and a source that does not speak it
      # must NOT route paths through here: a GitHub PR source (T10) receives
      # paths as JSON strings that arrive already decoded, and passing one
      # through this would silently rewrite any name containing a quote. Should a
      # second source ever need a different decoding it gets its own function,
      # never a branch inside this one -- per-source decoders accreting in one
      # place is the same shape that let the numstat and the diff disagree.
      #
      # It lives here rather than beside either caller because NEITHER can own
      # it: putting it with the git invocation would make {Source::Parser}
      # depend on {Source::LocalBranch}, inverting the port's premise that
      # everything downstream reads the port's messages and does not know which
      # source answered them.
      #
      # The one crossing in this module that is not a
      # record's: {Source::LocalBranch} reads a path out of a numstat and
      # {Source::Parser} reads one out of a diff header, and the whole reason
      # this lives in ONE place is that those two answers are JOINED to each
      # other. They were not, and an ordinary `we"ird.rb` took a whole changeset
      # down with an `Unattributed` refusal because each side spelled it
      # differently.
      #
      # `core.quotePath=false` -- which {Source::LocalBranch::CONFIG_PINS} sets --
      # governs NON-ASCII paths only. A name carrying a quote, a backslash, a tab
      # or a newline is quoted whatever that setting says, so this is not a
      # fallback for an exotic configuration; it is the ordinary path for those
      # names.
      #
      # A gsub over quoted RUNS rather than a test on the whole field, because
      # git quotes a rename's two sides INDEPENDENTLY and leaves the ` => `
      # between them bare (`"d1/a\"b.rb" => "d2/a\"b.rb"`) -- a whole-field test
      # sees an unquoted composite and decodes neither side. A bare `"` cannot
      # occur outside a quoted run, since any name containing one is quoted, so
      # the runs cannot be misread.
      #
      # Answers BYTES on purpose: an octal escape decodes to the file's own byte,
      # and what to do with a byte sequence that is not valid UTF-8 belongs to
      # the caller -- both of ours hand it straight to a scrub, because a path is
      # journalled as JSON.
      #
      # @param value [Object, nil]
      # @return [String, nil] ASCII-8BIT
      def self.unquote(value)
        value && value.to_s.b.gsub(/"(?:[^"\\]|\\.)*"/m) { |run| unescape(run[1..-2]) }
      end

      # @param body [String] one quoted run with its delimiters already removed
      # @return [String]
      def self.unescape(body)
        body.gsub(/\\(?:([0-7]{3})|(.))/m) do
          octal = Regexp.last_match(1)
          octal ? octal.to_i(8).chr : ESCAPES.fetch(Regexp.last_match(2), Regexp.last_match(2))
        end
      end
      private_class_method :unescape

      # A guard message that reports the value it JUDGED, in `inspect` form.
      #
      # ActiveModel's `%<value>s` renders nil and `""` identically -- as nothing
      # at all, leaving a message ending in a bare "got " -- and a hand-written
      # "got nil" is simply false whenever the caller passed something else.
      # Both send a reader looking for an argument they did not pass. A Proc
      # message is called with the offending value, so `inspect` can tell nil
      # from `""` from `"  "`.
      #
      # @param claim [String] what the field must be, as the message's first half
      # @return [Proc] an ActiveModel message, called with the value it refused
      def self.refusal(claim) = ->(_record, error) { "#{claim}, got #{error[:value].inspect}" }
    end
  end
end
