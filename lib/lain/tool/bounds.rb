# frozen_string_literal: true

module Lain
  class Tool
    # The sizes past which a tool result stops being worth its tokens, in the
    # THREE shapes that question actually has. `arXiv:2508.21433` measures tool
    # observations at ~84% of an average agent turn, so an unbounded result is
    # the single largest thing a turn spends on -- and the house rule across
    # `lib/` is never to lose bytes without saying so.
    #
    # == The boundary, which every applying tool must cite
    #
    # **Enumerations disclose.** A row-shaped result -- matches, paths, symbols,
    # hits -- is a LIST of independent answers, so the first N of them are a
    # usable partial answer. {Enumeration} keeps N and announces the cut IN BAND
    # ({Enumeration#notice}), on the principle {Tools::Grep} established with its
    # `... capped at 200 matches` trailer. The model gets an answer and knows it
    # is partial, which is enough for it to narrow the query itself.
    #
    # **Whole artifacts refuse.** A single indivisible payload -- a file's
    # contents, a command's output -- has no partial form. Its first N bytes are
    # not "some of the answer"; they are an answer that reads complete and is
    # wrong, which is the failure {Review::Bounds} was built against ("a
    # truncated list reads exactly like a short one"). So {Artifact} returns
    # nothing of the payload at all and names a NARROWER ACTION instead, because
    # the model always has a better move available and a refusal that does not
    # say so is a dead end.
    #
    # **What was authored elsewhere hands back.** A human's own message and a
    # skill's expansion are written by somebody other than the loop and are still
    # theirs after a bound has measured them, so the question is not "does this
    # fit" but "does this fit, and if not, do you still want it". {Handback}
    # therefore neither truncates nor discards: it answers with an {Overrun}
    # holding the whole content, the measurement, the ceiling and the actions its
    # CALLER chose to offer, and takes no view on which is taken -- a tool with a
    # human channel can put the choice to the human and send the oversized thing
    # anyway, one without turns the same sentence into a refusal
    # ({Overrun#refusal}). Choosing between those here would make a measurement
    # into a policy.
    #
    # {Artifact} was not widened to cover it, and the grounds are the
    # MEASUREMENT rather than the method count. {Artifact} carries a `unit` word
    # it is handed, while an {Overrun} measures bytes itself; one widened value
    # would let a caller holding `Artifact.new(limit: 200, unit: "matches")`
    # receive "is 11 bytes, over the ceiling of 200" -- a byte count judged
    # against a row cap, which is the unit-contradicting-the-number failure this
    # file exists to refuse. Secondarily, {Artifact}'s guarantee is stated as a
    # PARAMETER LIST -- nothing on it can be handed the payload -- and a
    # content-carrying method there would spend that for every existing caller
    # to buy it for the two that need the opposite.
    #
    # Ask which one applies by asking whether the first N units answer the
    # question that was asked: for a listing they do, for a file's contents they
    # do not. Then ask whether refusing is the last word -- when somebody is
    # there to be asked, it is not.
    #
    # A tool that caps DURING its walk cannot use {Enumeration}, and that is
    # settled rather than pending. {Enumeration#cap} derives the true total from
    # `rows.size`, so it needs the whole ordered collection, while {Tools::Grep}
    # pulls `MAX_MATCHES + 1` off a lazy walk precisely so it never scans the
    # rest, the daemon arm returns only a `capped` boolean, and
    # {Tools::AstSearch} does the same. Those keep their own trailer, pinned by
    # `spec/lain/middleware/withhold_secret_paths_spec.rb` and
    # `spec/lain/sensitivity/filter_spec.rb`, which the count-bearing wording
    # here does not contain. Do not unify the two formats, and do not add an
    # unknown-total mode to make them fit.
    #
    # == Deciding before the bytes exist
    #
    # {Artifact#admits?} takes a byte count and nothing else, so a caller
    # decides from `File.size` before opening the file, or from a running counter
    # mid-stream -- the shape {Tools::WebFetch}'s byte cap already uses to abort
    # a socket read rather than buffer 5 MiB and measure it. That is
    # {Review::Bounds}' discipline ("the DECISION to refuse is reached on a file
    # count alone and never costs a walk over the thing it is refusing to walk
    # over"), sharper here because a size is cheaper still than a count.
    #
    # {Artifact#refusal} takes a size too, and NO content parameter. That is what
    # makes "the refusal carries none of the oversized bytes" a property of the
    # signature rather than a promise about the implementation: a preview cannot
    # be added without changing the parameter list, and a preview is truncation
    # wearing a refusal's clothes.
    #
    # == Carrying the content without interpolating it
    #
    # {Handback} must hold what {Artifact} must not, so the same discipline moves
    # one place over: from "no parameter carries the content" to "no parameter
    # carries a SIZE". {Handback#overrun} is handed the content and measures it
    # with `bytesize` itself, and {Overrun#message} takes no arguments at all --
    # so the tool holding both an output String and its byte count, one character
    # from passing the wrong one, has no second value here to confuse the first
    # with.
    #
    # Holding the payload is not the same as never printing it, and that is the
    # half a signature cannot state: `Data` renders every member, so the default
    # `#inspect` would put a megabyte of a human's own reply into any `"#{over}"`
    # -- and the Journal is NDJSON, where one such line is the failure this whole
    # bound exists to prevent. {Overrun#inspect} therefore names the safe members
    # and withholds the content, with `to_s` and `pretty_print` following it,
    # after the pattern {Provider::Ollama::Deployment::Cloud} set for a live
    # credential. What remains is `#to_h`, pattern matching, and any whole-object
    # serialiser (`Marshal`, YAML) -- what `Data` gives every value, and none of
    # it reached by accident: the payload comes out only where a caller names
    # {Overrun#content}, destructures for it, or asks for the whole object.
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
      # `Result.error(e.message)`, so an exception that echoes its argument hands
      # the model the very bytes a refusal exists to withhold -- one hop past the
      # refusal, and just as leaked. The hazard is in `e.message` itself, not in
      # how Live frames it.
      def self.ceiling(value)
        raise ArgumentError, "a bound must be an Integer, got #{value.class}" unless value.is_a?(Integer)
        raise ArgumentError, "a bound must be non-negative, got #{value}" if value.negative?

        value
      end

      # A caller's own word, frozen so the value object holding it stays
      # `Ractor.shareable?`. `String#-@` rather than `#freeze` because
      # `Symbol#to_s` and interpolation both hand back MUTABLE Strings, which is
      # the trap that broke deep immutability once already.
      def self.phrase(value) = -value.to_s

      # The unit a bound counts in. The same freeze as {.phrase} and deliberately
      # its own name: {Enumeration} and {Artifact} are handed a countable noun
      # and print it beside a number, which is a narrower promise than "a word
      # this value holds", and both are proven against it. A rename would spend
      # that parity on a tidy.
      def self.unit(value) = phrase(value)

      # The actions a bound offers instead of what it would not pass. At least
      # one, always: advice that names nowhere to go leaves the model to re-issue
      # the same call and be refused identically, which is the loop these exist
      # to break.
      # The Array check comes first because `empty?` answers for a String too: a
      # single action handed in bare would slide past the emptiness rule and die
      # at `map` with a `NoMethodError`, which {Effect::Handler::Live} puts on
      # the model's channel as a crash-shaped sentence.
      def self.offer(actions)
        raise ArgumentError, "a bound's actions must be an Array, got #{actions.class}" unless actions.is_a?(Array)
        raise ArgumentError, "a bound must offer an action" if actions.empty?

        actions.map { |action| phrase(action) }.freeze
      end

      # What a bound was handed is a String or it is a bug, and the message names
      # the CLASS and never the value, for {.ceiling}'s reason. Its own function
      # rather than a line inside {.payload} because {Handback#measure} has to
      # ask the question BEFORE it knows whether it will keep a copy, and copying
      # a megabyte only to discard it is the one cost this shape must not pay.
      def self.text(content)
        raise ArgumentError, "a bound hands back a String, got #{content.class}" unless content.is_a?(String)

        content
      end

      # The oversized thing itself, for the one shape that keeps it. A frozen
      # COPY, so a caller may go on writing to its own buffer without changing
      # what the value says it holds -- and `dup` rather than `String#-@`, which
      # would intern a payload-sized String for the life of the process. The copy
      # is UNCONDITIONAL, and a frozen input is not short-circuited past it, for
      # the symmetry {Enumeration#cap} argues at length: whether the value holds
      # the caller's own object should not depend on how that caller happened to
      # build it.
      def self.payload(content) = text(content).dup.freeze

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
        # shape is FOR are read by `Listing`, whose `paths_in(row)` is `[row]`,
        # so under `glob` and `list_files` this row IS offered to
        # {Sensitivity::Filter} as a candidate path and survives because the
        # classifier rules it `:ordinary`. A tool adopting this notice therefore
        # OWES a test that its own reader keeps the row: the survival is a
        # classification, not a structural guarantee.
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
        # `size` goes back through {Bounds.ceiling} even though {#admits?} has
        # usually just asked it, because {#admits?} is not on this path -- a
        # caller reaches the refusal by any route it likes. A tool holding both
        # an output String and its `bytesize` is one character from passing the
        # wrong one, and an unchecked interpolation would put the entire payload
        # inside the message built to carry none of it. `subject` and `narrower`
        # are prose by design and deliberately NOT policed: no signature can, and
        # pretending otherwise is theatre.
        #
        # @raise [ArgumentError] when no narrower action is offered -- advice
        #   that names nowhere to go leaves the model to re-issue the same call
        #   and be refused identically, which is the loop this exists to break
        def message(subject:, size:, narrower:)
          raise ArgumentError, "a refusal must offer a narrower action" if narrower.empty?

          measured = Bounds.ceiling(size)
          "#{subject} is #{measured} #{unit}, over the ceiling of #{limit} -- instead, #{narrower.join(", or ")}"
        end
      end

      # The handing-back shape: measure it, keep every byte, leave the choice to
      # the caller. It counts BYTES and carries no unit, unlike its two siblings,
      # because the measurement is taken here rather than accepted -- a word
      # naming another unit would be free to contradict the number beside it.
      Handback = Data.define(:limit) do
        def initialize(limit:) = super(limit: Bounds.ceiling(limit))

        # @param size [Integer] a byte count, from `String#bytesize` or any of
        #   the cheap sources {Artifact#admits?} accepts
        # @return [Boolean] whether it fits under the ceiling
        def admits?(size) = size <= limit

        # The primary door: one call, no guard to forget, nothing to report when
        # nothing overran. `nil` rather than a null {Overrun} despite the house
        # preference, because a null one would have to answer {Overrun#content},
        # and handing the payload back through the shape that means "it fit" is
        # the confusion this value exists to prevent.
        #
        # @param subject [String] what overran, in the reader's terms ("your
        #   reply", "the skill's expansion")
        # @param content [String] the whole thing, measured here and handed back
        #   intact if it overran. Checked before it is measured, so the door both
        #   consumers are told to use refuses a non-String as loudly as the other
        #   one does, rather than dying at `bytesize`
        # @param actions [Array<String>] what this caller is willing to offer,
        #   phrased for ITS OWN audience -- see the warning on {#overrun}
        # @return [Overrun, nil] nil when the content fits
        def measure(subject:, content:, actions:)
          return nil if admits?(Bounds.text(content).bytesize)

          overrun(subject:, content:, actions:)
        end

        # The same value built directly, for a caller that has already asked
        # {#admits?}. Calling it on content that fits is a PROGRAMMER error and
        # says so: a sentence about the content would reach the model through
        # {Effect::Handler::Live} shaped exactly like a bound's refusal while
        # asserting that the thing fits.
        #
        # `actions` are AUDIENCE-BOUND and nothing here can check that. Nothing
        # in this value knows whether the caller will offer them to a human or
        # render them through {Overrun#refusal}, so "send it anyway" written by a
        # tool that will send nothing tells the model it has an option it does
        # not. {Artifact#message} prevents that structurally by hard-coding
        # "instead"; this shape cannot, because the choice is the caller's.
        #
        # @param subject [String] what overran, in the reader's terms
        # @param content [String] the whole oversized thing, handed back intact
        # @param actions [Array<String>] what this caller is willing to offer,
        #   phrased for the audience that will read them
        # @return [Overrun]
        # @raise [ArgumentError] when the content fits after all
        def overrun(subject:, content:, actions:) = Overrun.new(bound: self, subject:, content:, actions:)
      end

      # What did not fit, handed back whole alongside what may be done about it.
      # The measurement is derived and never stored, so {#size} and {#content}
      # cannot disagree, and the invariants are checked at construction so that
      # no {Overrun} describing something that fits, or offering nowhere to go,
      # can exist by any door.
      Overrun = Data.define(:bound, :subject, :content, :actions) do
        # The bound is type-checked where a size is not, because the structural
        # argument that saves the size does not reach it: every {Bounds} shape
        # answers `admits?` and `limit`, so an {Enumeration} counting rows would
        # compose "11 bytes, over the ceiling of 10" against a row cap without a
        # murmur.
        #
        # The fits-after-all sentence names no measurement on purpose. It is a
        # bug report for whoever wrote the call, and a sentence about the content
        # would reach the model through {Effect::Handler::Live} shaped exactly
        # like a bound's refusal while asserting that the thing fits.
        def initialize(bound:, subject:, content:, actions:)
          raise ArgumentError, "an overrun is bounded by a Handback, got #{bound.class}" unless bound.is_a?(Handback)

          held = Bounds.payload(content)
          if bound.admits?(held.bytesize)
            raise ArgumentError, "an overrun was built from content that fits -- use Handback#measure, " \
                                 "or guard Handback#overrun with #admits?"
          end

          super(bound:, subject: Bounds.phrase(subject), content: held, actions: Bounds.offer(actions))
        end

        # @return [Integer] the measurement, taken from the content itself
        def size = content.bytesize

        # @return [Integer] the ceiling it overran
        def limit = bound.limit

        # Phrased as {Artifact#message} is, up to the connector: that one says
        # "instead" because the payload is gone, this one names options.
        #
        # @return [String]
        def message = "#{subject} is #{size} bytes, over the ceiling of #{limit} -- #{actions.join(", or ")}"

        # The affordance for a caller with nobody to ask: the same sentence, still
        # carrying none of the payload. It renders whatever actions were baked
        # in, so a caller reaching for this one owes actions phrased for a model
        # being refused rather than for a human being offered a choice.
        #
        # @return [Tool::Result] an error result carrying {#message}
        def refusal = Result.error(message)

        # Never the content. `Data` renders every member, so the default would
        # put the whole payload into a `"#{over}"` -- an interpolation a
        # consumer writes without thinking, and one NDJSON line is all the
        # Journal needs to stop being parseable. `pretty_print` is overridden
        # for the same reason `Provider::Ollama::Deployment::Cloud` overrides
        # it: `pp` walks the members itself rather than calling `#inspect`.
        def inspect
          "#<data #{self.class} subject=#{subject.inspect} size=#{size} limit=#{limit} " \
            "actions=#{actions.inspect} content=[WITHHELD]>"
        end
        alias_method :to_s, :inspect

        def pretty_print(printer) = printer.text(inspect)
      end
    end
  end
end
