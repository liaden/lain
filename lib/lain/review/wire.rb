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
