# frozen_string_literal: true

module Lain
  module Middleware
    # Masks the sensitive regions of a `read_file` result that nobody has agreed
    # to send, and parks an approval so somebody can.
    #
    # {RefuseSecretWrites}' mirror image: same phase, same seam, same journaling
    # discipline, and the same argument turned around. That one withholds a
    # write because a credential inside a Memory::Item is indexed and durable
    # and there is no un-indexing it. This one rewrites `env[:result]` on the way
    # OUT of the tool phase, so unreleased bytes never exist above the
    # middleware -- never in an {Event}, never in a digest, never in the
    # prompt-cache prefix. Both are the same rule: the only place a leak can be
    # stopped is before the thing that remembers it.
    #
    # == Why this boundary exists when the path boundary already refused
    #
    # {Sensitivity::Policy} judges a PATH before the read, which is the only
    # thing it can judge -- content is not knowable until the bytes are in hand.
    # So this is the one boundary that can see a secret in a file classified
    # ORDINARY: a `.env` copied to `notes.txt`, a key pasted into a fixture, a
    # token committed to a spec. A path rule structurally cannot catch those.
    #
    # == Masking always comes with a release path
    #
    # An arm that only masked would leave the agent reading `Cargo.lock`,
    # getting `<redacted:1>` forever, with no move available to model or human.
    # So when anything would be masked this parks a {Approval::Queue::Pending}
    # carrying the outstanding regions and awaits it. Approve and the full bytes
    # are returned and those regions are released to the ledger; deny, defer or
    # time out and the masked projection stands. The fail-closed default is the
    # queue's own -- an unanswered window denies -- and is not reimplemented
    # here.
    #
    # An unreleased region renders as `<redacted:N>` and a released one as its
    # real bytes, so the model keeps the file's STRUCTURE -- for a `.env`, the
    # key names -- and partial approval falls out of that for free.
    #
    # == The ordinal in the placeholder is not the region's length
    #
    # `N` counts masked regions in reading order, so three masked values render
    # as three distinguishable placeholders and the model can say which one it
    # needs. The obvious alternative -- the byte length withheld -- would
    # disclose how long the secret is, which is a fact about the secret. The
    # ordinal discloses only how many there are, which the prompt already tells
    # the human.
    #
    # == It never short-circuits, and it never lets a raise escape
    #
    # {Middleware::Env} is `fetch`-based, so a phase that forgets its out-key
    # fails loudly. This calls {Base#downstream} first and merges afterwards, so
    # `:result` is always set by the tool and only ever REPLACED here.
    #
    # Keeping that true needs an explicit rescue now, which it did not when this
    # was pure masking: {#settle} AWAITS a human, and an await has failure modes
    # a fold over bytes does not. A raise from here escapes into
    # {Agent::ToolRunner}, which has already committed the `tool_use` -- so the
    # turn ends with a tool_use no tool_result answers, the state machine wedges
    # at `awaiting_tools`, and every later turn is a 400 from the real API.
    # {Provider::Mock} accepts that shape, which is why no spec would show it.
    #
    # The rescue answers with an ERROR result and never with the bytes: a read
    # this class could not finish checking is a read whose secrets it cannot
    # vouch for, so the fail-closed answer is the only one available.
    #
    # == Detection is not size-capped, deliberately
    #
    # {Sensitivity::Regions} costs ~0.22ms/KB, linearly, with no blowup on
    # adversarial input, and its docstring hands the cap decision to whichever
    # arm holds the bytes. This one declines to set one. A cap has exactly two
    # shapes and both are worse than the cost: scan a prefix and the tail ships
    # unmasked, which is a leak the size of the file; refuse the read outright
    # and a legitimate large file becomes unreadable with no move -- the dead end
    # the release path above exists to prevent. A megabyte costs ~0.2s once, on
    # the same fiber, before anything parks. If a cap is ever taken it must come
    # back through `complete: false`, or every read past it forgets its releases
    # and re-prompts forever.
    class RedactSecretReads < Base
      # Exact membership, {RefuseSecretWrites::GUARDED_TOOLS}' rule: a tool that
      # returns file bytes under some other name is unguarded by design until it
      # earns a place here. `bash` reading a file with `cat` is deliberately NOT
      # in this set -- that is the path boundary's job and a different card's.
      GUARDED_TOOLS = Set["read_file"].freeze

      PLACEHOLDER = "<redacted:%d>"

      # The provider content-block key this can read. Anything else in an Array
      # result is bytes this detector cannot see -- see {Scan}.
      TEXT = "text"

      # The key a guarded tool names its file under. Named rather than inline
      # because {TEXT} above is a different string that happens to look related.
      PATH_INPUT = "path"

      # The queue a `--yolo` run does not wire. {CLI::Switchboard#approvals} is
      # nil under the flag, and the three answers available were: return the
      # full bytes, refuse the read, or mask with no release. The last leaves
      # the model `<redacted:1>` forever with nobody able to answer, and the
      # second makes `--yolo` stricter than the default, which inverts what the
      # flag means. So the stand-in answers what `--yolo` already answers
      # everywhere else in this harness -- approve, ask nobody -- and the
      # release is real, because the run genuinely did approve it.
      #
      # It is passed EXPLICITLY and `queue:` carries no default, so this cannot
      # be reached by forgetting an injection. That is {Sensitivity::Ledger}'s
      # no-Null rule honoured rather than dodged: what it forbids is silent
      # approval arriving by omission, not a named object that approves on
      # purpose.
      class Unqueued
        # The one message this middleware reads off a settled
        # {Approval::Queue::Pending}.
        class Verdict
          def approved? = true

          INSTANCE = new.freeze

          def self.instance = INSTANCE
        end

        # `outstanding:` is accepted and discarded, but cannot be renamed to the
        # unused-argument underscore: it is a KEYWORD, so the name is the duck.
        def adjudicate(_effect, _context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
          Verdict.instance
        end

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # The contract the required `ledger:` keeps, named so the raise below and
      # the doc above it cannot drift into two different arguments.
      LEDGER_CONTRACT = "the run has ONE region ledger, built on the Switchboard and injected -- " \
                        "a second one holds releases nobody ever sees"

      # Readable for {Agent::ToolRunner#handler}'s reason: what a guard was
      # wired to is not private business when the caller did not build it, and
      # the wiring spec has to be able to assert IDENTITY -- that this holds the
      # board's one ledger and the board's one queue, not a second of either.
      # Asserting on behaviour instead cannot tell a fresh ledger from the
      # board's, which is exactly the mutation that survived review.
      attr_reader :ledger, :queue, :journal

      # @param ledger [Sensitivity::Ledger] the run's ONE region ledger.
      #   REQUIRED, with no default and no Null Object: a default is how a
      #   second ledger gets constructed in silence, and a Null would answer
      #   "nothing outstanding" forever -- a release control that releases
      #   everything, wearing this codebase's Null idiom as camouflage.
      # @param queue [#adjudicate] where a read parks for release, or
      #   {Unqueued} under `--yolo`. Required for the same reason.
      # @param journal [#<<] where {Telemetry::ReadRedacted} lands
      # @raise [ArgumentError] on a nil ledger or queue
      def initialize(ledger:, queue:, journal: Channel::Null.instance)
        # A missing KEYWORD is Ruby's error; a nil VALUE is not, and nil is
        # exactly what `Switchboard#approvals` carries under --yolo -- so
        # without this the argument that "no default means no silent approval"
        # rests on nobody ever passing the value the wiring actually holds.
        raise ArgumentError, "a ledger is required: #{LEDGER_CONTRACT}" unless ledger
        raise ArgumentError, "a queue is required: pass #{Unqueued.name} where a run wires none" unless queue

        @ledger = ledger
        @queue = queue
        @journal = journal
        # Mutable, on a frozen object, deliberately: `freeze` seals the ivars,
        # not the Set they point at, and this is the run's accumulating
        # answer-memory -- {Sensitivity::Ledger}'s own posture, for its reason.
        @declined = Set.new
        super()
        freeze
      end

      Withheld = Data.define(:session, :path, :scan, :unreleased)

      # What one masking decision needs to carry, so the collaborators it
      # touches do not become five parameters on every method.
      class Withheld
        def found = scan.regions.length

        # Counts, never bytes -- what {Telemetry::ReadRedacted} carries.
        #
        # DERIVED from the snapshot, deliberately, and NOT re-asked of the
        # ledger. An earlier edition asked, on the argument that a subtraction
        # merely restates the line above it. That argument was wrong twice over.
        #
        # The two are not equal. `unreleased` is captured BEFORE the park and
        # the ledger is read AFTER it, with a human await in between and
        # {Tools::ReadFile#parallel_safe?} siblings running in the same reactor
        # -- so a sibling read of the same file, approved while this one waited,
        # moves the ledger under this record. Measured: two concurrent reads,
        # one approved and one denied, and the ledger form reports `released: 1`
        # for the read that masked the region and sent nothing.
        #
        # That is the wrong direction. This record describes ONE read: how many
        # regions it found, and how many of them it actually rendered as real
        # bytes. The snapshot is what that read acted on, so the snapshot is
        # what it must report. Reading the ledger later answers a different
        # question -- "what does the run believe now" -- and writing that answer
        # here puts a false entry inside the very count
        # {Telemetry::Guards::ReadRedacted}'s `released <= regions` validator
        # exists to keep honest.
        def released = found - unreleased.length
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        carried = downstream(env, &app)
        return carried unless GUARDED_TOOLS.include?(effect.name)

        guarded(carried, effect)
      end

      private

      # `Async::Stop` is deliberately NOT rescued: it is not a StandardError,
      # and a stopped requester must keep unwinding. {#settle}'s `ensure` is
      # what makes that safe -- it has already recorded the mask by the time the
      # stop passes through here.
      def guarded(carried, effect)
        result = carried.fetch(:result)
        # A failed read carries a message, never file bytes, so there is nothing
        # here to mask and no read to record.
        return carried if result.error?

        adjudicate(carried, effect, result)
      rescue StandardError => e
        # The CLASS only. An exception's message can quote the input that
        # produced it, and the input here is a file full of the bytes this
        # class exists to withhold.
        carried.merge(result: Tool::Result.error(
          "#{effect.name} could not be checked for unreleased secrets (#{e.class}); nothing was returned."
        ))
      end

      # The call order the ledger's contract fixes: detect, ask what is
      # outstanding, adjudicate, and release ONLY on approval -- the unreleased
      # list, never every region, because what the human agreed to send is not a
      # statement about what else the file holds.
      def adjudicate(carried, effect, result)
        scan = Scan.new(result.content)
        # Refused BEFORE the ledger is touched. `outstanding` RECONCILES -- it
        # drops the releases for regions the file no longer holds -- so asking
        # it about a view we are about to refuse would forget releases for
        # regions nobody looked at, and re-prompt for them forever after.
        return unreadable(carried, effect) unless scan.readable?

        withheld = withheld_in(carried, effect, scan)
        return carried unless withheld.unreleased.any?
        return mask(carried, effect, withheld) if declined?(withheld)

        settle(carried, effect, withheld)
      end

      # Content this class cannot scan cannot be vouched for, so it is not sent.
      # The alternative -- pass the unscannable blocks through and mask only the
      # ones it understood -- is the fail-open shape {Scan} documents.
      def unreadable(carried, effect)
        carried.merge(result: Tool::Result.error(
          "#{effect.name} returned content this secret boundary cannot scan, so it was withheld."
        ))
      end

      # Ask the ledger what nobody has agreed to send.
      #
      # `complete: true` unconditionally, and that is a claim this class earns
      # rather than assumes: content it could not fully scan is REFUSED above,
      # never scanned in part, and there is no size cap. So a scan that reaches
      # the ledger has by construction seen every byte, which is exactly what
      # makes the reconcile inside `outstanding` sound.
      def withheld_in(carried, effect, scan)
        session = carried.fetch(:context) || Session::Null.instance
        # ABSOLUTE, resolved against the READING WORKER's cwd and never the
        # process's: the ledger is per-run and reaches every child, so it has no
        # cwd of its own and raises on a relative path. This is the same rule
        # {Tools::ReadFile} resolved by, so the ledger, the prompt and the
        # read-set all name one file.
        path = Session.normalize_path(effect.input[PATH_INPUT], cwd: session.worker_env.cwd)

        Withheld.new(session:, path:, scan:,
                     unreleased: @ledger.outstanding(path, scan.regions, complete: true))
      end

      # Already asked about, and not approved. Asking again cannot produce a
      # different answer without a human doing something the model cannot
      # prompt for, and each re-ask costs another full timeout window -- 300
      # seconds by default -- so a model told to re-read a denied file turns
      # one refusal into an unbounded series of five-minute stalls.
      #
      # A TIMEOUT counts as a decline for the same reason a denial does: nobody
      # answered, and the queue's own doctrine is that an unattended gate
      # refuses. Approval is the only answer that clears it.
      #
      # Run-scoped and add-only, like everything else on this boundary, so the
      # worst it can do is mask something a human would have released -- and
      # they can still release it by reading a file whose regions have changed.
      # Two sibling fibers can both park for the same digests (the check and
      # the record sit either side of the await), which costs one extra prompt
      # and nothing else.
      def declined?(withheld) = withheld.unreleased.all? { @declined.include?([withheld.path, _1.digest]) }

      # The await is the only place in this class that can be unwound from
      # outside, and the read-set is already wrong when it is.
      #
      # {Tools::ReadFile} recorded a COMPLETE read below this middleware before
      # the park ever began, and `@masked` is add-only, so if control leaves
      # here without a verdict nothing later repairs it: `read?` stays true,
      # `masked_read?` stays false, and `edit_file` is ALLOWED over a file whose
      # secrets the model never saw. The control fails OPEN, in the one
      # direction it exists to prevent. The window is the queue's, 300 seconds
      # by default, and a Ctrl-C at the prompt is enough to reach it -- a park
      # `read_file` never had before this class.
      #
      # `ensure`, and gated on a DECISION rather than on the call returning,
      # because both halves can be skipped: a surface that raises unwinds
      # `adjudicate` itself, and a requester stopped mid-park raises
      # `Async::Stop`, which is not a StandardError and no rescue sees. Gating
      # on `settled` alone would still miss a duck whose `approved?` raises.
      #
      # Recording the mask up front and retracting it on approval is the
      # obvious alternative and is not available: `@masked` has no removal, by
      # {Session::ReadSet}'s design.
      def settle(carried, effect, withheld)
        outstanding = Approval::Queue::Outstanding.new(path: withheld.path, regions: withheld.unreleased)
        decided = false
        settled = @queue.adjudicate(effect, carried.fetch(:context), outstanding:)
        approved = settled.approved?
        decided = true
        return release(carried, withheld) if approved

        mask(carried, effect, withheld)
      ensure
        withheld.session.record_masked_read(withheld.path) unless decided
      end

      # Nothing was withheld, so nothing is recorded and nothing is journaled:
      # the approval's own decision record is what says a secret was sent, and a
      # {Telemetry::ReadRedacted} over a read that redacted nothing would be a
      # false finding in the experiment record.
      def release(carried, withheld)
        @ledger.release(withheld.path, withheld.unreleased)
        carried
      end

      # Journaled on a STATE TRANSITION, not on a call --
      # {Session::Journaled#record_read}'s rule, which this has to match or
      # break. That method emits ONE line however many times a read/edit loop
      # revisits a file; a redaction line per read would mean an unmasked file
      # journals once over ten iterations and a masked one journals ten times,
      # so the record would be noisiest exactly where the loop is most likely.
      # `@declined` already holds "these digests at this path have been ruled
      # on", which is the transition, so the check goes BEFORE it is added to.
      def mask(carried, effect, withheld)
        withheld.session.record_masked_read(withheld.path)
        record(redaction(effect, withheld)) unless declined?(withheld)
        withheld.unreleased.each { @declined << [withheld.path, _1.digest] }
        carried.merge(result: Tool::Result.ok(withheld.scan.mask(withheld.unreleased)))
      end

      def redaction(effect, withheld)
        Telemetry::ReadRedacted.new(tool_use_id: effect.tool_use_id, path: withheld.path,
                                    regions: withheld.found, released: withheld.released)
      end

      # Evidence about a turn must never be able to COST the turn --
      # {Approval::Queue#record_evidence}'s argument, and this seam sits under
      # it too: the mask above has already happened, so a closed Journal or a
      # full disk must not convert a correctly-masked read into the error
      # result {#guarded}'s rescue would otherwise produce.
      #
      # It SWALLOWS rather than degrading into a `journal_error` record the way
      # Queue does, because this journal is a `#<<` Channel and has no such
      # shape to fall back to. The cost is stated rather than hidden: this
      # record is also what {SessionRecord::Replay#redactions} reads, so a lost
      # write means a resumed session does not know the path was masked. The
      # LIVE session still does, and a journal that cannot be written to is not
      # one a resume was going to work from anyway.
      def record(entry)
        @journal << entry
      rescue StandardError
        nil
      end

      # The detector's view of one {Tool::Result}'s content, and the masked
      # rendering of it.
      #
      # `content` is a String or an Array of provider content blocks, so "the
      # file's bytes" is not one thing, and the difference is decided here
      # rather than papered over with a `to_s` that would corrupt a legitimate
      # result. A String IS the whole file. An Array is a partial view: its text
      # blocks are readable and everything else -- an image, a document -- is
      # bytes this detector structurally cannot see, so those blocks pass
      # through untouched and {#complete?} answers false.
      #
      # That false is not a formality. `complete: false` is what stops
      # {Sensitivity::Ledger#outstanding} reconciling releases away against
      # regions nobody looked at, which would re-prompt for secrets already
      # approved, forever.
      #
      # `read_file` returns a String today, so the Array arm is unexercised in
      # production. It is here because the arm that guesses is the one that
      # ships a corrupted result the first time a tool returns blocks -- which
      # means it has to be ready in the RIGHT direction. An earlier edition was
      # not: a text block spelled any way this did not recognise (a Symbol
      # `:text` key, a bare String element, text nested a level down) simply
      # produced no regions, and a result with no regions takes the early
      # return -- so the bytes went to the model unmasked with nobody asked.
      # Fail-open, in the class whose whole purpose is the opposite.
      #
      # So {#readable?} is now the question, and an Array carrying anything this
      # cannot read is REFUSED rather than passed through. That is deliberately
      # loud and deliberately inconvenient: whoever first makes a guarded tool
      # return image or document blocks will get a refusal and has to decide
      # what masking means for them, which is a decision this class must not
      # make silently on their behalf.
      class Scan
        # A piece of scannable text, and the key it has to be written back
        # under. `key` is nil when the block IS the String, so there is nothing
        # to merge into.
        Piece = Data.define(:text, :key)

        def initialize(content)
          @content = content
          @pieces = content.is_a?(String) ? [Piece.new(text: content, key: nil)] : content.map { piece_of(_1) }
          @detected = @pieces.map { |piece| piece && Sensitivity::Regions.detect(piece.text) }
          freeze
        end

        # Whether every piece of this content is text this could scan. False
        # means the result must not be sent at all: there is no "scan the part
        # I understood and forward the rest", because the rest is what would
        # carry the secret out.
        #
        # This replaced a `complete?` that answered the ledger's narrower
        # question -- "did I see the whole file?" -- and then let an incomplete
        # scan through anyway. Once an unreadable result is refused outright,
        # the two questions collapse into this one and the ledger is always
        # told `complete: true`, truthfully.
        def readable? = @pieces.all?

        # @return [Array<Sensitivity::Regions::Region>] every region found, in
        #   reading order
        def regions = @detected.compact.flatten

        # @param unreleased [Array<#digest>] the regions to withhold
        # @return [String, Array] content shaped exactly as it arrived
        def mask(unreleased)
          withheld = unreleased.to_set(&:digest)
          # An Enumerator rather than a counter variable, so the ordinals stay
          # consecutive ACROSS pieces without a mutable local threaded through
          # two methods.
          ordinals = (1..).each
          rebuild(@pieces.zip(@detected).map do |piece, found|
            piece && redact(piece.text, found.select { withheld.include?(_1.digest) }, ordinals)
          end)
        end

        private

        # Every spelling of "this block is text", and nil for anything else.
        # A bare String element and a Symbol `:text` key are both text and were
        # both silently unscanned before; nil now refuses the result rather than
        # letting it through unmasked.
        #
        # The KEY is carried, not just the text, because writing the masked text
        # back under a hardcoded `"text"` beside an existing `:text` leaves the
        # original -- the secret survives in the same Hash, one key over. Caught
        # by the Symbol-key example, which is exactly why it exists.
        def piece_of(block)
          return Piece.new(text: block, key: nil) if block.is_a?(String)
          return nil unless block.is_a?(Hash)

          key = [TEXT, TEXT.to_sym].find { block[_1].is_a?(String) }
          Piece.new(text: block[key], key:) if key
        end

        # Regions are byte offsets into `piece.b` and {Sensitivity::Regions}
        # guarantees them ascending and non-overlapping, so one forward walk
        # rebuilds the file with each withheld span swapped for its placeholder.
        # The whole walk is in BINARY because an offset into re-decoded text is
        # a different offset; the original encoding is restored at the end, and
        # the placeholder is ASCII so it cannot invalidate it.
        def redact(piece, hidden, ordinals)
          bytes = piece.b
          cursor, parts = hidden.inject([0, []]) { |carry, region| swap(bytes, carry, region, ordinals) }
          (parts << bytes.byteslice(cursor..)).join.force_encoding(piece.encoding)
        end

        # The bytes kept since the previous region, then the placeholder that
        # stands in for this one -- carrying forward the offset just past it.
        def swap(bytes, (at, kept), region, ordinals)
          [region.start + region.length,
           kept + [bytes.byteslice(at, region.start - at), format(PLACEHOLDER, ordinals.next)]]
        end

        # Written back under the key it was READ from, never a hardcoded one --
        # see {#piece_of}. A nil key means the element WAS the String, so the
        # masked text replaces it outright.
        def rebuild(rendered)
          return rendered.first if @content.is_a?(String)

          @content.zip(rendered, @pieces).map do |block, text, piece|
            next_block(block, text, piece&.key)
          end
        end

        def next_block(block, text, key)
          return block unless text
          return text if key.nil?

          block.merge(key => text)
        end
      end
    end
  end
end
