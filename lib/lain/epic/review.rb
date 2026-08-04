# frozen_string_literal: true

module Lain
  module Epic
    # The ownership baton for one epic's artifacts. While a human holds a
    # document, lain does not write it; when they hand it back, exactly one
    # awaiting fiber learns what they did to it.
    #
    # == One generation, one promise, no shared ivar
    #
    # {#open} answers a {Token} carrying a FRESH {Lain::Promise}, and the open
    # set is keyed by generation. This is the asker {Tools::AskHuman}'s doc has
    # in mind when it says an asker who asks concurrently must carry its promises
    # on events rather than on an ivar: two reviews are open whenever two agents
    # review two artifacts, and one ivar would resolve the wrong one in silence.
    #
    # The generation is what makes a LATE answer harmless -- the bargain
    # {Frontend::Neovim::Compose} strikes with its own counter. The editor stamps
    # the number on the review buffer and hands it back with `done`, so a buffer
    # left over from a settled or a dead review names a generation this object
    # refuses.
    #
    # == A generation names a review WITHIN one epic
    #
    # The identity is the PAIR `(epic_slug, generation)`, and a settle route must
    # carry both. Numbers are drawn from this epic's own records, so two live
    # Reviews sharing one journal -- one per epic slug, which is what a session
    # builds -- both hand out 1. A bare integer off the wire cannot say which
    # review it means, and there is deliberately no shared counter to make it
    # able to: a counter every construction site must remember to pass is a
    # collision waiting to happen quietly, where a route that must name its epic
    # cannot forget.
    #
    # Within one epic the numbers are unique over the WHOLE journal, opened and
    # closed alike, so the open set and the settled set can never overlap and a
    # `done` gesture is answered rather than misrouted.
    #
    # == Paths are ABSOLUTE here, and that is a decision
    #
    # {#open?} is the duck {Home::Journaled} asks before every write, and it is
    # asked with {Home::Artifact#path} -- the absolute path. So the open set is
    # keyed on absolute paths, and {ReviewOpened} journals the same string: the
    # record is what {.from_journal} rebuilds the set from, and a relative path
    # there would rebuild a baton no `open?` could match. {ReviewOpened} says
    # what that costs and what carries the durable join instead.
    #
    # == Nothing here blocks a thread
    #
    # {#open} and {#settle} both return at once; the only parking is a caller's
    # own `token.await`, which parks that FIBER inside its reactor. A review
    # rebuilt from the journal has no promise at all and says so loudly rather
    # than parking anyone ({Unpromised}) -- promises are process-local
    # coordination and deliberately do not survive a restart.
    class Review
      # The generation is not open: never opened here, or already settled. One
      # refusal because a caller does the same thing with both -- tell the human
      # their `done` gesture found nothing -- and one message that says which.
      class NotOpen < Error; end

      # A second opener for a path someone already holds. Refused rather than
      # queued: the second generation would shadow the first, and the first's
      # awaiting fiber would then wait for a settle that can never name it.
      class AlreadyOpen < Error; end

      # Constructed and handed to {Intake::Delta.malformed}, never raised: it is
      # the `error_kind` a rebuilt review's settlement wears, so a consumer can
      # tell "the journal did not keep the bytes" from a grammar or graph refusal
      # without matching message text -- which is what that member is for.
      class Unrecoverable < Error; end

      # Constructed and handed to {ReviewClosed}, never raised: it is the
      # `error_kind` an ABANDONED review closes with, so a reader can tell a
      # hand-over that never happened from one that came back malformed. See
      # {#abandon} for when that is the honest record.
      class Abandoned < Error; end

      class NoPromise < Error; end

      # The promise a review rebuilt from the journal does not have.
      #
      # Null on the path that must not care: {#resolve} sends the delta nowhere,
      # so {Review#settle} never asks whether a promise exists and a restarted
      # review settles rather than wedging forever. LOUD on the path that has no
      # honest null: there is no value to await and no fiber to wake, so {#await}
      # says so instead of parking a caller nothing will ever resolve.
      module Unpromised
        def self.resolve(_delta) = nil

        def self.resolved? = false

        def self.await
          raise NoPromise, "this review was rebuilt from the journal, which records THAT it is open and not " \
                           "who was waiting -- a promise is process-local and does not survive a restart"
        end
      end

      # What the disk is compared against: the document lain wrote, held whole
      # so that {Intake} can answer both of its registers over it.
      class Baseline
        def initialize(written)
          @written = written
        end

        def delta(disk) = Intake.diff(written: @written, disk:)
      end

      # The same duck for an artifact that is PROSE -- research and the issue
      # plan, which are written to be read rather than resolved -- where there
      # is no graph on either side and so nothing structural to say.
      #
      # The delta is MEASURED on bytes and UNCOMPARED structurally. Both
      # addresses and the truncation suspicion are exactly as answerable over
      # prose as over an epic document, because both are byte measures; the
      # account is empty because no comparison was MADE.
      #
      # It carries NO error, and that is what separates it from {Recalled},
      # whose account is empty for the same shape of reason. Nothing failed
      # here. Prose is deliberately never parsed: {Document.parse_markdown} over
      # a research note refuses it, and reporting a human's ordinary prose as a
      # malformed epic would be a false alarm about their work rather than a
      # report of it.
      #
      # So an empty account now means one of three things, and `error_kind` --
      # nil, {Unrecoverable}, or a grammar refusal -- is what tells them apart.
      class ProseBaseline
        def initialize(written)
          @written = written
        end

        def delta(disk)
          Intake::Delta.new(written_digest: @written.byte_digest, disk_digest: Intake.byte_digest(disk),
                            account: Intake::Account.empty, lossy: Intake.lossy?(@written.bytes, disk),
                            error: nil, error_kind: nil)
        end
      end

      # The same duck for a review rebuilt from the journal, which recorded the
      # written document's DIGESTS and not its bytes.
      #
      # So nothing can be compared, and the honest report of that is the delta
      # {Intake} builds when a parse fails: both byte addresses on record, and an
      # account that is empty because no comparison was MADE rather than because
      # the sides agreed -- `malformed?` is what tells those two apart.
      #
      # It is NOT a corrupt file, and a surface must never render it as one. The
      # true sentence is "lain restarted and no longer holds what it wrote";
      # `error_kind` is {Unrecoverable} exactly so a renderer can say that.
      #
      # `lossy: false` here is UNMEASURED, not measured false: the suspicion is a
      # ratio against the written bytesize, which the record does not carry.
      class Recalled
        NOTHING_TO_COMPARE = "this review was rebuilt from the journal, which records the digests of the " \
                             "document lain wrote and not its bytes -- the disk is on record, but nothing " \
                             "could be compared against it"

        def initialize(written_digest)
          @written_digest = written_digest
        end

        def delta(disk)
          Intake::Delta.malformed(Unrecoverable.new(NOTHING_TO_COMPARE),
                                  written_digest: @written_digest, disk_digest: Intake.byte_digest(disk),
                                  lossy: false)
        end
      end

      # The live half of a `review_opened` record: the generation the editor
      # stamps on its buffer, the file that is held, what to compare the disk
      # against, and the promise the asker parks on.
      #
      # Mutable, like {Approval::Queue::Pending} and unlike every frozen value in
      # this unit: a promise exists to be resolved. {Review#open} returns the
      # same object it keeps, so a caller's promise and settle's are one.
      class Token
        # Both halves of the identity, on one object. A settle route has to name
        # `(epic_slug, generation)` -- a bare number cannot say which review it
        # means -- and a token that carried only the number would leave the slug
        # to be remembered BESIDE it at every construction site, which is the
        # forget-and-misroute failure the pair exists to rule out.
        # `written_digest` rides here because it is a field of the very record
        # this object is the live half OF, and because a token that cannot name
        # the bytes lain wrote cannot describe its own close -- which is exactly
        # what {Review#abandon} needs when there is no disk read to describe it
        # with.
        attr_reader :epic_slug, :generation, :path, :written_digest

        def initialize(epic_slug:, generation:, path:, written_digest:, baseline:, promise:)
          @epic_slug = epic_slug
          @generation = generation
          @path = path
          @written_digest = written_digest
          @baseline = baseline
          @promise = promise
        end

        def delta(disk) = @baseline.delta(disk)
        def resolve(delta) = @promise.resolve(delta)
        def resolved? = @promise.resolved?
        def await = @promise.await
      end

      # The fold that rebuilds an open set from journaled records --
      # {Approval::SignoffQueue.from_journal}'s shape.
      class Replay
        TYPES = [ReviewOpened::JOURNAL_TYPE, ReviewClosed::JOURNAL_TYPE].freeze

        def initialize(entries, epic_slug:)
          @epic_slug = -epic_slug.to_s
          @open = {}
          @settled = Set.new
          records = mine(Journal.records(entries).to_a)
          @high_water = high_water_of(records)
          records.each { |record| fold(record) }
        end

        attr_reader :open, :settled, :high_water

        private

        # Over CLOSED claims as well as open ones, so the two sets cannot
        # overlap. A `review_closed` whose claim is gone -- rotated away, or torn
        # -- would otherwise leave its number free, and the next open would hand
        # out a generation that is simultaneously open and settled. This is the
        # read side of the same hazard {Review#open} closes by bumping its
        # counter before it journals.
        def high_water_of(records)
          [0, *records.map { |record| ReviewClaim.generation(record["generation"]) }].max
        end

        # A record naming ANOTHER epic is not ours and is dropped; one naming NO
        # epic is KEPT so its own guard refuses it below. {Progress::Refold}'s
        # rule, and for its reason: a filter that swallowed the unattributable
        # line would skip exactly the record that most needs refusing.
        def mine(records)
          records.select { |record| TYPES.include?(record["type"].to_s) && mine?(record) }
        end

        def mine?(record)
          slug = record["epic_slug"].to_s
          slug.strip.empty? || slug == @epic_slug
        end

        def fold(record)
          record["type"].to_s == ReviewOpened::JOURNAL_TYPE ? park(record) : release(record)
        end

        # Guarded on the same contract the WRITE side uses, so a record that
        # cannot be read whole aborts the rebuild rather than being skipped --
        # {Progress::Refold}'s rule again. Both ways of getting it wrong are
        # unsafe here: a skipped `review_opened` hands the baton back to lain
        # while a human still holds the file, and a claim rebuilt with a blank
        # path holds a baton no `open?` can ever release.
        #
        # Two claims on ONE path are folded in, not refused. {Review#open}'s
        # one-per-path rule guards a single live Review; a journal can still show
        # two, because two Reviews for one epic (a wiring error -- the contract is
        # one per slug) each guard only their own open set.
        #
        # Refusing that was a worse bug than the one it caught. The fold aborts
        # where it raises, so the refusal was judged against a PREFIX of the
        # journal: it went on raising after both claims had settled, and the
        # epic became permanently un-rebuildable -- the wedge this whole class
        # exists to prevent, arriving through the guard added to prevent it.
        #
        # So the doubled state is carried instead: {Review#open_generations}
        # holds the EARLIEST claim on a path and the path stays held until every
        # claim on it has released. That refuses regeneration for at least as
        # long as any refusal would have (the safe direction), it heals itself
        # as the claims settle, and a journal that is no longer inconsistent
        # rebuilds cleanly.
        #
        # The same argument covers a claim on a generation that already CLOSED,
        # which the same wiring error produces (both Reviews hand out 1, and
        # either may settle first). The journal's last word on that number is
        # that a human holds the file, so the fold says so and the baton stays
        # releasable; leaving it in the settled set as well would tell that human
        # their live review was already settled. There is no shape of journal
        # this fold refuses to finish, and that is the property to keep.
        def park(record)
          Guards::ReviewOpened.check!(**common(record), graph_digest: record["graph_digest"])
          generation = ReviewClaim.generation(record["generation"])
          @settled.delete(generation)
          @open[generation] = token(record, generation)
        end

        def token(record, generation)
          written_digest = record["written_digest"].to_s
          Token.new(epic_slug: @epic_slug, generation:, path: ReviewClaim.path(record["path"]),
                    written_digest:, baseline: Recalled.new(written_digest), promise: Unpromised)
        end

        def release(record)
          Guards::ReviewClosed.check!(**common(record),
                                      disk_digest: record["disk_digest"], changes: record["changes"],
                                      lossy: record["lossy"], error: record["error"],
                                      error_kind: record["error_kind"])
          generation = ReviewClaim.generation(record["generation"])
          @open.delete(generation)
          @settled << generation
        end

        # The four members both halves share, which is exactly what
        # {Guards::ReviewRecord} declares -- each half adds its own on top.
        def common(record)
          { epic_slug: record["epic_slug"], path: record["path"],
            generation: ReviewClaim.generation(record["generation"]), written_digest: record["written_digest"] }
        end
      end
      private_constant :Replay

      # Rebuild the open set from journaled claims, so a restarted process knows
      # a human is still holding a file, which generation releases it
      # ({#generation_for}), and therefore that it must not regenerate it. State
      # only: see {Unpromised} for why no promise comes back with it.
      #
      # == It fails OPEN, and a caller must know that
      #
      # {Journal.records} skips any line it cannot parse -- its fd is shared with
      # Rust tracing spans, so skipping foreign bytes is its contract rather than
      # a lapse. A `review_opened` line torn by a crash is therefore never seen
      # by the guard below: it is simply gone, the baton is LOST, and lain will
      # happily regenerate a file a human is mid-edit in. That is the outcome
      # this whole class exists to prevent, and the fold cannot close it from
      # here.
      #
      # So `open?(path) == false` is not proof that nobody is holding the file.
      # It means no readable claim says so. A surface that needs the stronger
      # statement has to get it from somewhere the journal's skip contract does
      # not reach.
      #
      # @param entries [Enumerable<Hash, String>] journal lines or records
      # @param journal [#<<] where {ReviewOpened} and {ReviewClosed} land
      # @param epic_slug [String] the epic whose artifacts this baton is for
      def self.from_journal(entries, journal:, epic_slug:)
        new(journal:, epic_slug:, replay: Replay.new(entries, epic_slug:))
      end

      # @param journal [#<<] where {ReviewOpened} and {ReviewClosed} land
      # @param epic_slug [String] the epic whose artifacts this baton is for
      # @param replay [Replay] the open/settled sets and high-water generation
      #   already folded from journal records; {.from_journal} builds one from
      #   raw entries, and the default replays nothing so a bare `new` starts
      #   empty.
      def initialize(journal:, epic_slug:, replay: Replay.new([], epic_slug:))
        @journal = journal
        @epic_slug = -epic_slug.to_s
        @open = replay.open
        @settled = replay.settled
        @generation = replay.high_water
      end

      # Hand a document to a human and take the baton for it.
      #
      # Journaled BEFORE the baton is held, which is {Approval::SignoffQueue}'s
      # order and buys its one-directional invariant: nothing is ever held
      # without a record behind it, so a crash between the two refuses a write
      # the record would also have refused. The other order loses the claim.
      #
      # @param path [String] the artifact's ABSOLUTE path -- the same string
      #   {Home::Journaled} asks {#open?} about
      # @param written [Intake::Written] the bytes and graph lain last wrote
      # @return [Token] the generation an editor stamps and the promise to await
      # @raise [AlreadyOpen] if somebody already holds this path
      def open(path:, written:)
        # Through the record's own normalization, so a path held live and the
        # same path rebuilt from the record are one string. They diverged once
        # (one side stripped, the other did not), and the symptom of that is the
        # worst one this class has: a guard that silently stops guarding.
        path = ReviewClaim.path(path)
        refuse_second_opener!(path)
        # The counter advances BEFORE the record, so a journal write that raises
        # burns a generation rather than leaving the next open free to reuse it.
        # A burned number costs nothing -- it simply never opens; a reused one
        # settles somebody else's review ({Frontend::Neovim::Compose}'s counter
        # is bumped before its RPC for the same reason).
        generation = (@generation += 1)
        @journal << ReviewOpened.new(epic_slug: @epic_slug, path:, generation:,
                                     written_digest: written.byte_digest, graph_digest: written.graph_digest)
        @open[generation] = Token.new(epic_slug: @epic_slug, generation:, path:,
                                      written_digest: written.byte_digest,
                                      baseline: baseline_for(written), promise: Promise.new)
      end

      # Whether anybody holds the baton for this path -- the whole of the duck
      # {Home::Journaled} depends on. See {.from_journal} for why a `false` from
      # a rebuilt Review is weaker than it looks.
      def open?(path) = !generation_for(path).nil?

      # WHICH generation releases this path, or nil when nobody holds it.
      #
      # The reader a restart needs: without it the rebuilt baton could be
      # observed ({#open?}) and never released, since {#settle} takes a
      # generation and the only other way to learn one is to re-fold the journal
      # by hand.
      def generation_for(path) = open_generations[ReviewClaim.path(path)]

      # Everything being held, as `path => generation` -- what a surface renders
      # when it has to tell a human which files they are still holding, and the
      # ONE place "who holds this path" is decided, so {#open?} and
      # {#generation_for} cannot answer it differently.
      #
      # `||=` keeps the EARLIEST claim when a rebuilt journal shows two on one
      # path (see {Replay#park}); a later one shadows nothing and releases
      # separately, so the path frees when the last of them settles.
      def open_generations
        @open.each_value.with_object({}) { |token, holders| holders[token.path] ||= token.generation }
      end

      # Take the baton back: compare what came back against what lain wrote,
      # journal the comparison, and hand the delta to whoever is waiting.
      #
      # The record lands BEFORE the promise resolves, so a fiber woken by the
      # delta can trust the settlement is already on record -- and before the
      # open set releases, so a journal write that raises leaves the review open,
      # which refuses a regeneration rather than allowing one.
      #
      # @param generation [Integer, String] the token's generation, as the editor
      #   hands it back; read through {WireInteger} exactly as the record reads
      #   it, so the wire's `"3"` and a token's `3` name one review and `"3junk"`
      #   names none
      # @param disk [String] the bytes found on disk now
      # @param annotations [Array<Hash>] the notes the human left, as the editor
      #   sends them ({Annotations} says what shape that is)
      # @return [Intake::Delta]
      # @raise [NotOpen] for a generation that was settled, never opened here, or
      #   is not a generation at all
      def settle(generation, disk:, annotations: [])
        generation = read_generation(generation)
        token = @open.fetch(generation) { refuse_stale!(generation) }
        delta = token.delta(disk)
        journal_settlement(closed(token, delta), notes_for(token, annotations, disk))
        release(generation)
        token.resolve(delta)
        delta
      end

      # Give the baton back without a settlement, because the hand-over never
      # happened.
      #
      # The case is narrow and it is deliberately NOT a settle: something raised
      # between {#open} and the human being told the file is theirs, so nobody
      # was handed anything, no editor buffer exists to send `done` from, and no
      # route to {#settle} was ever bound. Left open, that claim is DURABLE --
      # {ReviewOpened} is journaled before the token comes back -- so a restarted
      # lain would go on refusing every write to this epic with no user-reachable
      # escape at all.
      #
      # Journaled for exactly that reason: an in-memory release would leave the
      # journal saying open, and the next {.from_journal} would rebuild the wedge
      # this method exists to prevent.
      #
      # It closes with {ReviewClosed} rather than a record of its own, because
      # {Replay#release} already folds that record and already reads
      # `error`/`error_kind`. An abandon IS a close that compared nothing, which
      # is the shape that record already carries, so the fold needs no new
      # branch and no reader needs teaching.
      #
      # `disk_digest` is the WRITTEN digest, and that is a statement rather than
      # a placeholder: nothing came back because nothing went out, so what is on
      # disk is what lain wrote. `lossy: false` is UNMEASURED, not measured false
      # -- {Recalled}'s own distinction, and `error_kind` is what keeps them
      # apart.
      #
      # The promise is deliberately NOT resolved. Nobody reviewed anything, so
      # there is no delta to hand anyone and a fabricated one would report a
      # review that never happened. The only caller raises past its own await, so
      # no fiber is left waiting; a caller that abandons a review it also intends
      # to await has to answer that for itself.
      #
      # @param generation [Integer, String] the token's generation, read exactly
      #   as {#settle} reads it
      # @param reason [String] why the hand-over did not happen, journaled as the
      #   record's `error`
      # @return [Token] the token whose claim was given back
      # @raise [NotOpen] for a generation that was settled, never opened here, or
      #   is not a generation at all
      def abandon(generation, reason:)
        generation = read_generation(generation)
        token = @open.fetch(generation) { refuse_stale!(generation) }
        @journal << abandoned(token, reason)
        release(generation)
        token
      end

      private

      def abandoned(token, reason)
        ReviewClosed.new(epic_slug: @epic_slug, path: token.path, generation: token.generation,
                         written_digest: token.written_digest, disk_digest: token.written_digest,
                         changes: Intake::Account.empty.changes, lossy: false,
                         error: reason.to_s, error_kind: Abandoned.name)
      end

      # The wire's refusal is a record's refusal (ArgumentError), and this is the
      # one place that is the wrong exception: the only caller
      # ({CLI::HumanReplies::Reviews#settle}) rescues {NotOpen} to render the
      # editor a refusal, and anything else escapes and kills the fiber reading
      # the editor's replies -- so one stale buffer would take the whole reply
      # loop down with it. A generation that is not a generation names no open
      # review, which is exactly what {NotOpen} says.
      def read_generation(generation)
        ReviewClaim.generation(generation)
      rescue ArgumentError => e
        raise NotOpen, "#{e.message}, so there is no open review it could name"
      end

      def release(generation)
        @open.delete(generation)
        @settled << generation
      end

      # Which baseline compares this written side, decided in ONE place because
      # it is one question. `graph_digest` is where "there is nothing structural
      # to compare" is already structural rather than conventional: prose has no
      # way to acquire one ({Intake::Prose}), so nil is a property of the
      # artifact and not a flag a caller has to remember to pass.
      def baseline_for(written) = written.graph_digest.nil? ? ProseBaseline.new(written) : Baseline.new(written)

      def journal_settlement(closed, notes)
        @journal << closed
        notes.each { |note| @journal << note }
      end

      # Built BEFORE anything is journaled, which is the whole reason this is its
      # own method. A note the record refuses -- a human who typed nothing, an
      # unreadable line -- raises here, where the journal and the baton still
      # agree that the review is open and the human can hand it back again. Built
      # after the settlement, the same refusal left the journal saying settled
      # while the baton was still held and nobody's promise had resolved.
      def notes_for(token, annotations, disk)
        Annotations.resolve(annotations, disk)
                   .map { |note| Annotation.new(epic_slug: @epic_slug, generation: token.generation, **note) }
      end

      def closed(token, delta)
        ReviewClosed.new(epic_slug: @epic_slug, path: token.path, generation: token.generation,
                         written_digest: delta.written_digest, disk_digest: delta.disk_digest,
                         changes: delta.account.changes, lossy: delta.lossy?,
                         error: delta.error, error_kind: delta.error_kind)
      end

      def refuse_second_opener!(path)
        return unless open?(path)

        raise AlreadyOpen, "#{path} is already under review -- a second opener would shadow the first " \
                           "generation, leaving whoever awaits it waiting on a settle that cannot name it"
      end

      # Names WHICH way the generation is not open, because the two are different
      # situations for the human at the other end: a second `done` on a review
      # they already handed back, versus a buffer left over from a process that
      # has since restarted.
      def refuse_stale!(generation)
        raise NotOpen, "review generation #{generation} #{state_of(generation)} for epic " \
                       "#{@epic_slug.inspect}, so there is nothing to settle"
      end

      def state_of(generation) = @settled.include?(generation) ? "was already settled" : "was never opened"
    end
  end
end
