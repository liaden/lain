# frozen_string_literal: true

require "time"
require "active_support/core_ext/string/inflections"

module Lain
  module CLI
    # `lain epic queue [SLUG]` / `lain epic approve DIGEST` / `lain epic deny
    # DIGEST`: the morning review. What a {Approval::Gate::Policy::Deferred}
    # refused and parked -- question, spike evidence, and the model's hesitation
    # -- read over coffee and decided.
    #
    # == Draining is journaling
    #
    # {Approval::SignoffQueue} is a FOLD, not a file: an artifact is parked
    # exactly when a `deferred` decision has no LATER terminal one for the same
    # `(artifact_digest, epic_slug, stage)`. So `approve`/`deny` do not mutate a
    # queue -- they APPEND a terminal {Approval::GateDecision} and let the next
    # fold see the partition drained. Nothing here holds state between commands,
    # and two readers of the same journals agree by construction.
    #
    # == A failed rebuild ABORTS
    #
    # {Approval::SignoffQueue.from_journal} raises on a record it cannot read
    # whole, and NOTHING in this class rescues that. The ergonomic response --
    # an empty queue on failure -- is maximally fail-open here: an empty queue
    # reads as drained, drained opens the next stage, and the stage opens over
    # work nobody signed off. {Approval::Gate::Policy::Drained} legitimizes "this
    # caller has no queue", never "this rebuild failed".
    #
    # This matters most on THIS surface, because it is the screen a human reads
    # specifically to decide that nothing is outstanding. A listing that shows
    # "nothing parked" because the fold blew up is worse than no listing at all,
    # which is why the empty rendering names the directory it read AND what it
    # understood there -- lines seen, records kept, lines it could parse nothing
    # from. A count of FILES cannot tell "understood it" from "understood none
    # of it", and an honest empty has to be checkable.
    #
    # Returns Strings; only the frontend prints (output discipline,
    # {CLI::Friction}'s precedent).
    class EpicQueue
      # `approve`/`deny` named an address nothing is waiting on. Loud, and it
      # lists what IS parked -- the digest is 71 characters and the one thing a
      # reader needs is the near-miss beside what they typed.
      class UnknownDigest < Error; end

      # A journaled record this surface must read whole and cannot. Held apart
      # from {UnknownDigest}: that one says "you named the wrong thing", this one
      # says "the record is damaged", and the remedies are nothing alike.
      class UnreadableRecord < Error; end

      # The two labels a human sign-off wears in the experiment record.
      # `answered_by` names WHO decided, `policy` names HOW the verdict was
      # reached -- independent axes ({Approval::GateDecision}'s contract), and
      # this is the one path where both are known without asking anything.
      HUMAN = "human"
      SIGNOFF_POLICY = "signoff"

      # {Approval::Gate::Adjudicator::GateEvidence}'s discriminator. A literal
      # because that class ships no constant for it; a spec pins this string
      # against a real record's `#journal_type`, so the two cannot drift.
      EVIDENCE_TYPE = "gate_evidence"

      DEFAULT_CLOCK = -> { Time.now.utc }

      # @param paths [Paths] resolves `sessions_dir`, both for reading every
      #   journal and for the file a drain decision is appended to
      # @param clock [#call] returns "now" as a Time; injected so the wait a
      #   sign-off records is a function of the journal rather than of when the
      #   command ran
      def initialize(paths: Paths.new, clock: DEFAULT_CLOCK)
        @paths = paths
        @clock = clock
      end

      # @param slug [String, nil] narrow to one epic; every epic when omitted
      # @return [String] the parked items, reviewable-first
      def listing(slug = nil)
        rows = review.rows(slug)
        body = rows.empty? ? empty_listing(slug) : [headline(rows), *rows.map(&:to_s)].join("\n\n")
        [body, unparsed_warning].compact.join("\n\n")
      end

      # @param digest [String] the artifact address to sign off
      # @param reason [String, nil] the human's rationale, journaled verbatim
      # @return [String] the confirmation
      # @raise [UnknownDigest] naming the digest and listing the parked ones
      def approve(digest, reason: nil) = drain(digest, approved: true, reason:)

      # A denial is terminal too: a refused artifact is not awaiting anyone's
      # sign-off either, so it drains the partition exactly as an approval does.
      # @see #approve
      def deny(digest, reason: nil) = drain(digest, approved: false, reason:)

      private

      # ONE command per instance. The fold is memoized, so an instance reused
      # after its own `approve` would answer from the review it read before that
      # decision landed. That is exactly right for a one-shot CLI -- the Thor
      # registration builds a fresh one per invocation, and `unknown_message`
      # wants the same fold `find` just missed in, not a second read of the
      # disk -- and it is why nothing here is offered as a long-lived object.
      def dir = @dir ||= @paths.sessions_dir
      def review = @review ||= Review.new(journals.to_a, now: @clock.call)

      # The journal-discovery contract lives in {SessionJournals}, not here, so
      # `lain epic status` and this command cannot drift about which files they
      # read or in what order -- they would disagree about what is parked, and
      # neither would raise. This class contributes only the two record types it
      # is about, which is also what bounds the materialization that ordering
      # forces.
      def journals
        @journals ||= SessionJournals.new(dir:, types: [Approval::SignoffQueue::JOURNAL_TYPE, EVIDENCE_TYPE])
      end

      def drain(digest, approved:, reason:)
        digest = digest.to_s
        rows = review.find(digest)
        raise UnknownDigest, unknown_message(digest) if rows.empty?

        decisions = rows.map { |row| row.terminal(approved:, reason:) }
        append(decisions)
        confirmation(digest, decisions)
      end

      # One Journal for the whole command, closed whatever happens. {Journal.open}
      # creates a fresh file under `sessions_dir`, which is deliberate: the fold
      # reads every file there, so a decision journaled from a one-shot CLI lands
      # in the same truth the next fold sees.
      def append(decisions)
        journal = Journal.open(paths: @paths)
        begin
          decisions.each { |decision| journal.record(decision) }
        ensure
          journal.close
        end
      end

      def confirmation(digest, decisions)
        signed = decisions.map do |decision|
          "  #{decision.epic_slug}/#{decision.stage} — #{decision.approved ? "approved" : "denied"} by " \
            "#{decision.answered_by} after #{Row.waited_label(decision.latency)}"
        end
        ["signed off #{digest}", *signed].join("\n")
      end

      def unknown_message(digest)
        parked = review.rows(nil)
        return "no parked sign-off for #{digest.inspect} -- nothing is parked for sign-off" if parked.empty?

        "no parked sign-off for #{digest.inspect} -- parked right now:\n" \
          "#{parked.map { |row| "  #{row.address}" }.join("\n")}"
      end

      def headline(rows)
        "#{rows.size} #{"gate".pluralize(rows.size)} parked for sign-off, ready-to-review first"
      end

      # Names what was UNDERSTOOD, not just how many files were opened.
      # "Nothing parked" is the answer this surface exists to give, and a count
      # of files cannot tell "read one journal and understood it" from "read one
      # journal and understood none of it" -- while a line nobody could parse
      # might BE the deferral, and a lost deferral reads as drained.
      def empty_listing(slug)
        about = slug.to_s.empty? ? "" : " for epic #{slug.to_s.inspect}"
        counts = journals.tally
        "nothing parked for sign-off#{about} (folded #{counted(counts.files, "journal")} under #{dir}: " \
          "#{counted(counts.lines, "line")}, #{counted(counts.records, "gate record")})"
      end

      # The emptiness above is only as good as the reading under it, so a line
      # the parser could make nothing of is reported rather than swallowed.
      #
      # REPORTED, not refused: {Journal.records}' documented contract is to skip
      # what it cannot read, because this fd can be shared with other writers,
      # and refusing would make one damaged byte take the whole surface down.
      # But silence here is the false all-clear this screen must never give, so
      # the count rides along on every rendering -- a listing with items can be
      # missing one just as easily as an empty one can.
      #
      # A FOREIGN record does not count: a Rust `tracing` span is valid JSON and
      # simply is not ours, so counting it would cry wolf on every session that
      # shared its journal.
      def unparsed_warning
        unreadable = journals.tally.unreadable
        return nil unless unreadable.positive?

        "WARNING: #{counted(unreadable, "line")} could not be parsed as journal records. A parked sign-off " \
          "could be among them, so this listing is not proven complete."
      end

      def counted(count, noun) = "#{count} #{noun.pluralize(count)}"

      # One parked item joined to the two records that explain it: the deferral
      # that parked it (when, and the model's hesitation) and the spike evidence
      # (the question that was asked).
      Row = Data.define(:item, :parked_at, :waited, :reason, :question) do
        # Seconds as a human reads them. Coarse on purpose -- a morning review
        # asks "has this been sitting since yesterday", never "how many seconds".
        def self.waited_label(seconds)
          return "#{(seconds / 86_400).floor}d" if seconds >= 86_400
          return "#{(seconds / 3_600).floor}h" if seconds >= 3_600
          return "#{(seconds / 60).floor}m" if seconds >= 60

          "#{seconds.floor}s"
        end

        # There is a spike to read, so this one can actually be decided now. An
        # item parked with no evidence (a researcher spawn that failed -- T7's
        # fail-closed path) has nothing for a human to weigh yet, so it sorts
        # behind. That is what "ready-to-review first" means here.
        def reviewable? = !item.evidence_digest.nil?

        # Reviewable first, then pipeline order (an earlier stage's partition is
        # what BLOCKS the later ones -- {Epic::Stage}'s boundary rule -- so
        # draining it unblocks the most work), then oldest first.
        #
        # An unrecognized stage sorts last rather than raising: it is still
        # rendered, with its stage verbatim, because refusing to ORDER an item is
        # no reason to hide every other one. That is not the same failure as a
        # record the fold cannot read -- this one is read perfectly and merely
        # has no place in the pipeline.
        def order_key = [reviewable? ? 0 : 1, stage_index, parked_at]

        def address = "#{item.artifact_digest}  (#{item.epic_slug}/#{item.stage})"

        def terminal(approved:, reason:)
          Approval::GateDecision.new(artifact_digest: item.artifact_digest, epic_slug: item.epic_slug,
                                     stage: item.stage, approved:, answered_by: HUMAN, policy: SIGNOFF_POLICY,
                                     latency: waited, evidence_digest: item.evidence_digest, reason:)
        end

        def to_s
          ["#{item.stage}  epic #{item.epic_slug}  waiting #{self.class.waited_label(waited)}",
           "  question:  #{question || "<not recoverable from the journal>"}",
           "  artifact:  #{item.artifact_digest}",
           "  evidence:  #{item.evidence_digest || "<none gathered -- the spike did not answer>"}",
           *(reason ? ["  hesitation: #{reason}"] : [])].join("\n")
        end

        private

        # `Lain::Epic`, spelled out: {CLI::Epic} is a sibling of this class, so a
        # bare `Epic` resolves to THAT one and finds no STAGES.
        def stage_index = Lain::Epic::STAGES.index(item.stage) || Lain::Epic::STAGES.size
      end

      # The fold, joined. Held apart from {EpicQueue} because rebuilding the
      # review is a separate responsibility from the command surface over it --
      # and because the rebuild must be reachable by a spec without a CLI.
      class Review
        def initialize(records, now:)
          @records = records
          @now = now
          # NO rescue, here or anywhere below it. See the class comment.
          @queue = Approval::SignoffQueue.from_journal(records)
        end

        # @param slug [String, nil]
        # @return [Array<Row>] ordered reviewable-first
        def rows(slug = nil)
          wanted = slug.to_s
          ordered = built.sort_by(&:order_key)
          wanted.empty? ? ordered : ordered.select { |row| row.item.epic_slug == wanted }
        end

        # Every row at this address. Plural because one artifact CAN be parked in
        # two partitions (the same bytes gated at two stages), and signing off
        # "the digest" means signing off each place it waits -- which the
        # confirmation then names one by one, so nothing is drained silently.
        def find(digest) = built.select { |row| row.item.artifact_digest == digest }

        private

        def built = @built ||= @queue.map { |item| row_for(item) }

        def row_for(item)
          deferral = deferrals.fetch(address(item)) { raise UnreadableRecord, orphan_message(item) }
          parked_at = parked_at(deferral, item)
          Row.new(item:, parked_at:, waited: waited(parked_at, item), reason: deferral["reason"],
                  question: evidence.dig(address(item), "question"))
        end

        # A deferral stamped AFTER now is a damaged record, and it is refused
        # here rather than allowed downstream. Left alone it reached
        # {Guards::GateDecision} as a negative latency and came back as a bare
        # `ArgumentError` naming neither this surface nor a remedy -- and the
        # item could not be drained at all until the wall clock caught up, while
        # the listing rendered `waiting -3600s`. Clock skew between the machine
        # that journaled and the one reading is the ordinary cause, so the
        # message says to check that rather than implying corruption.
        def waited(parked_at, item)
          seconds = @now - parked_at
          return seconds unless seconds.negative?

          raise UnreadableRecord,
                "the deferral parking #{item.artifact_digest} is stamped #{parked_at.iso8601}, which is in the " \
                "FUTURE relative to now (#{@now.iso8601}) -- its wait cannot be measured, and a sign-off may " \
                "not journal a latency nobody could have waited. Check the clock on the machine that journaled it."
        end

        # The wait is a MEASUREMENT that gets journaled as the sign-off's
        # latency, so an unreadable timestamp is refused rather than defaulted.
        # `to_f` would turn a missing `ts` into 0.0 -- "answered instantly", a
        # measurement nobody made -- written into the experiment record.
        # {Journal#record} stamps every line it writes, so no producible record
        # trips this: it is a truncation canary, the {SignoffQueue::Guards}
        # idiom.
        def parked_at(deferral, item)
          Time.iso8601(deferral["ts"].to_s)
        rescue ArgumentError, TypeError
          raise UnreadableRecord, "the deferral parking #{item.artifact_digest} carries no readable `ts` " \
                                  "(#{deferral["ts"].inspect}) -- its wait cannot be measured, and a " \
                                  "sign-off may not journal a latency nobody measured"
        end

        # Last write wins: an artifact deferred twice is one thing to sign off
        # ({SignoffQueue#park} is idempotent on the same address), and the most
        # recent attempt is the one whose hesitation and evidence a reader wants.
        def deferrals
          @deferrals ||= of_type(Approval::SignoffQueue::JOURNAL_TYPE)
                         .select { |record| record["policy"].to_s == Approval::SignoffQueue::DEFERRED_POLICY }
                         .to_h { |record| [address_of(record), record] }
        end

        def evidence
          @evidence ||= of_type(EVIDENCE_TYPE).to_h { |record| [address_of(record), record] }
        end

        def of_type(type) = Journal.records(@records, type:)

        def address(item) = [item.artifact_digest, item.epic_slug, item.stage]

        def address_of(record)
          [record["artifact_digest"].to_s, record["epic_slug"].to_s, record["stage"].to_s]
        end

        # Nothing can park without a deferral behind it ({SignoffQueue}'s
        # one-directional invariant), so reaching this means the records changed
        # underneath the fold. Refused rather than rendered with a blank age.
        def orphan_message(item)
          "#{item.artifact_digest} is parked in #{item.epic_slug}/#{item.stage} with no `deferred` " \
            "gate_decision behind it -- the queue and the journal disagree, and this surface will not guess"
        end
      end

      # Machinery, not surface: the three commands above are the whole public
      # API, and {Progress}'s `Lineage`/`Refold` set the precedent for keeping a
      # fold's internals out of reach.
      private_constant :Row, :Review
    end
  end
end
