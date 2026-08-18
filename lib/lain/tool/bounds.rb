# frozen_string_literal: true

module Lain
  class Tool
    # The sizes past which a tool result stops being worth its tokens, in the
    # TWO shapes that question actually has.
    #
    # `arXiv:2508.21433` measures tool observations at ~84% of an average agent
    # turn, so an unbounded result is the single largest thing a turn spends on.
    # What this object refuses to do is spend those tokens *silently*: the house
    # rule across `lib/` is never lose bytes without saying so, and both shapes
    # below satisfy it in different ways because the results they bound are
    # different in kind.
    #
    # == The boundary, which every applying tool must cite
    #
    # **Enumerations disclose.** A row-shaped result -- matches, paths, symbols,
    # hits -- is a LIST of independent answers, so the first N of them are a
    # usable partial answer. {Enumeration} keeps N and announces the cut IN BAND
    # ({Enumeration#notice}), on the principle {Tools::Grep} established with
    # its `... capped at 200 matches` trailer -- the principle, not the string.
    # The model gets an answer and knows it is partial, which is enough for it
    # to narrow the query itself.
    #
    # A tool that caps DURING its walk cannot come here, and that is settled
    # rather than pending. {Enumeration#cap} derives the true total from
    # `rows.size`, so it needs the whole ordered collection; {Tools::Grep}
    # pulls `MAX_MATCHES + 1` off a lazy walk precisely so it never scans the
    # rest, the daemon arm returns only a `capped` boolean, and
    # {Tools::AstSearch} does the same. None can supply a total, and their
    # `... capped at 200 matches` trailer is pinned by
    # `spec/lain/middleware/withhold_secret_paths_spec.rb` and
    # `spec/lain/sensitivity/filter_spec.rb`, which the count-bearing wording
    # here does not contain. So those four keep their own trailer and stay off
    # this object; do not unify the two formats, and do not add an
    # unknown-total mode to make them fit.
    #
    # **Whole artifacts refuse.** A single indivisible payload -- a file's
    # contents, a command's output -- has no partial form. Its first N bytes are
    # not "some of the answer"; they are an answer that reads complete and is
    # wrong, which is the failure {Review::Bounds} was built against ("a
    # truncated list reads exactly like a short one"). So {Artifact} returns
    # nothing of the payload at all and instead names a NARROWER ACTION -- a
    # window, a structural query -- because the model always has a better move
    # available and a refusal that does not say so is a dead end.
    #
    # The two are not a preference between styles. Ask which one applies by
    # asking whether the first N units answer the question that was asked: for
    # a listing they do, for a file's contents they do not.
    #
    # == Deciding before the bytes exist
    #
    # {Review::Bounds} states the discipline this copies: "the DECISION to
    # refuse is reached on a file count alone and never costs a walk over the
    # thing it is refusing to walk over." Here that is sharper, because a size
    # is cheaper still than a count. {Artifact#admits?} takes a byte count and
    # nothing else, so a caller decides from `File.size` before opening the
    # file, or from a running counter mid-stream -- the shape
    # {Tools::WebFetch}'s byte cap already uses to abort a socket read rather
    # than buffer 5 MiB and measure it.
    #
    # {Artifact#refusal} takes a size too, and NO content parameter. That is
    # what makes "the refusal carries none of the oversized bytes" a property of
    # the signature rather than a promise about the implementation: a preview
    # cannot be added without changing the parameter list, and a preview is
    # truncation wearing a refusal's clothes.
    module Bounds
      # A non-negative Integer or it is a bug. One rule for a CEILING and for
      # the measurement a ceiling is compared against, because the two are the
      # same kind of number and a bound that trusted one but not the other would
      # have a loud path and a silent one.
      #
      # STRICT, which `Integer()` is not: `Integer("262144")` parses, `"0x10"`
      # becomes 16 and `2.7` truncates to 2, all silently. A count that arrived
      # as the wrong type arrived from somewhere that is wrong about it, so it
      # fails here rather than at `Array#first(nil)` mid tool call.
      #
      # The message names the CLASS and never the value, and that is not
      # fussiness. {Effect::Handler::Live} turns a raising tool into
      # `Result.error("#{e.class}: #{e.message}")`, so an exception that echoes
      # its argument hands the model the very bytes a refusal exists to
      # withhold -- one hop past the refusal, and just as leaked.
      def self.ceiling(value)
        raise ArgumentError, "a bound must be an Integer, got #{value.class}" unless value.is_a?(Integer)
        raise ArgumentError, "a bound must be non-negative, got #{value}" if value.negative?

        value
      end

      # The unit a bound counts in, frozen so the value object stays
      # `Ractor.shareable?`. `String#-@` rather than `#freeze` because
      # `Symbol#to_s` and interpolation both hand back MUTABLE Strings, which is
      # the trap that broke deep immutability once already.
      def self.unit(value) = -value.to_s

      # The disclosing shape: cap the rows, say so in the rows.
      Enumeration = Data.define(:limit, :unit) do
        def initialize(limit:, unit:)
          super(limit: Bounds.ceiling(limit), unit: Bounds.unit(unit))
        end

        # @param count [Integer] how many rows are on offer
        # @return [Boolean] whether they fit under the cap
        def admits?(count) = count <= limit

        # Applied AFTER the caller's deterministic ordering, never by stopping a
        # walk early -- `spec/lain/core/grep_parity_spec.rb` records that walk
        # order diverges under a cap, so which rows survive must be decided by
        # the sort and not by the filesystem.
        #
        # Frozen on BOTH branches, and that symmetry is the point rather than
        # the freezing: returning the caller's own mutable Array when it fits
        # and a fresh one when it does not means the return value's aliasing
        # depends on how many rows a directory happened to hold, which is a
        # difference no caller should have to think about and none would test.
        #
        # @param rows [Array<String>] every row the tool found, already ordered
        # @return [Array<String>] a frozen copy of the rows when they fit;
        #   otherwise the first {#limit} of them followed by one {#notice} row
        def cap(rows)
          return rows.dup.freeze if admits?(rows.size)

          (rows.first(limit) + [notice(rows.size)]).freeze
        end

        # The in-band disclosure. It names the TRUE count as well as the cap,
        # because "200 of 5000" tells the model how much it is missing and
        # "200" alone does not.
        #
        # == Why it survives the secret filter, stated exactly
        #
        # Not because it names no path. That reasoning holds only under grep's
        # reader ({Middleware::WithholdSecretPaths::MATCHES}, which finds no
        # `path:lineno:text` split and leaves the row alone). The tools this
        # shape is FOR are read by `Listing`, whose `paths_in(row)` is `[row]`
        # -- so under `glob` and `list_files` this row IS offered to
        # {Sensitivity::Filter} as a candidate path, and it survives because the
        # classifier rules it `:ordinary`, not because there was nothing to
        # classify. A tool adopting this notice therefore OWES a test that its
        # own reader keeps the row; the survival is a classification, not a
        # structural guarantee.
        #
        # @param total [Integer] the true row count
        # @return [String]
        def notice(total) = "... capped at #{limit} of #{total} #{unit}"
      end

      # The refusing shape: name the size, the ceiling and a narrower action,
      # and return none of the payload.
      Artifact = Data.define(:limit, :unit) do
        def initialize(limit:, unit: "bytes")
          super(limit: Bounds.ceiling(limit), unit: Bounds.unit(unit))
        end

        # @param size [Integer] the artifact's size, from `File.size`, a
        #   streaming counter, or `String#bytesize` -- the content itself is
        #   deliberately not a parameter
        # @return [Boolean] whether it fits under the ceiling
        def admits?(size) = size <= limit

        # @param subject [String] what is being refused, in the reader's terms
        #   (a path, "the command's output")
        # @param size [Integer] the measurement that failed
        # @param narrower [Array<String>] the actions that WOULD work
        # @return [Tool::Result] an error result carrying {#message}
        def refusal(subject:, size:, narrower:) = Result.error(message(subject:, size:, narrower:))

        # Phrased as {Review::Bounds}' refusals are, because a reader meeting
        # both should not have to work out that they are the same sentence.
        #
        # @raise [ArgumentError] when no narrower action is offered -- advice
        #   that names nowhere to go leaves the model to re-issue the same call
        #   and be refused identically, which is the loop this exists to break
        # `size` goes back through {Bounds.ceiling} even though {#admits?} has
        # usually just asked it, because {#admits?} is not on this path -- a
        # caller reaches the refusal by any route it likes. A tool holding both
        # an output String and its `bytesize` is one character from passing the
        # wrong one, and an unchecked interpolation would put the entire payload
        # inside the message built to carry none of it. `subject` and `narrower`
        # are prose by design and deliberately NOT policed: no signature can,
        # and pretending otherwise is theatre. `size` is different because it is
        # declared a byte count and the decide-from-a-size-alone contract rests
        # on it being one.
        def message(subject:, size:, narrower:)
          raise ArgumentError, "a refusal must offer a narrower action" if narrower.empty?

          measured = Bounds.ceiling(size)
          "#{subject} is #{measured} #{unit}, over the ceiling of #{limit} -- instead, #{narrower.join(", or ")}"
        end
      end
    end
  end
end
