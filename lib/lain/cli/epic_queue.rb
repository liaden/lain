# frozen_string_literal: true

require "time"
require "active_support/core_ext/string/inflections"

module Lain
  module CLI
    # `lain epic queue [SLUG]` / `lain epic approve DIGEST` / `lain epic deny
    # DIGEST`: the morning review. What a {Approval::Gate::Policy::Deferred}
    # refused and parked, read over coffee and decided. Returns Strings; only the
    # frontend prints.
    #
    # == Draining is journaling
    #
    # {Approval::SignoffQueue} is a FOLD, not a file: an artifact is parked
    # exactly when a `deferred` decision has no LATER terminal one for the same
    # `(artifact_digest, epic_slug, stage)`. So `approve`/`deny` APPEND a terminal
    # {Approval::GateDecision} rather than mutating a queue, nothing here holds
    # state between commands, and two readers of the same journals agree by
    # construction.
    #
    # == A failed rebuild ABORTS
    #
    # {Approval::SignoffQueue.from_journal} raises on a record it cannot read
    # whole, {SessionJournals} on a torn line a sign-off could rest on, and
    # NOTHING here rescues either. Only the listing reads past a torn line, and
    # it says so on every rendering. The ergonomic response -- an empty
    # queue on failure -- is maximally fail-open: an empty queue reads as drained,
    # drained opens the next stage, and the stage opens over work nobody signed
    # off. {Approval::Gate::Policy::Drained} legitimizes "this caller has no
    # queue", never "this rebuild failed".
    #
    # This is the screen a human reads specifically to decide that nothing is
    # outstanding, so the empty rendering names the directory it read AND what it
    # understood there -- lines seen, records kept, lines it could parse nothing
    # from. A count of FILES cannot tell "understood it" from "understood none of
    # it", and an honest empty has to be checkable.
    class EpicQueue
      # `approve`/`deny` named an address nothing is waiting on. Loud, and it
      # lists what IS parked: the digest is 71 characters, so what a reader needs
      # is the near-miss beside what they typed.
      class UnknownDigest < Error; end

      # Held apart from {UnknownDigest}: that one says "you named the wrong
      # thing", this one says "the record is damaged", and the remedies are
      # nothing alike. The fold's own refusal, so a damaged record reads the
      # same whether the fold or this surface found it.
      UnreadableRecord = Approval::SignoffQueue::UnreadableRecord

      # An approved issue plan's issue status is folded from the epic's own
      # document, and the queue -- global to the sessions directory -- can be
      # drained from anywhere. Run outside the owning project, that document
      # is another project's, so the approval refuses before anything lands.
      class OutsideProject < Error; end

      # `answered_by` names WHO decided, `policy` names HOW the verdict was
      # reached -- independent axes ({Approval::GateDecision}'s contract), both
      # known here without asking anything.
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
      # @param epics [CLI::Epic, nil] folds an epic's progress, asked only when
      #   an approved issue plan has an issue to put in flight; nil builds the
      #   default one at that moment, so a drain that moves nothing never
      #   resolves a project
      def initialize(paths: Paths.new, clock: DEFAULT_CLOCK, epics: nil)
        @paths = paths
        @clock = clock
        @epics = epics
      end

      # @param slug [String, nil] narrow to one epic; every epic when omitted
      # @return [String] the parked items, reviewable-first
      def listing(slug = nil)
        read = walk(SessionJournals::Tolerate)
        rows = Review.new(read.to_a, now: @clock.call).rows(slug)
        body = rows.empty? ? empty_listing(slug, read.tally) : [headline(rows), *rows.map(&:to_s)].join("\n\n")
        [body, unparsed_warning(read.tally)].compact.join("\n\n")
      end

      # @param digest [String] the artifact address to sign off
      # @param reason [String, nil] the human's rationale, journaled verbatim
      # @return [String] the confirmation
      # @raise [UnknownDigest] naming the digest and listing the parked ones
      def approve(digest, reason: nil) = drain(digest, approved: true, reason:)

      # A denial is terminal too: a refused artifact awaits nobody's sign-off
      # either, so it drains the partition exactly as an approval does.
      # @see #approve
      def deny(digest, reason: nil) = drain(digest, approved: false, reason:)

      private

      # ONE command per instance: the fold is memoized, so an instance reused
      # after its own `approve` would answer from the review it read before that
      # decision landed. Right for a one-shot CLI -- Thor builds a fresh one per
      # invocation, and `unknown_message` wants the same fold `find` just missed
      # in -- and why nothing here is offered as a long-lived object.
      def dir = @dir ||= @paths.sessions_dir
      def review = @review ||= Review.new(journals.to_a, now: @clock.call)

      # The journal-discovery contract lives in {SessionJournals}, so this
      # command and `lain epic status` cannot drift about which files they read
      # or in what order -- they would disagree about what is parked, and neither
      # would raise. This class contributes only its two record types, which also
      # bounds the materialization that ordering forces.
      def journals = @journals ||= walk(SessionJournals::Refuse)

      # A decision refuses over a torn line; the listing alone tolerates one,
      # because {#unparsed_warning} tells the reader it is unproven. The
      # listing's read is its own and never cached, so its tolerance cannot
      # reach the {#review} the deciding verbs read.
      def walk(damage)
        SessionJournals.new(dir:, types: [Approval::SignoffQueue::JOURNAL_TYPE, EVIDENCE_TYPE], damage:)
      end

      def drain(digest, approved:, reason:)
        digest = digest.to_s
        rows = review.find(digest)
        raise UnknownDigest, unknown_message(digest, approved:) if rows.empty?

        decisions = rows.map { |row| row.terminal(approved:, reason:) }
        starts = Starts.new(decisions) { |slug| epics.progress(slug) }
        confirmation(digest, decisions, append(decisions, starts))
      end

      def epics = @epics ||= Epic.new(paths: @paths)

      # {Journal.open} creates a fresh file under `sessions_dir`, deliberately:
      # the fold reads every file there, so a decision journaled from a one-shot
      # CLI lands in the same truth the next fold sees. The decisions go first,
      # and any issue they start after them, as a verdict writes them.
      def append(decisions, starts)
        journal = Journal.open(paths: @paths)
        begin
          decisions.each { |decision| journal.record(decision) }
          starts.write(journal)
        ensure
          journal.close
        end
      end

      def confirmation(digest, decisions, moved)
        signed = decisions.map do |decision|
          "  #{decision.epic_slug}/#{decision.stage} — #{decision.approved ? "approved" : "denied"} by " \
            "#{decision.answered_by} after #{Row.waited_label(decision.latency)}"
        end
        ["signed off #{digest}", *signed, *moved.map { |line| "  #{line}" }].join("\n")
      end

      # `review.rows(nil)` widens to every epic: the near-miss beside what was
      # typed is the point of this listing. That is also why a SLUG argument gets
      # a different sentence -- "no parked sign-off for alpha" beside a row
      # naming alpha reads as the fold missing a match it plainly has, when in
      # fact `approve`/`deny` key on `artifact_digest` and a slug could never
      # match. {#digest_shaped?} tells the two kinds of miss apart.
      def unknown_message(digest, approved:)
        parked = review.rows(nil)
        headline = digest_shaped?(digest) ? "no parked sign-off for #{digest.inspect}" : kind_hint(digest, approved:)
        return "#{headline} -- nothing is parked for sign-off" if parked.empty?

        "#{headline} -- parked right now:\n#{parked.map { |row| "  #{row.address}" }.join("\n")}"
      end

      # Judged by {Canonical::DIGEST_ALGORITHM}, the one place the scheme is
      # named, rather than by a length or hex check that a genuinely
      # wrong-but-well-typed digest could still fail.
      def digest_shaped?(digest) = digest.start_with?("#{Canonical::DIGEST_ALGORITHM}:")

      def kind_hint(digest, approved:)
        "#{approved ? "approve" : "deny"} names a parked artifact by digest, not #{digest.inspect}"
      end

      def headline(rows)
        "#{rows.size} #{"gate".pluralize(rows.size)} parked for sign-off, ready-to-review first"
      end

      # Names what was UNDERSTOOD, not how many files were opened: a line nobody
      # could parse might BE the deferral, and a lost deferral reads as drained.
      def empty_listing(slug, counts)
        about = slug.to_s.empty? ? "" : " for epic #{slug.to_s.inspect}"
        "nothing parked for sign-off#{about} (folded #{counted(counts.files, "journal")} under #{dir}: " \
          "#{counted(counts.lines, "line")}, #{counted(counts.records, "gate record")})"
      end

      # REPORTED, not refused: this is the one reader that tolerates a torn
      # line, because refusing would make one damaged byte take down the screen
      # a human reads to find it -- and every decision taken from here refuses.
      # Silence is the false all-clear this screen must never give, so the count
      # rides along on every rendering -- a listing with items can be missing
      # one just as easily as an empty one can.
      #
      # A FOREIGN record does not count: a Rust `tracing` span is valid JSON and
      # simply is not ours, so counting it would cry wolf on every shared
      # journal.
      def unparsed_warning(counts)
        unreadable = counts.unreadable
        return nil unless unreadable.positive?

        "WARNING: #{counted(unreadable, "line")} could not be parsed as journal records. A parked sign-off " \
          "could be among them, so this listing is not proven complete."
      end

      def counted(count, noun) = "#{count} #{noun.pluralize(count)}"

      # One parked item joined to the two records that explain it: the deferral
      # that parked it and the spike evidence behind it.
      Row = Data.define(:item, :parked_at, :waited, :reason, :question) do
        # Coarse on purpose: a morning review asks "has this been sitting since
        # yesterday", never "how many seconds".
        def self.waited_label(seconds)
          return "#{(seconds / 86_400).floor}d" if seconds >= 86_400
          return "#{(seconds / 3_600).floor}h" if seconds >= 3_600
          return "#{(seconds / 60).floor}m" if seconds >= 60

          "#{seconds.floor}s"
        end

        # There is a spike to read, so this one can be decided now. An item
        # parked with no evidence has nothing for a human to weigh yet, so it
        # sorts behind -- what "ready-to-review first" means here.
        def reviewable? = !item.evidence_digest.nil?

        # Reviewable first, then pipeline order (an earlier stage's partition
        # BLOCKS the later ones, so draining it unblocks the most work), then
        # oldest first. An unrecognized stage sorts last rather than raising: it
        # is read perfectly and merely has no place in the pipeline, so refusing
        # to ORDER it is no reason to hide every other item.
        def order_key = [reviewable? ? 0 : 1, stage_index, parked_at]

        def address = "#{item.artifact_digest}  (#{item.epic_slug}/#{item.stage})"

        def terminal(approved:, reason:)
          Approval::GateDecision.new(artifact_digest: item.artifact_digest, epic_slug: item.epic_slug,
                                     stage: item.stage, approved:, answered_by: HUMAN, policy: SIGNOFF_POLICY,
                                     latency: waited, evidence_digest: item.evidence_digest, reason:,
                                     issue_id: item.issue_id, criteria_digest: item.criteria_digest)
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

      # The issues a drain starts. An approved issue plan puts its issue in
      # flight whichever surface approved it -- the epic driver launches only
      # issues in flight, so a plan signed off here and left pending would
      # never run. Progress is read BEFORE anything is journaled, so an epic
      # whose document is not here refuses before the sign-off lands.
      class Starts
        # Yields each epic slug with an approved plan, for that epic's progress.
        #
        # @raise [OutsideProject] when that epic's document is not where this
        #   process looks -- the approver stands in another project
        def initialize(decisions)
          @plans = decisions.select { |decision| plan_approval?(decision) }
          @progress = @plans.map(&:epic_slug).uniq.to_h do |slug|
            [slug, yield(slug)]
          rescue Lain::Epic::Home::MissingArtifact => e
            raise OutsideProject, outside_message(slug, e)
          end
        end

        # @return [Array<String>] one line per approved plan, saying what moved
        def write(journal)
          @plans.map do |plan|
            Lain::Epic::InFlight.new(scribe: Lain::Epic::Scribe.new(epic_slug: plan.epic_slug, journal:),
                                     progress: -> { @progress.fetch(plan.epic_slug) }, issue_id: plan.issue_id).call
          end
        end

        private

        def plan_approval?(decision)
          Lain::Epic::InFlight.starts?(approved: decision.approved, stage: decision.stage, issue_id: decision.issue_id)
        end

        def outside_message(slug, cause)
          "approving an issue_plan of epic #{slug.inspect} puts its issue in flight, which reads the epic's own " \
            "document, so it must run inside the project that owns it -- nothing was journaled (#{cause.message})"
        end
      end

      # The fold, joined. Held apart from {EpicQueue} because rebuilding the
      # review is a separate responsibility from the command surface over it, and
      # because the rebuild must be reachable by a spec without a CLI.
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

        # Plural because one artifact CAN be parked in two partitions (the same
        # bytes gated at two stages), and signing off "the digest" means signing
        # off each place it waits -- which the confirmation names one by one, so
        # nothing is drained silently.
        def find(digest) = built.select { |row| row.item.artifact_digest == digest }

        private

        def built = @built ||= @queue.map { |item| row_for(item) }

        def row_for(item)
          deferral = deferrals.fetch(address(item)) { raise UnreadableRecord, orphan_message(item) }
          parked_at = parked_at(deferral, item)
          Row.new(item:, parked_at:, waited: waited(parked_at, item), reason: deferral["reason"],
                  question: evidence.dig(address(item), "question"))
        end

        # A deferral stamped AFTER now is refused here rather than downstream:
        # left alone it reached {Contracts::GateDecision} as a negative latency
        # and came back as a bare `ArgumentError` naming neither this surface nor
        # a remedy, while the listing rendered `waiting -3600s` and the item could
        # not be drained until the wall clock caught up. Clock skew between the
        # machine that journaled and the one reading is the ordinary cause, so the
        # message says to check that rather than implying corruption.
        def waited(parked_at, item)
          seconds = @now - parked_at
          return seconds unless seconds.negative?

          raise UnreadableRecord,
                "the deferral parking #{item.artifact_digest} is stamped #{parked_at.iso8601}, which is in the " \
                "FUTURE relative to now (#{@now.iso8601}) -- its wait cannot be measured, and a sign-off may " \
                "not journal a latency nobody could have waited. Check the clock on the machine that journaled it."
        end

        # The wait is journaled as the sign-off's latency, so an unreadable
        # timestamp is refused rather than defaulted: `to_f` would write a missing
        # `ts` into the experiment record as 0.0, "answered instantly", a
        # measurement nobody made. {Journal#record} stamps every line it writes,
        # so no producible record trips this -- it is a truncation canary.
        def parked_at(deferral, item)
          Time.iso8601(deferral["ts"].to_s)
        rescue ArgumentError, TypeError
          raise UnreadableRecord, "the deferral parking #{item.artifact_digest} carries no readable `ts` " \
                                  "(#{deferral["ts"].inspect}) -- its wait cannot be measured, and a " \
                                  "sign-off may not journal a latency nobody measured"
        end

        # Last write wins: an artifact deferred twice is one thing to sign off,
        # and the most recent attempt carries the hesitation a reader wants.
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

        # Nothing can park without a deferral behind it, so reaching this means
        # the records changed underneath the fold. Refused rather than rendered
        # with a blank age.
        def orphan_message(item)
          "#{item.artifact_digest} is parked in #{item.epic_slug}/#{item.stage} with no `deferred` " \
            "gate_decision behind it -- the queue and the journal disagree, and this surface will not guess"
        end
      end

      # Machinery, not surface: the three commands above are the whole public
      # API, and {Progress}'s `Lineage`/`Refold` set the precedent.
      private_constant :Row, :Review
    end
  end
end
