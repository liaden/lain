# frozen_string_literal: true

module Lain
  module Review
    class Session
      # The fold that rebuilds one review round from journaled records --
      # {Epic::Review::Replay}'s shape and discipline: every record is
      # reconstructed through the SAME guard the write side used, so a record that
      # PARSES but cannot be read whole aborts the rebuild rather than being
      # skipped.
      #
      # IT FAILS OPEN FOR A TORN LINE, which the guard does not cover, and the
      # distinction is the whole of what a reader can rely on. A guard here only
      # ever sees a record {Journal.parse} already turned into a Hash;
      # {Journal.records} answers nil for a line that is not JSON at all and
      # filters it away, which is its CONTRACT rather than a lapse -- the fd is
      # shared with Rust tracing spans. A `hunk_marked` line torn by a crash is
      # therefore never seen by the guard below: it is simply gone, and that hunk
      # quietly reads unreviewed again.
      #
      # So two failures that sound alike are refused differently, and only one is
      # refused at all. A record that ARRIVES malformed aborts the whole rebuild,
      # because a skipped mark is exactly the silent wrong answer this chunk keeps
      # finding. A line that never arrives cannot be refused by anything at this
      # tier. Both halves have specs, so neither can quietly become the other.
      #
      # A ROUND IS POSITIONAL, and that is forced. {ChangesetOpened} carries a
      # digest; {HunkMarked} and {AnnotationPlaced} deliberately do not, so
      # nothing but ORDER can say which round a mark belongs to, and the round is
      # "everything after the LAST `changeset_opened`". {CorpusExtended} carries a
      # digest too and is no exception: its digest addresses the WIDENED corpus
      # and says nothing about which round it sits in. That gives three behaviours
      # without a further field on two records:
      #
      # - a restart resumes, because reopening was never journaled;
      # - opening a new round over rewritten commits inherits nothing, because
      #   `#open` writes a new `changeset_opened` and the fold stops there;
      # - the prior round stays readable, because nothing was deleted.
      #
      # It reads the journal and writes NOTHING. {Session.from_journal} builds one
      # of these before it builds a session, so a resume cannot double the record
      # it is reading.
      class Replay
        # The six record types a round is made of.
        #
        # This filter is NOT what makes a foreign record harmless -- {#fold}'s
        # independent type tests already ignore anything else, and a mutation pass
        # proved it by deleting the filter with every example still green. What it
        # actually buys: the round has to be found by POSITION, `#rindex` needs an
        # Array, and `.to_a` on an unfiltered lazy walk would materialize every
        # Rust tracing span in a long session's journal. A bound on what is held,
        # not a correctness guard.
        TYPES = [ChangesetOpened::JOURNAL_TYPE, CorpusExtended::JOURNAL_TYPE, HunkMarked::JOURNAL_TYPE,
                 AnnotationPlaced::JOURNAL_TYPE, ReviewVerdict::JOURNAL_TYPE, ChangesetClosed::JOURNAL_TYPE].freeze

        # @return [ChangesetOpened, nil] the head of the last round, or nil when
        #   the journal opened no review at all
        attr_reader :opened

        # @return [Array<CorpusExtended>] this round's widenings, oldest first
        attr_reader :extensions

        # @return [Array<AnnotationPlaced>] in the order they were journaled,
        #   which is the only order any reader gets
        attr_reader :annotations

        # @return [ReviewVerdict, Verdict::None] the round's judgement -- its
        #   FIRST, see {#fold}
        attr_reader :judgement

        # @param entries [Enumerable<Hash, String>] journal lines or records
        def initialize(entries)
          round = latest_round(Journal.records(entries).select { |record| ours?(record) }.to_a)
          @opened = round.empty? ? nil : opened_from(round.first)
          @pairs = []
          @annotations = []
          @extensions = []
          @judgement = Verdict::None
          @closed = false
          round.drop(1).each { |record| fold(record) }
          @annotations.freeze
          @extensions.freeze
        end

        # @return [Boolean] whether the round was let go without a verdict
        def closed? = @closed

        # Neither judged nor closed: the round a chat still held when this
        # journal stopped. False with no round at all.
        #
        # @return [Boolean]
        def open? = !opened.nil? && judgement.verdict.empty? && !closed?

        # @param target [String] what a round would be opened on
        # @return [Boolean] whether the round is open, and was opened on it
        def open_on?(target) = open? && opened.target == target

        # Every path this round accreted, oldest first -- what a resume walks to
        # rebuild the corpus as it stood, and the only thing that can say so.
        # {Marks} cannot: a mark carries a hunk key and nothing else, and a key
        # is a digest no path reads back out of.
        #
        # @return [Array<String>]
        def paths = extensions.flat_map(&:paths)

        # The address last PUT ON RECORD in this round, which is the opened one
        # until a widening moves it. {Session#regenerated?} holds the changeset
        # as it now stands against this rather than against `opened.digest`, so a
        # deliberate widening does not read afterwards as the ground shifting
        # underneath the human. A round with no extension records -- every
        # `/review` of a branch -- answers exactly what it always did.
        #
        # @param opened [ChangesetOpened] the head of the round, which the caller
        #   holds: {Session.open} builds one this fold never saw
        # @return [String]
        def digest(opened) = [opened.digest, *extensions.map(&:digest)].last

        # Replayed by the SAME sequence of {Marks#mark} calls the live session
        # made, in journal order, so "replay equals live" is true by
        # construction rather than by two implementations agreeing. The last
        # word on a hunk wins, exactly as it does live.
        #
        # @param base_ref [String] the revision the round was opened against
        # @return [Marks]
        def marks(base_ref)
          @pairs.reduce(Marks.new(base_ref:)) { |marks, (hunk_key, state)| marks.mark(hunk_key, state) }
        end

        private

        def ours?(record) = TYPES.include?(record["type"].to_s)

        def latest_round(records)
          index = records.rindex { |record| record["type"].to_s == ChangesetOpened::JOURNAL_TYPE }
          index.nil? ? [] : records[index..]
        end

        def opened_from(record)
          ChangesetOpened.new(source: record["source"], base_ref: record["base_ref"],
                              head_ref: record["head_ref"], digest: record["digest"], target: record["target"])
        end

        # Independent tests rather than a `case`, so there is no branch a further
        # type could fall through into. The round cannot contain a second
        # `changeset_opened` -- it begins at the LAST one -- so no case is
        # unhandled.
        #
        # THE FIRST VERDICT WINS, and that is not a preference. It was last-wins,
        # a rule this fold INVENTED: {Session#submit} refuses a second verdict
        # outright, so a live session's state after two submissions is its first
        # one. Last-wins let replay reach a state the live session would have
        # refused. Two verdicts in one round need two writers on one journal,
        # which `#submit` cannot produce alone but two Sessions over one file can.
        #
        # Ignoring the second rather than RAISING on it is
        # {Epic::Review::Replay#park}'s hard-won rule: a fold aborts where it
        # raises, so a refusal is judged against a prefix of the journal and the
        # round becomes permanently un-rebuildable.
        def fold(record)
          type = record["type"].to_s
          @pairs << mark_pair(record) if type == HunkMarked::JOURNAL_TYPE
          @extensions << extension(record) if type == CorpusExtended::JOURNAL_TYPE
          @annotations << annotation(record) if type == AnnotationPlaced::JOURNAL_TYPE
          keep_first(judgement_of(record)) if type == ReviewVerdict::JOURNAL_TYPE
          close(closure_of(record)) if type == ChangesetClosed::JOURNAL_TYPE
        end

        # Takes the REBUILT record for {#keep_first}'s reason: a malformed close
        # aborts the fold rather than counting.
        def close(_closure) = @closed = true

        # The record is REBUILT before the first-wins rule is applied, never
        # after. Written as `... if type == ... && @judgement.verdict.empty?`
        # the condition short-circuited, so a malformed SECOND verdict was
        # never constructed and so never refused -- the one record in a round
        # that could say anything at all and still fold cleanly, which is
        # exactly the exemption the abort rule exists to have none of.
        def keep_first(judged)
          @judgement = judged if @judgement.verdict.empty?
        end

        def extension(record) = CorpusExtended.new(paths: record["paths"], digest: record["digest"])

        def mark_pair(record)
          marked = HunkMarked.new(hunk_key: record["hunk_key"], state: record["state"])
          [marked.hunk_key, marked.state]
        end

        def annotation(record)
          AnnotationPlaced.new(id: record["id"], path: record["path"], side: record["side"],
                               line: record["line"], anchor_text: record["anchor_text"],
                               text: record["text"], kind: record["kind"],
                               drifted: record["drifted"], revision: record["revision"])
        end

        def closure_of(record)
          ChangesetClosed.new(changeset_digest: record["changeset_digest"], closed_by: record["closed_by"])
        end

        def judgement_of(record)
          ReviewVerdict.new(verdict: record["verdict"], changeset_digest: record["changeset_digest"])
        end
      end
    end
  end
end
