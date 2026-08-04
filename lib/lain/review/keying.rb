# frozen_string_literal: true

module Lain
  module Review
    # How the review tier turns a list of parts into an address, and the two
    # properties that make one safe to journal.
    #
    # It exists because those properties were a COMMENT before they were an
    # object. A review-panel mutation pass deleted the framing below and built
    # two changesets that then addressed identically -- so the claim was one
    # edit from being false, in a digest that is written to the experiment
    # record and joined on a year later. A property nothing defends is not a
    # property; `spec/lain/review/keying_spec.rb` is where these two are
    # falsifiable on their own, without a changeset in the way.
    #
    # == Why {Hunk} does NOT route through here
    #
    # {Hunk#key} does the same two things and is deliberately left alone.
    # Its parts are framed SELECTIVELY (the path is, the body is not), so
    # rewriting it in these terms would change the bytes it hashes -- and a
    # hunk key is the durable identity a mark is stored under, so every mark in
    # every journal would stop matching its hunk. The duplication is the price
    # of not migrating those keys; this file's doc is where that is said out
    # loud rather than rediscovered.
    module Keying
      # Length-framed, and this is the property that was undefended.
      #
      # Without the count, `["ab", "c"]` and `["a", "bc"]` concatenate to the
      # same bytes and address identically -- and those are not contrived
      # inputs here: the parts of a changeset address are a base revision
      # followed by file paths, and a byte moving across that boundary is
      # exactly a shorter base ref beside a longer path.
      #
      # The COUNT is the safety and the trailing separator is legibility, and
      # the two are defended by different things -- which is the distinction an
      # earlier version of this comment got wrong.
      #
      # No collision argument rests on the separator: `<len>\n<bytes>` is
      # already uniquely decodable (read digits to the first `\n`, then take
      # exactly that many bytes), so dropping it cannot make two part lists
      # agree. A mutation pass removed it and nothing went red, and that was
      # correct as far as the COLLISION properties go.
      #
      # It was not therefore inert. It changes every digest this module
      # produces while leaving `review-changeset-v1` -- the string that exists
      # to be bumped when the layout changes -- untouched, which is a silent
      # migration waiting to happen. That is what the golden vector in
      # `keying_spec.rb` is for: the LAYOUT is pinned by one recorded address
      # per scheme, so this line cannot move without a red test, and the only
      # way to make that test pass is to bump the scheme deliberately.
      #
      # @param part [Object] anything answering `#to_s`
      # @return [String] ASCII-8BIT, `<bytesize>\n<bytes>\n`
      def self.frame(part)
        bytes = part.to_s.b
        "#{bytes.bytesize}\n#{bytes}\n"
      end

      # The scheme is HASHED as well as prefixed, and it is FRAMED like every
      # other part -- which is a correction, not a flourish.
      #
      # Hashing it stops a digest under one scheme being forgeable into another
      # by a first part that mimics the scheme line. Framing it is what makes
      # that true rather than nearly true: written as a bare `"#{scheme}\n"` the
      # scheme was the one unframed field in an otherwise uniquely decodable
      # blob, and a review panel found 47 cross-scheme hex collisions against
      # exactly that shape -- `digest("1", ["2", ""])` and `digest("1\n1",
      # ["0\n"])` both hashing to `39caa94c…`. Framed, the whole blob is
      # uniquely decodable and no such pair exists.
      #
      # {Hunk#key} still carries the unframed shape and cannot be changed (see
      # this module's own doc). It is not exploitable there: its three schemes
      # contain no newline and differ in their leading bytes, and a hunk key is
      # compared as the WHOLE `<scheme>:<hex>` address, which differs by its
      # prefix even where a hex could be made to agree.
      #
      # `.b` on every fragment before the join: two parts of one changeset can
      # carry different encodings (a path scrubbed to UTF-8 beside a ref that is
      # ASCII), and joining those raises instead of hashing.
      #
      # @param scheme [String] the address's namespace, versioned by its owner
      # @param parts [Array<Object>] in a caller-determined, stable order
      # @return [String] `<scheme>:<hex>`, interned
      def self.digest(scheme, parts)
        -"#{scheme}:#{Ext.blake3_hex([scheme, *parts].map { |part| frame(part) }.map(&:b).join)}"
      end
    end
  end
end
