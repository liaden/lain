# frozen_string_literal: true

require "time"
require "active_support/core_ext/string/inflections"

module Lain
  module CLI
    # `lain epic queue [SLUG]` / `lain epic approve DIGEST` / `lain epic deny
    # DIGEST`: the morning review. What a {Lain::Epic::Gate::Policy::Deferred}
    # refused and parked, read over coffee and decided. Returns Strings; only the
    # frontend prints.
    #
    # == Draining is journaling
    #
    # {Lain::Epic::SignoffQueue} is a FOLD, not a file: an artifact is parked
    # exactly when a `deferred` decision has no LATER terminal one for the same
    # `(artifact_digest, epic_slug, stage)`. So `approve`/`deny` APPEND a terminal
    # {Lain::Epic::GateDecision} rather than mutating a queue, nothing here holds
    # state between commands, and two readers of the same journals agree by
    # construction.
    #
    # == A failed rebuild ABORTS
    #
    # {Lain::Epic::SignoffQueue.from_journal} raises on a record it cannot read
    # whole, {SessionJournals} on a torn line a sign-off could rest on, and
    # NOTHING here rescues either. Only the listing reads past a torn line, and
    # it says so on every rendering. The ergonomic response -- an empty
    # queue on failure -- is maximally fail-open: an empty queue reads as drained,
    # drained opens the next stage, and the stage opens over work nobody signed
    # off.
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
      UnreadableRecord = Lain::Epic::SignoffQueue::UnreadableRecord

      # An approved issue plan puts its issue in flight, and an issue's status
      # is folded from the epic's own document -- so with no document where
      # this process resolves it, the approval refuses before anything lands,
      # naming the document and the path it looked at.
      class MissingEpicDocument < Error; end

      # `answered_by` names WHO decided; `policy` names HOW the verdict was
      # reached ({Lain::Epic::SignoffQueue::SIGNOFF_POLICY}) -- independent axes
      # ({Lain::Epic::GateDecision}'s contract), both known here without asking.
      HUMAN = "human"

      # {Lain::Epic::Gate::Adjudicator::GateEvidence}'s discriminator. A literal
      # because that class ships no constant for it; a spec pins this string
      # against a real record's `#journal_type`, so the two cannot drift.
      EVIDENCE_TYPE = "gate_evidence"

      PARKED_TYPE = "awaiting_human"
      TESTS_TYPE = "tests_ran"

      DEFAULT_CLOCK = -> { Time.now.utc }

      # @param paths [Paths] resolves `sessions_dir`, both for reading every
      #   journal and for the file a drain decision is appended to
      # @param clock [#call] returns "now" as a Time; injected so the wait a
      #   sign-off records is a function of the journal rather than of when the
      #   command ran
      # @param epics [CLI::Epic, nil] answers where an epic stands, asked only
      #   when an approval advances its epic ({Epic::Advance#moves?}); nil builds the
      #   default one at that moment, so a drain that moves nothing never
      #   builds the epic command
      # @param root [String] the project root, where a chat files its journal
      # @param config [Config, nil] says where the epics live, for the boundary's
      #   current digests; nil loads the root's own when an approval first needs it
      def initialize(paths: Paths.new, clock: DEFAULT_CLOCK, epics: nil, root: Project::Resolver.default_project.root,
                     config: nil)
        @paths = paths
        @root = root
        @clock = clock
        @epics = epics
        @config = config
      end

      # @param slug [String, nil] narrow to one epic; every epic when omitted
      # @return [String] the parked items, reviewable-first
      def listing(slug = nil)
        read = walk(SessionJournals::Tolerate)
        rows = Review.new(read.to_a, now: @clock.call).rows(slug)
        body = rows.empty? ? empty_listing(slug, read.tally) : [headline(rows), *rows.map(&:to_s)].join("\n\n")
        [body, unparsed_warning(read.tally), misfiled_warning(read.tally)].compact.join("\n\n")
      end

      # @param digest [String] the artifact address to sign off
      # @param reason [String, nil] the human's rationale, journaled verbatim
      # @param answered_by [String] the surface the human answered on
      # @return [String] the confirmation
      # @raise [UnknownDigest] naming the digest and listing the parked ones
      def approve(digest, reason: nil, answered_by: HUMAN)
        drain(digest, Lain::Approval::Verdict::Approve.new(note: reason), answered_by)
      end

      # A denial is terminal too: a refused artifact awaits nobody's sign-off
      # either, so it drains the partition exactly as an approval does.
      # @see #approve
      def deny(digest, reason: nil, answered_by: HUMAN)
        drain(digest, Lain::Approval::Verdict::Deny.new(note: reason), answered_by)
      end

      private

      # ONE command per instance: the fold is memoized, so an instance reused
      # after its own `approve` would answer from the review it read before that
      # decision landed. Right for a one-shot CLI -- Thor builds a fresh one per
      # invocation, and `unknown_message` wants the same fold `find` just missed
      # in -- and why nothing here is offered as a long-lived object.
      attr_reader :root

      def dirs = @dirs ||= [@paths.filing_dir(root:)]
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
        types = [Lain::Epic::SignoffQueue::JOURNAL_TYPE, EVIDENCE_TYPE, PARKED_TYPE, TESTS_TYPE]
        SessionJournals.new(dirs:, types:, damage:)
      end

      def drain(digest, verdict, answered_by)
        digest = digest.to_s
        rows = review.find(digest)
        raise UnknownDigest, unknown_message(digest, approved: verdict.approved?) if rows.empty?

        decisions = in_stage_order(rows).map { |row| row.terminal(verdict, answered_by:) }
        advances = Advances.new(decisions) { epics }
        ensure_open!(decisions) if verdict.approved?
        confirmation(digest, decisions, append(decisions, advances))
      end

      # Stable within a stage, so two issues' plans keep the fold's order.
      def in_stage_order(rows) = rows.sort_by.with_index { |row, at| [row.stage_index, at] }

      # A sign-off advances its epic as a verdict does, so it meets the same
      # boundary. Each approval is folded in before the next is checked: one
      # digest parked at research and at epic_plan opens epic_plan only over
      # the research approval this same drain journals.
      def ensure_open!(decisions)
        queue = Lain::Epic::SignoffQueue.from_journal(journals.to_a)
        boundary = Lain::Epic::Gate::Policy::Boundary.new(queue, digests)
        decisions.each do |decision|
          boundary.ensure_open!(decision.stage, epic_slug: decision.epic_slug, issue_id: decision.issue_id)
          queue.apply(decision.to_journal)
        end
      end

      def epics = @epics ||= Epic.new(paths: @paths)

      def digests = EpicSubmit::Digests.new(config: @config || Config.load(root:), paths: @paths, root:)

      # {Journal.open} creates a fresh file under the root's session directory, deliberately:
      # the fold reads every file there, so a decision journaled from a one-shot
      # CLI lands in the same truth the next fold sees. The decisions go first,
      # and whatever they advance after them, as a verdict writes them.
      def append(decisions, advances)
        journal = Journal.open(paths: @paths, root:)
        begin
          decisions.each { |decision| journal.record(decision) }
          advances.write(journal)
        ensure
          journal.close
        end
      end

      def confirmation(digest, decisions, moved)
        signed = decisions.map do |decision|
          "  #{partition_of(decision)} — #{decision.approved? ? "approved" : "denied"} by " \
            "#{decision.answered_by} after #{Row.waited_label(decision.latency)}"
        end
        ["#{decisions.first.approved? ? "signed off" : "denied"} #{digest}", *signed,
         *moved.map { |line| "  #{line}" }].join("\n")
      end

      # Spelled by {Lain::Epic::SignoffQueue::Partition}, so a sign-off names its
      # issue exactly as the park it drained did.
      def partition_of(decision)
        Lain::Epic::SignoffQueue::Partition.new(epic_slug: decision.epic_slug, stage: decision.stage,
                                                issue_id: decision.issue_id).to_s
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
        held = rows.count(&:held)
        "#{rows.size} #{"gate".pluralize(rows.size)} waiting for sign-off#{" (#{held} held)" if held.positive?}, " \
          "ready-to-review first"
      end

      # Names what was UNDERSTOOD, not how many files were opened: a line nobody
      # could parse might BE the deferral, and a lost deferral reads as drained.
      def empty_listing(slug, counts)
        about = slug.to_s.empty? ? "" : " for epic #{slug.to_s.inspect}"
        folded = "#{counts.files} #{"journal".pluralize(counts.files)}"
        "nothing parked for sign-off#{about} (folded #{folded} under #{Paths.listing(dirs)}: " \
          "#{counts.lines} #{"line".pluralize(counts.lines)}, " \
          "#{counts.records} #{"gate record".pluralize(counts.records)})"
      end

      # REPORTED, not refused: this is the one reader that tolerates a torn
      # line, because refusing would make one damaged byte take down the screen
      # a human reads to find it -- and every decision taken from here refuses.
      # Silence is the false all-clear this screen must never give, so the count
      # rides along on every rendering -- a listing with items can be missing
      # one just as easily as an empty one can.
      #
      # A FOREIGN record does not count: another writer's JSON line is valid and
      # simply is not ours, so counting it would cry wolf on every shared
      # journal.
      def unparsed_warning(counts)
        unreadable = counts.unreadable
        return nil unless unreadable.positive?

        "WARNING: #{unreadable} #{"line".pluralize(unreadable)} could not be parsed as journal records. " \
          "A parked sign-off could be among them, so this listing is not proven complete."
      end

      # A misfiled record DID parse, so it gets its own sentence naming the type
      # it wore, rather than sending the reader after torn bytes.
      def misfiled_warning(counts)
        misfiled = counts.misfiled
        return nil if misfiled.empty?

        "WARNING: #{misfiled.size} #{"record".pluralize(misfiled.size)} carrying a sign-off's fields " \
          "#{misfiled.one? ? "has" : "have"} " \
          "an unknown type (#{misfiled.uniq.join(", ")}). A parked sign-off could be among them, so this listing " \
          "is not proven complete."
      end

      # One parked item joined to the two records that explain it: the deferral
      # that parked it and the spike evidence behind it. `spiked` is whether a
      # spike ran at all, because an empty evidence cell means something else
      # when no policy ever asked for one.
      Row = Data.define(:item, :parked_at, :waited, :reason, :question, :spiked, :tests, :held) do
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

        def address = "#{item.artifact_digest}  (#{item.partition})"

        def terminal(verdict, answered_by:)
          Lain::Epic::GateDecision.new(artifact_digest: item.artifact_digest, epic_slug: item.epic_slug,
                                       stage: item.stage, verdict:, answered_by:,
                                       policy: Lain::Epic::SignoffQueue::SIGNOFF_POLICY,
                                       latency: waited, evidence_digest: item.evidence_digest,
                                       issue_id: item.issue_id, criteria_digest: item.criteria_digest)
        end

        # `Lain::Epic`, spelled out: {CLI::Epic} is a sibling of this class, so a
        # bare `Epic` resolves to THAT one and finds no STAGES.
        def stage_index = Lain::Epic::STAGES.index(item.stage) || Lain::Epic::STAGES.size

        def to_s
          ["#{item.stage}  epic #{item.epic_slug}#{issue}  #{held ? "held" : "waiting"} " \
           "#{self.class.waited_label(waited)}",
           "  question:  #{question || "<not recoverable from the journal>"}",
           *(tests ? ["  tests:     #{tests}"] : []),
           "  artifact:  #{item.artifact_digest}",
           "  evidence:  #{item.evidence_digest || no_evidence}",
           *reason_lines, *answer_lines].join("\n")
        end

        private

        def reason_lines
          return [] unless reason

          [held ? "  held for:  #{reason}" : "  hesitation: #{reason}"]
        end

        def answer_lines
          return [] unless held

          ["  answer:    lain epic approve #{item.artifact_digest}",
           "             lain epic deny #{item.artifact_digest}"]
        end

        def issue = item.issue_id ? "  issue #{item.issue_id}" : ""

        def no_evidence = spiked ? "<none gathered -- the spike did not answer>" : "<none -- no spike ran>"
      end

      # What a drain advances, by {Epic::Advance}'s rule, so a sign-off here
      # moves the epic exactly as a verdict would: the epic driver launches
      # only issues in flight, and `lain epic status` reads the last stage
      # started, so an approval that moved neither would never be acted on.
      # Where each epic stands is read BEFORE anything is journaled, so a fold
      # that refuses refuses before the sign-off lands.
      class Advances
        # Yields once, for the epics to read, and only when an approval moves
        # something -- so a drain that moves nothing never resolves a project.
        #
        # @raise [MissingEpicDocument] when an approved plan's epic has no
        #   document where this process resolves it
        def initialize(decisions)
          advances = decisions.select(&:approved?).map { |decision| [decision, advance(decision)] }
          moving = advances.select { |_decision, advance| advance.moves? }
          @ready = moving.empty? ? [] : read(moving, yield)
        end

        # @return [Array<String>] one line per advancing approval, saying what moved
        def write(journal) = @ready.map { |ready| ready.call(journal) }

        private

        def advance(decision)
          Lain::Epic::Advance.new(epic_slug: decision.epic_slug, stage: decision.stage, issue_id: decision.issue_id)
        end

        def read(moving, epics)
          moving.map do |decision, advance|
            advance.read(epics)
          rescue Lain::Epic::Home::MissingArtifact => e
            raise MissingEpicDocument, missing_message(decision, e)
          end
        end

        def missing_message(decision, cause)
          "cannot approve the #{decision.stage} for issue #{decision.issue_id.inspect} of epic " \
            "#{decision.epic_slug.inspect}: putting the issue in flight reads its status from the epic's document, " \
            "and there is #{cause.message} -- nothing was journaled"
        end
      end

      # The fold, joined. Held apart from {EpicQueue} because rebuilding the
      # review is a separate responsibility from the command surface over it, and
      # because the rebuild must be reachable by a spec without a CLI.
      class Review
        # The latest record of one type per key. Records arrive as the raw hashes the fold reads,
        # because the row builders index them by field name.
        class LatestBy < Journal::Projection
          def self.unit = new({})

          def step(record)
            admits?(record) ? self.class.new(state.merge(key_of(record) => record)) : self
          end

          private

          def admits?(record) = record["type"].to_s == self.class::TYPE

          def key_of(record)
            [record["artifact_digest"].to_s, record["epic_slug"].to_s, record["stage"].to_s]
          end
        end

        # Last write wins: an artifact deferred twice is one thing to sign off,
        # and the most recent attempt carries the hesitation a reader wants.
        class Deferrals < LatestBy
          TYPE = Lain::Epic::SignoffQueue::JOURNAL_TYPE
          DEFERRED = Lain::Epic::GateDecision::WORDS.fetch(Lain::Epic::GateDecision::Deferred)

          private

          def admits?(record) = super && record["verdict"] == DEFERRED
        end

        # A hold is answered by the next decision, so its newest record is what dates it.
        class Holds < LatestBy
          TYPE = Lain::Epic::SignoffQueue::JOURNAL_TYPE
          HELD = Lain::Epic::GateDecision::WORDS.fetch(Lain::Approval::Verdict::Hold)

          private

          def admits?(record) = super && record["verdict"] == HELD
        end

        # Only a deferred gate's wait: a live gate's is closed by its own decision.
        class Parks < LatestBy
          TYPE = PARKED_TYPE

          private

          def admits?(record) = super && record["kind"] == "gate" && record["deferred"] == true

          def key_of(record) = [record["ref"].to_s, record["epic_slug"].to_s, record["stage"].to_s]
        end

        class Evidence < LatestBy
          TYPE = EVIDENCE_TYPE
        end

        # Keyed by the issue and the commit the tests ran at, as a parked row finds them.
        class TestRuns < LatestBy
          TYPE = TESTS_TYPE

          private

          def key_of(record) = [record["issue_id"].to_s, record["sha"].to_s]
        end

        private_constant :LatestBy, :Deferrals, :Holds, :Parks, :Evidence, :TestRuns

        def initialize(records, now:)
          @now = now
          # Materialized once: the queue fold and the record maps both read it, and a lazy source walks per reader.
          records = records.to_a
          # NO rescue, here or anywhere below it. See the class comment.
          @queue = Lain::Epic::SignoffQueue.from_journal(records)
          @signoff = Lain::Epic::Signoff.from_journal(records)
          @maps = Journal::Projections.of(deferrals: Deferrals.unit, holds: Holds.unit, parks: Parks.unit,
                                          test_runs: TestRuns.unit, evidence: Evidence.unit)
                                      .over(Journal.records(records))
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

        def built
          @built ||= [*@queue.map { |item| row_for(item, deferrals, held: false) },
                      *@signoff.held_items.map { |item| row_for(item, holds, held: true) }]
        end

        def row_for(item, records, held:)
          deferral = records.fetch(address(item)) { raise UnreadableRecord, orphan_message(item) }
          parked_at = parked_at(deferral, item)
          Row.new(item:, parked_at:, waited: waited(parked_at, item), reason: deferral["reason"],
                  question: question_of(item), spiked: evidence.key?(address(item)), tests: tests_of(item), held:)
        end

        def question_of(item) = evidence.dig(address(item), "question") || parks.dig(address(item), "summary")

        def tests_of(item)
          sha = parks.dig(address(item), "sha")
          ran = sha && test_runs[[item.issue_id.to_s, sha]]
          ran && tests_said(ran)
        end

        def tests_said(ran)
          return "not run (#{ran["why"]})" unless ran["ran"]

          counts = [[ran["passed"], "passed"], [ran["failed"], "failed"],
                    [ran["errors"], "error".pluralize(ran["errors"])]]
          counts.select { |number, word| word == "passed" || number.to_i.positive? }
                .map { |number, word| "#{number} #{word}" }.join(", ")
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

        def deferrals = @maps[:deferrals].value

        def holds = @maps[:holds].value

        def parks = @maps[:parks].value

        def test_runs = @maps[:test_runs].value

        def evidence = @maps[:evidence].value

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
