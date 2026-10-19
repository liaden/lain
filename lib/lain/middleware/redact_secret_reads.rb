# frozen_string_literal: true

module Lain
  module Middleware
    # Masks the sensitive regions of a `read_file` result that nobody has agreed
    # to send, and parks an approval so somebody can.
    #
    # {RefuseSecretWrites}' mirror image, and the same rule turned around: the
    # only place a leak can be stopped is before the thing that remembers it. This
    # one rewrites `env[:result]` on the way OUT of the tool phase, so unreleased
    # bytes never exist above the middleware -- never in an {Event}, never in a
    # digest, never in the prompt-cache prefix.
    #
    # == Why this boundary exists when the path boundary already refused
    #
    # {Sensitivity::Policy} judges a PATH before the read, which is the only thing
    # it can judge -- content is not knowable until the bytes are in hand. So this
    # is the one boundary that can see a secret in a file classified ORDINARY: a
    # `.env` copied to `notes.txt`, a key pasted into a fixture, a token committed
    # to a spec. A path rule structurally cannot catch those.
    #
    # == Masking always comes with a release path
    #
    # An arm that only masked would leave the agent reading `Cargo.lock`, getting
    # `<redacted:1>` forever, with no move available to model or human. So when
    # anything would be masked this parks a {Approval::Queue::Pending} and awaits
    # it; the fail-closed default is the queue's own and is not reimplemented
    # here. An unreleased region renders as `<redacted:N>` and a released one as
    # its real bytes, so the model keeps the file's STRUCTURE and partial approval
    # falls out for free.
    #
    # == The ordinal in the placeholder is not the region's length
    #
    # `N` counts masked regions in reading order, so three masked values render as
    # three distinguishable placeholders and the model can say which one it needs.
    # The obvious alternative -- the byte length withheld -- would disclose how
    # long the secret is, which is a fact about the secret. The ordinal discloses
    # only how many there are, which the prompt already tells the human.
    #
    # == It never short-circuits, and it never lets a raise escape
    #
    # {Base#downstream} runs first and the merge happens afterwards, so `:result`
    # is always set by the tool and only ever REPLACED here.
    #
    # Keeping that true needs an explicit rescue, which pure masking did not:
    # {#settle} AWAITS a human. A raise from here escapes into
    # {Agent::ToolRunner}, which has already committed the `tool_use` -- so the
    # turn ends with a tool_use no tool_result answers, the state machine wedges
    # at `awaiting_tools`, and every later turn is a 400 from the real API.
    # {Provider::Mock} accepts that shape, which is why no spec would show it. The
    # rescue answers with an ERROR result and never with the bytes.
    #
    # == Detection is not size-capped, deliberately
    #
    # {Sensitivity::Regions} costs ~0.22ms/KB, linearly, with no blowup on
    # adversarial input, and hands the cap decision to whichever arm holds the
    # bytes. This one declines: a cap has two shapes and both are worse than the
    # cost -- scan a prefix and the tail ships unmasked, a leak the size of the
    # file; refuse the read outright and a legitimate large file becomes
    # unreadable with no move. A megabyte costs ~0.2s once, before anything parks.
    # If a cap is ever taken it must come back through `complete: false`, or every
    # read past it forgets its releases and re-prompts forever.
    #
    # == A command's output masks on every call, with no release
    #
    # A `bash` result names no file to key a release on, so its regions mask
    # whoever approved the call and nothing parks. The detector misses a secret
    # with no recognisable shape, so the value of every secret-named variable in
    # the process environment is masked wherever it appears too. The live pane
    # is masked for the same secrets by {Tools::Bash} as the command runs, so
    # the channel the pane and `lain://journal` read never carries them raw.
    #
    # == A memory item's body masks on every read, with no release
    #
    # A stored body names no file to key a release on, and its reader may be the
    # clerk, which no human watches, so it is masked as a command's output is.
    # The author line is lain's own and is left whole, as is a cited lineage
    # digest. The session remembers each item read masked, and
    # {RefuseSecretWrites} refuses to rewrite it from that read; a
    # {Telemetry::MemoryMasked} record carries that across a resume. The journaled `memory_loaded` copy stays
    # raw: masking it would move the item digests every resume checks.
    class RedactSecretReads < Base
      # Exact membership, {RefuseSecretWrites::GUARDED_TOOLS}' rule: a tool that
      # returns file bytes under some other name is unguarded by design until it
      # earns a place here. `bash` is masked as {COMMAND_TOOLS} and never parks:
      # what file `cat` read is the path boundary's question.
      GUARDED_TOOLS = Set["read_file"].freeze

      COMMAND_TOOLS = Set["bash"].freeze
      OUTPUT_TRAILER = "%<count>d %<noun>s masked in this command's output; a command's output cannot be released."

      # A row is a partial view, so its regions are masked and never parked: a park per
      # matched file would turn one search into a queue of prompts, and
      # `read_file` stays the way to ask.
      ROW_TOOLS = Set["grep", "ast_search"].freeze

      MEMORY_TOOLS = Set["memory_read"].freeze
      MEMORY_TRAILER = "%<count>d %<noun>s masked in this memory item; a memory item cannot be released."
      LINEAGE_DIGEST = /((?<![[:alnum:]:])blake3:\h{64}(?![[:alnum:]]))/

      SCANNED_TOOLS = [GUARDED_TOOLS, ROW_TOOLS, COMMAND_TOOLS, MEMORY_TOOLS].freeze

      # The provider content-block key this can read. Anything else in an Array
      # result is bytes this detector cannot see -- see {Scan}.
      TEXT = "text"

      # The key a guarded tool names its file under. Named rather than inline
      # because {TEXT} above is a different string that happens to look related.
      PATH_INPUT = "path"

      # The queue an unattended run does not wire. `--non-interactive` is its only
      # caller: {CLI::Switchboard#approvals} is nil there, and of the three answers
      # available -- full bytes, refuse, or mask with no release -- the last leaves
      # the model `<redacted:1>` forever with nobody able to answer.
      #
      # THIS IS A FAIL-OPEN, and the only one left in such a run: the SAME nil
      # `Switchboard#approvals` selects DENY at the gate and APPROVE at the
      # release. Its justification was that `--yolo` approved everywhere else; the
      # flag is gone and the behaviour stayed. Flipping it to deny is deferred to
      # its own measurement, because it changes what EVERY unattended run returns
      # for a sensitive read, and both halves are pinned together in
      # `cli/tool_guard_spec.rb` so the flip lands as a red example rather than a
      # lying comment.
      #
      # It is passed EXPLICITLY and `queue:` carries no default, so this cannot be
      # reached by forgetting an injection: what {Sensitivity::Ledger}'s no-Null
      # rule forbids is silent approval arriving by omission, not a named object
      # that approves on purpose.
      class Unqueued
        # What a release the stand-in approved is signed with, so the record of
        # what the fail-open sent names it rather than a surface nobody watched.
        SURFACE = "unqueued"

        Verdict = Data.define(:requester)

        # The messages this middleware reads off a settled
        # {Approval::Queue::Pending}: `approved?`, `timed_out?`, `surface`, `requester`.
        class Verdict
          def approved? = true
          def timed_out? = false
          def surface = SURFACE
        end

        # `outstanding:` is accepted and discarded, but cannot be renamed to the
        # unused-argument underscore: it is a KEYWORD, so the name is the duck.
        def adjudicate(_effect, context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
          Verdict.new(requester: Approval::Queue.requester_for(context))
        end

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # Where no `related:` is wired, nothing is related, so every flagged
      # region still asks.
      module Unrelated
        def self.related?(_path) = false
      end

      # The contract the required `ledger:` keeps, named so the raise below and
      # the doc above it cannot drift into two different arguments.
      LEDGER_CONTRACT = "the run has ONE region ledger, built on the Switchboard and injected -- " \
                        "a second one holds releases nobody ever sees"

      # {LEDGER_CONTRACT}'s sibling, and it names the approval OUT LOUD. This
      # message is read at exactly the moment somebody is hunting for a value to
      # inject, so "pass Unqueued" on its own would read as an instruction to open
      # the run's one fail-open without saying that is what it does.
      QUEUE_CONTRACT = "pass Middleware::RedactSecretReads::Unqueued where a run wires none -- " \
                       "but it APPROVES every release; see its docstring"

      # Readable for {Agent::ToolRunner#handler}'s reason, plus one: the wiring
      # spec has to be able to assert IDENTITY -- that this holds the board's one
      # ledger and the board's one queue, not a second of either. Asserting on
      # behaviour instead cannot tell a fresh ledger from the board's, which is
      # exactly the mutation that survived review.
      attr_reader :ledger, :queue, :journal, :related, :child_env

      # @param ledger [Sensitivity::Ledger] the run's ONE region ledger.
      #   REQUIRED, with no default and no Null Object: a default is how a
      #   second ledger gets constructed in silence, and a Null would answer
      #   "nothing outstanding" forever -- a release control that releases
      #   everything, wearing this codebase's Null idiom as camouflage.
      # @param queue [#adjudicate] where a read parks for release, or
      #   {Unqueued} when a run wires none. Required for the same reason.
      # @param journal [#<<] where {Telemetry::ReadRedacted},
      #   {Telemetry::SearchRedacted} and {Telemetry::ReadReleased} land
      # @param requester [String, nil] the child a read is asked for, as its
      #   gate names it; nil for the parent, whose context names nobody
      # @param related [#related?] answers whether an absolute path lies under
      #   a `sensitivity related:` directory, whose regions mask without asking.
      #   A default is safe here, unlike the two above: the default asks.
      # @param child_env [Exec::ChildEnv] the launch's child environment, read on
      #   every command result for the values of secret-named variables, beside
      #   the calling worker's own
      # @raise [ArgumentError] on a nil ledger or queue
      def initialize(ledger:, queue:, journal: Channel::Null.instance, requester: nil, related: Unrelated,
                     child_env: Exec::ChildEnv::DEFAULT)
        # A missing KEYWORD is Ruby's error; a nil VALUE is not, and nil is
        # exactly what `Switchboard#approvals` carries in an unattended run -- so
        # without this the argument that "no default means no silent approval"
        # rests on nobody ever passing the value the wiring actually holds.
        raise ArgumentError, "a ledger is required: #{LEDGER_CONTRACT}" unless ledger
        raise ArgumentError, "a queue is required: #{QUEUE_CONTRACT}" unless queue

        @ledger = ledger
        @queue = queue
        @journal = journal
        @requester = requester
        @related = related
        @child_env = child_env
        # Mutable, on a frozen object, deliberately: `freeze` seals the ivars,
        # not the Set they point at, and this is the run's accumulating
        # answer-memory -- {Sensitivity::Ledger}'s own posture, for its reason.
        @declined = Set.new
        # The subset of `@declined` nobody answered, so a later read can still say the window lapsed.
        @lapsed = Set.new
        # Kept apart from `@declined` because a row mask is not a ruling: a
        # file masked in a search must still park on its next `read_file`. Two
        # parallel searches can both journal the same mask, the race
        # `@declined` accepts for its extra prompt.
        @row_masked = Set.new
        super()
        freeze
      end

      Withheld = Data.define(:session, :path, :scan, :unreleased)

      # What one masking decision needs to carry, so the collaborators it touches
      # do not become five parameters on every method.
      class Withheld
        def found = scan.regions.length

        # Counts, never bytes -- what {Telemetry::ReadRedacted} carries.
        #
        # DERIVED from the snapshot and NOT re-asked of the ledger: `unreleased`
        # is captured BEFORE the park and the ledger is read AFTER it, with a human
        # await in between and {Tools::ReadFile#parallel_safe?} siblings in the
        # same reactor. Measured with two concurrent reads, one approved and one
        # denied, the ledger form reports `released: 1` for the read that masked
        # the region and sent nothing.
        #
        # This record describes ONE read, so the snapshot it acted on is what it
        # must report. The ledger answers "what does the run believe now", and
        # writing that here puts a false entry inside the very count
        # {Telemetry::Carriers::ReadRedacted}'s `released <= regions` validator
        # exists to keep honest.
        def released = found - unreleased.length
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        carried = downstream(env, &app)
        return carried unless SCANNED_TOOLS.any? { _1.include?(effect.name) }

        guarded(carried, effect)
      end

      private

      # `Async::Stop` is deliberately NOT rescued: it is not a StandardError, and
      # a stopped requester must keep unwinding. {#settle}'s `ensure` is what
      # makes that safe -- it has already recorded the mask by the time the stop
      # passes through here.
      def guarded(carried, effect)
        result = carried.fetch(:result)
        # A failed command can still quote what it printed.
        return printed(carried, result) if COMMAND_TOOLS.include?(effect.name)
        # A failed read carries a message, never file bytes, so there is nothing
        # here to mask and no read to record.
        return carried if result.error?
        return recalled(carried, effect, result) if MEMORY_TOOLS.include?(effect.name)
        return searched(carried, effect, result) if ROW_TOOLS.include?(effect.name)

        adjudicate(carried, effect, result)
      rescue StandardError => e
        # The CLASS only. An exception's message can quote the input that
        # produced it, and the input here is a file full of the bytes this class
        # exists to withhold.
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
        # drops the releases for regions the file no longer holds -- so asking it
        # about a view we are about to refuse would forget releases for regions
        # nobody looked at, and re-prompt for them forever after.
        return unreadable(carried, effect) unless scan.readable?

        withheld = withheld_in(carried, effect, scan)
        return carried unless withheld.unreleased.any?
        return mask(carried, effect, withheld, remembered(withheld)) if remembered(withheld)

        settle(carried, effect, withheld)
      end

      def printed(carried, result)
        text, count = text_mask(carried).call(result.text)
        return carried unless count.positive?

        masked = carried.merge(result: Tool::Result.new(content: with_trailer(text, count), is_error: result.error?))
        record(Telemetry::CommandRedacted) do
          Telemetry::CommandRedacted.new(tool_use_id: carried.fetch(:effect).tool_use_id, regions: count)
        end
        masked
      end

      def recalled(carried, effect, result)
        author, body = result.text.split("\n", 2)
        text, count = recalled_body(text_mask(carried), body.to_s)
        return carried unless count.positive?

        (carried.fetch(:context) || Session::Null.instance).record_masked_memory(effect.input["id"])
        record(Telemetry::MemoryMasked) do
          Telemetry::MemoryMasked.new(tool_use_id: effect.tool_use_id, id: effect.input["id"], regions: count)
        end
        carried.merge(result: Tool::Result.ok("#{author}\n#{with_trailer(text, count, MEMORY_TRAILER)}"))
      end

      # A lineage digest is the evidence a clerk is asked to cite, and the
      # entropy detector would take it for a token, so the text around each one
      # is masked and the digest is kept, with one numbering across the pieces.
      def recalled_body(mask, body)
        ordinals = (1..).each
        body.split(LINEAGE_DIGEST).each_slice(2).inject(["", 0]) do |(text, count), (piece, digest)|
          masked, spans = mask.mask(piece, ordinals)
          [text + masked + digest.to_s, count + spans]
        end
      end

      def text_mask(carried) = ::Lain::Sensitivity::TextMask.new(secrets: session_secrets(carried.fetch(:context)))

      def with_trailer(text, count, trailer = OUTPUT_TRAILER)
        lead = text.end_with?("\n") ? text : "#{text}\n"
        lead + format(trailer, count:, noun: count == 1 ? "region was" : "regions were")
      end

      def session_secrets(context)
        lent = (context || Session::Null.instance).worker_env.env
        ::Lain::Sensitivity::Literals.new(child_env: @child_env, lent:).to_a
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
      # the ledger has by construction seen every byte, which is what makes the
      # reconcile inside `outstanding` sound.
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
      # different answer without a human doing something the model cannot prompt
      # for, and each re-ask costs another full timeout window -- 300 seconds by
      # default -- so a model told to re-read a denied file turns one refusal into
      # an unbounded series of five-minute stalls. A TIMEOUT counts as a decline:
      # nobody answered.
      #
      # Run-scoped and add-only, so the worst it can do is mask something a human
      # would have released. Two sibling fibers can both park for the same digests
      # (the check and the record sit either side of the await), which costs one
      # extra prompt and nothing else.
      def declined?(withheld) = withheld.unreleased.all? { @declined.include?([withheld.path, _1.digest]) }

      # Why a read is masked without asking, or nil when it must ask.
      def remembered(withheld)
        return (lapsed?(withheld) ? :timed_out : :declined) if declined?(withheld)

        :related if @related.related?(withheld.path)
      end

      def lapsed?(withheld) = withheld.unreleased.all? { @lapsed.include?([withheld.path, _1.digest]) }

      # The await is the only place in this class that can be unwound from
      # outside, and the read-set is already wrong when it is.
      #
      # {Tools::ReadFile} recorded a COMPLETE read below this middleware before
      # the park began, and `@masked` is add-only, so if control leaves here
      # without a verdict nothing later repairs it: `read?` stays true,
      # `masked_read?` stays false, and `edit_file` is ALLOWED over a file whose
      # secrets the model never saw -- fail-OPEN, in the one direction this exists
      # to prevent, and a Ctrl-C at the prompt is enough to reach it.
      #
      # `ensure`, gated on a DECISION rather than on the call returning, because
      # both halves can be skipped: a surface that raises unwinds `adjudicate`
      # itself, and a requester stopped mid-park raises `Async::Stop`, which no
      # rescue sees. Gating on `settled` alone would miss a duck whose `approved?`
      # raises. Recording the mask up front and retracting it on approval is not
      # available: `@masked` has no removal, by {Session::ReadSet}'s design.
      def settle(carried, effect, withheld)
        outstanding = Approval::Queue::Outstanding.new(path: withheld.path, regions: withheld.unreleased)
        decided = false
        settled = @queue.adjudicate(effect, asked(carried.fetch(:context)), outstanding:)
        approved = settled.approved?
        decided = true
        return release(carried, effect, withheld, settled) if approved

        why = settled.timed_out? ? :timed_out : :declined
        withheld.unreleased.each { @lapsed << [withheld.path, _1.digest] } if why == :timed_out
        mask(carried, effect, withheld, why)
      ensure
        withheld.session.record_masked_read(withheld.path) unless decided
      end

      # One queue serves the whole fleet, so a child's read names the child
      # through the context, as the child's gate does.
      def asked(context) = @requester ? Approval::PolicySwitch::Requested.new(context, @requester) : context

      # Nothing was withheld, so no mask is recorded. What is journaled is that
      # a secret was sent: the decision record names no file and no count, and a
      # {Telemetry::ReadRedacted} would resume the file as masked.
      def release(carried, effect, withheld, settled)
        @ledger.release(withheld.path, withheld.unreleased)
        record(Telemetry::ReadReleased) do
          Telemetry::ReadReleased.new(tool_use_id: effect.tool_use_id, path: withheld.path,
                                      regions: withheld.unreleased.length, requester: settled.requester,
                                      surface: settled.surface)
        end
        carried
      end

      # Journaled on a STATE TRANSITION, not on a call -- {Session#record_read}'s
      # rule, which this has to match or break. A redaction line per read would
      # mean an unmasked file journals once over ten iterations and a masked one
      # ten times, so the record would be noisiest exactly where the loop is most
      # likely. `@declined` already holds "these
      # digests at this path have been ruled on", which IS the transition, so the
      # check goes BEFORE it is added to.
      def mask(carried, effect, withheld, why)
        withheld.session.record_masked_read(withheld.path)
        record(Telemetry::ReadRedacted) { redaction(effect, withheld) } unless declined?(withheld)
        withheld.unreleased.each { @declined << [withheld.path, _1.digest] }
        masked = withheld.scan.mask(withheld.unreleased)
        carried.merge(result: Tool::Result.ok(Trailer.append(masked, withheld.unreleased.length, why)))
      end

      # `complete: false`, because a row is a partial view: a complete reconcile
      # would drop the releases for every region the rows do not show.
      def searched(carried, effect, result)
        rows = rows_in(carried, effect, result.content)
        found = rows.regions
        unreleased = found.to_h { |path, regions| [path, @ledger.outstanding(path, regions, complete: false)] }
        return carried if unreleased.values.all?(&:empty?)

        record_row_masks(effect, found, unreleased)
        carried.merge(result: Tool::Result.ok(rows.mask(unreleased)))
      end

      def rows_in(carried, effect, content)
        cwd = (carried.fetch(:context) || Session::Null.instance).worker_env.cwd
        Rows.new(content, base: Session.normalize_path(effect.input[PATH_INPUT], cwd:), cwd:)
      end

      # {#mask}'s state-transition rule, over a set of its own so that nothing
      # here reads as a ruling to the next `read_file`. A {Telemetry::SearchRedacted},
      # never a {Telemetry::ReadRedacted}, so a resume does not fold it into a mask.
      def record_row_masks(effect, found, unreleased)
        unreleased.reject { |path, held| row_masked?(path, held) }.each do |path, held|
          record(Telemetry::SearchRedacted) do
            Telemetry::SearchRedacted.new(tool_use_id: effect.tool_use_id, path:, regions: found[path].length,
                                          released: found[path].length - held.length)
          end
          held.each { @row_masked << [path, _1.digest] }
        end
      end

      def row_masked?(path, held)
        held.all? { |region| [@row_masked, @declined].any? { _1.include?([path, region.digest]) } }
      end

      def redaction(effect, withheld)
        Telemetry::ReadRedacted.new(tool_use_id: effect.tool_use_id, path: withheld.path,
                                    regions: withheld.found, released: withheld.released)
      end

      # Evidence about a turn must never be able to COST the turn: the mask has
      # already happened, so a closed Journal or a full disk must not convert a
      # correctly-masked read into the error result {#guarded}'s rescue produces.
      #
      # It is not silent either: a lost release is a secret sent with no record
      # of it, so the failure degrades into the Journal's own `journal_error`
      # shape, naming the record it stood in for, as {Approval::Queue} does. A
      # lost mask costs a resumed session the knowledge that the path was masked,
      # since {SessionRecord::Replay#redactions} reads this record; the LIVE
      # session still knows.
      #
      # The entry is built in the block, so a record whose own construction
      # raises degrades here too rather than escaping past this rescue. `kind`
      # names it, because a raise mid-construction leaves no instance to name.
      def record(kind)
        @journal << yield
      rescue StandardError => e
        degrade(kind, e)
      end

      # When even the degraded write fails there is nowhere left to say so.
      def degrade(kind, error)
        @journal << { "type" => "journal_error", "error" => "#{error.class}: #{error.message}",
                      "entry_class" => kind.name }
      rescue StandardError
        nil
      end

      # The detector's view of one {Tool::Result}'s content, and the masked
      # rendering of it.
      #
      # `content` is a String or an Array of provider content blocks, so "the
      # file's bytes" is not one thing, and the difference is decided here rather
      # than papered over with a `to_s` that would corrupt a legitimate result. A
      # String IS the whole file. An Array is a partial view: its text blocks are
      # readable and everything else -- an image, a document -- is bytes this
      # detector structurally cannot see.
      #
      # `read_file` returns a String today, so the Array arm is unexercised in
      # production. It is here because the arm that guesses ships a corrupted
      # result the first time a tool returns blocks. An earlier edition guessed
      # wrong: a text block spelled any way it did not recognise (a Symbol `:text`
      # key, a bare String element, text nested a level down) produced no regions,
      # and a result with no regions takes the early return -- so the bytes went to
      # the model unmasked with nobody asked. Fail-open, in the class whose whole
      # purpose is the opposite.
      #
      # So {#readable?} is the question now, and an Array carrying anything this
      # cannot read is REFUSED. Deliberately loud and deliberately inconvenient:
      # whoever first makes a guarded tool return image or document blocks has to
      # decide what masking means for them, which is not a decision this class may
      # make silently on their behalf.
      class Scan
        # A piece of scannable text, and the key it has to be written back under.
        # `key` is nil when the block IS the String, so there is nothing to merge
        # into.
        Piece = Data.define(:text, :key)

        def initialize(content)
          @content = content
          @pieces = content.is_a?(String) ? [Piece.new(text: content, key: nil)] : content.map { piece_of(_1) }
          @detected = @pieces.map { |piece| piece && ::Lain::Sensitivity::Regions.detect(piece.text) }
          freeze
        end

        # Whether every piece of this content is text this could scan. False means
        # the result must not be sent at all: there is no "scan the part I
        # understood and forward the rest", because the rest is what would carry
        # the secret out.
        #
        # It replaced a `complete?` that answered the ledger's narrower "did I see
        # the whole file?" and then let an incomplete scan through anyway. Once an
        # unreadable result is refused outright the two questions collapse into
        # this one, and the ledger is always told `complete: true`, truthfully.
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

        # Every spelling of "this block is text", and nil for anything else. A
        # bare String element and a Symbol `:text` key are both text and were both
        # silently unscanned before; nil now refuses the result rather than
        # letting it through unmasked.
        #
        # The KEY is carried, not just the text, because writing the masked text
        # back under a hardcoded `"text"` beside an existing `:text` leaves the
        # original -- the secret survives in the same Hash, one key over.
        def piece_of(block)
          return Piece.new(text: block, key: nil) if block.is_a?(String)
          return nil unless block.is_a?(Hash)

          key = [TEXT, TEXT.to_sym].find { block[_1].is_a?(String) }
          Piece.new(text: block[key], key:) if key
        end

        # The masked rendering is {Sensitivity::Masking}'s, and this class owns
        # only the piece bookkeeping around it: {Survey::Projection} withholds
        # regions too, and two walks over the same byte offsets is how the read
        # path and a survey would drift on what a masked file looks like.
        # `ordinals` is threaded through so the numbering stays consecutive ACROSS
        # the pieces of one result.
        def redact(piece, hidden, ordinals) = ::Lain::Sensitivity::Masking.render(piece, hidden, ordinals:)

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

      # What a masked read tells the model: the file is readable, so a refusal is not
      # a missing file, and the human is the one who can lift it.
      module Trailer
        REASONS = { declined: "the release was declined", timed_out: "the release timed out",
                    related: "it lies under a related directory, whose regions are never released" }.freeze

        # @param content [String, Array] the masked result, shaped as it arrived
        # @param count [Integer] regions withheld
        # @param why [Symbol] a key of {REASONS}
        def self.append(content, count, why)
          text = line(count, why)
          content.is_a?(String) ? "#{content}\n#{text}" : [*content, { "type" => "text", "text" => text }]
        end

        def self.line(count, why)
          "#{placeholders(count)}. The file is inside the project and readable; #{REASONS.fetch(why)}. " \
            "Tell the user which file you need unmasked."
        end

        def self.placeholders(count)
          return "1 region is masked as <redacted:1>" if count == 1

          "#{count} regions are masked as <redacted:1> to <redacted:#{count}>"
        end

        private_class_method :line, :placeholders
      end

      # A directory target labels a row relative to the walked root and a file
      # target with the model's own spelling, so a row's file is its label
      # resolved against the root or the worker's cwd: the key `read_file` uses.
      class Rows
        TRAILER = "%<count>d %<noun>s masked: read_file on a file may ask for the release of its regions. " \
                  "A multi-line secret, such as a PEM body, cannot be detected one line at a time " \
                  "and is not masked here."

        Span = Data.define(:start, :length)

        # Byte offsets, because {Sensitivity::Masking} walks a row as bytes.
        class Span
          def finish = start + length

          def reaches?(other) = other.start <= finish

          def |(other) = Span.new(start:, length: [finish, other.finish].max - start)
        end

        Row = Data.define(:prefix, :text, :path, :regions)

        # A region masks where it was found. Its bytes can recur in the row: an
        # ast_search capture quotes the matched value, escaped as `inspect`
        # escapes it, and a key-only shape is not found again there because the
        # capture does not repeat the key. Only a value of substance is sought
        # again, since a short one recurs in ordinary words and the placeholders
        # would spell it back out.
        class Row
          # @return [Array(String, Integer)] the row as sent, and how many placeholders it holds
          def masked(unreleased, ordinals)
            spans = spans(unreleased)
            [prefix + ::Lain::Sensitivity::Masking.render(text, spans, ordinals:), spans.size]
          end

          private

          def spans(unreleased)
            withheld = unreleased.to_set(&:digest)
            found = regions.select { withheld.include?(_1.digest) }.map { Span.new(start: _1.start, length: _1.length) }
            coalesced(found + recurrences(unreleased))
          end

          def recurrences(unreleased)
            haystack = text.b
            unreleased.map(&:bytes).select { _1.bytesize >= ::Lain::Sensitivity::Regions::SUBSTANCE_LENGTH }
                      .flat_map { spellings(_1) }.uniq.flat_map { occurrences(haystack, _1) }
          end

          def spellings(bytes) = [bytes.b, String.new(bytes, encoding: Encoding::UTF_8).inspect[1..-2].b]

          def occurrences(haystack, needle)
            Enumerator.produce(haystack.byteindex(needle)) { haystack.byteindex(needle, _1 + needle.bytesize) }
                      .take_while(&:itself).map { Span.new(start: _1, length: needle.bytesize) }
          end

          # Masking walks ascending, non-overlapping spans, and an escaped
          # spelling can overlap a raw one.
          def coalesced(spans)
            spans.sort_by(&:start).inject([]) do |kept, span|
              kept.last&.reaches?(span) ? [*kept[..-2], kept.last | span] : [*kept, span]
            end
          end
        end

        Line = Data.define(:text)

        # A cap or skip trailer names no file, so there is nothing in it to key.
        class Line
          def path = nil

          def masked(_unreleased, _ordinals) = [text, 0]
        end

        # @param content [String] the tool's rows, newline-joined
        # @param base [String] the search target, resolved
        # @param cwd [String] the worker's cwd, against which a file target's label resolves
        def initialize(content, base:, cwd:)
          @directory = File.directory?(base)
          @anchor = @directory ? base : cwd
          @base = base
          @rows = content.split("\n", -1).map { row_of(_1) }
          freeze
        end

        # @return [Hash{String => Array<Sensitivity::Regions::Region>}] every region per file, in row order
        def regions = matches.group_by(&:path).transform_values { |rows| rows.flat_map(&:regions) }

        # @param unreleased [Hash{String => Array<#digest>}] the regions to withhold, per file
        # @return [String] the rows with those regions masked, and the trailer saying so
        def mask(unreleased)
          ordinals = (1..).each
          rendered = @rows.map { _1.masked(unreleased.fetch(_1.path, []), ordinals) }
          masked = rendered.count { |(_, placeholders)| placeholders.positive? }
          [*rendered.map(&:first), format(TRAILER, count: masked, noun: masked == 1 ? "row was" : "rows were")]
            .join("\n")
        end

        private

        def matches = @rows.grep(Row)

        # A row whose file cannot be found keys on its first reading, so it still masks.
        def row_of(text)
          fields = text.split(Middleware::WithholdSecretPaths::Matches::SEPARATOR, -1)
          labels = Middleware::WithholdSecretPaths::MATCHES.paths_in(text)
          return Line.new(text:) if labels.empty?

          label = labels.find { file?(resolved(_1)) } || labels.first
          at = label.count(Middleware::WithholdSecretPaths::Matches::SEPARATOR) + 2
          text = fields.drop(at).join(":")
          Row.new(prefix: "#{fields.take(at).join(":")}:", text:, path: resolved(label),
                  regions: Scan.new(text).regions)
        end

        def resolved(label) = Session.normalize_path(label, cwd: @anchor)

        def file?(path) = @directory ? File.file?(path) : path == @base
      end
    end
  end
end
