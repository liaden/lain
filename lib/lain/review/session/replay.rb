# frozen_string_literal: true

module Lain
  module Review
    class Session
      # The fold that rebuilds one review round from journaled records --
      # {Epic::Review::Replay}'s shape, and its discipline: every record is
      # reconstructed through the SAME guard the write side used, so a record
      # that PARSES but cannot be read whole aborts the rebuild rather than
      # being skipped.
      #
      # == It fails OPEN for a torn line, which the guard does not cover
      #
      # This paragraph replaces a claim that was false, and the distinction it
      # draws is the whole of what a reader can rely on. A guard here only ever
      # sees a record {Journal.parse} already turned into a Hash;
      # {Journal.records} answers nil for a line that is not JSON at all and
      # filters it away, which is its CONTRACT rather than a lapse -- the fd is
      # shared with Rust tracing spans, so a reader skips somebody else's bytes
      # instead of raising over them. A `hunk_marked` line torn by a crash is
      # therefore never seen by the guard below: it is simply gone, and that
      # hunk quietly reads unreviewed again.
      #
      # So two failures that sound alike are refused differently, and only one
      # is refused at all. A record that ARRIVES malformed -- a blank
      # `hunk_key`, a `line` of 0, a `kind` outside the vocabulary -- aborts the
      # whole rebuild, because a skipped mark is exactly the silent wrong answer
      # this chunk keeps finding. A line that never arrives cannot be refused by
      # anything at this tier; {Epic::Review.from_journal} records the same
      # limitation about its own baton for the same reason. Both halves have
      # specs, so neither can quietly become the other.
      #
      # == A round is POSITIONAL, and that is forced
      #
      # {ChangesetOpened} carries a digest; {HunkMarked} and {AnnotationPlaced}
      # deliberately do not. So nothing but ORDER can say which round a mark
      # belongs to, and the round is "everything after the LAST
      # `changeset_opened`". That gives the three behaviours the card asks for
      # without a fourth field on two records:
      #
      # - a restart resumes, because reopening was never journaled and the last
      #   round is still the live one;
      # - opening a new round over rewritten commits inherits nothing, because
      #   `#open` writes a new `changeset_opened` and the fold stops there --
      #   annotations are round-scoped, produced then consumed then historical,
      #   and nothing re-anchors them forward;
      # - the prior round stays readable, because nothing was deleted.
      #
      # It reads the journal and writes NOTHING. {Session.from_journal} builds
      # one of these before it builds a session, so a resume cannot double the
      # record it is reading.
      class Replay
        # The four record types a round is made of.
        #
        # This filter is NOT what makes a foreign record harmless -- {#fold}'s
        # three independent type tests already ignore anything that is not one
        # of these, and a mutation pass proved it by deleting the filter with
        # every example still green. Claiming it as a defence would be claiming
        # a defence the code does not need, so here is what it actually buys:
        # the round has to be found by POSITION, `#rindex` needs an Array, and
        # `.to_a` on an unfiltered lazy walk would materialize every Rust
        # tracing span in a long session's journal alongside our four. It is a
        # bound on what is held, not a correctness guard.
        TYPES = [ChangesetOpened::JOURNAL_TYPE, HunkMarked::JOURNAL_TYPE,
                 AnnotationPlaced::JOURNAL_TYPE, ReviewVerdict::JOURNAL_TYPE].freeze

        # @return [ChangesetOpened, nil] the head of the last round, or nil when
        #   the journal opened no review at all
        attr_reader :opened

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
          @judgement = Verdict::None
          round.drop(1).each { |record| fold(record) }
          @annotations.freeze
        end

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
                              head_ref: record["head_ref"], digest: record["digest"])
        end

        # Three independent tests rather than a `case`, so there is no branch a
        # fourth type could fall through into, and any record that is none of
        # the three is ignored here rather than upstream. The round cannot
        # contain a second `changeset_opened` -- it begins at the LAST one -- so
        # no case is unhandled.
        #
        # == The FIRST verdict wins, and that is not a preference
        #
        # It was last-wins, which was a rule this fold INVENTED: {Session#submit}
        # refuses a second verdict outright ({AlreadySettled}), so a live
        # session's state after two submissions is its first one and the second
        # never happened. Last-wins let replay reach a state the live session
        # would have refused -- this card's own escalation trigger about replay
        # diverging from live, arriving in the verdict instead of the mark set.
        # Two verdicts in one round need two writers on one journal, which
        # `#submit` cannot produce alone but two Sessions over one file can.
        #
        # Ignoring the second rather than RAISING on it is {Epic::Review::Replay#park}'s
        # hard-won rule: a fold aborts where it raises, so a refusal is judged
        # against a prefix of the journal and the round becomes permanently
        # un-rebuildable -- the wedge, arriving through the guard meant to
        # prevent it. Agreeing with the live session costs nothing here; raising
        # would cost the resume this whole class exists for.
        def fold(record)
          type = record["type"].to_s
          @pairs << mark_pair(record) if type == HunkMarked::JOURNAL_TYPE
          @annotations << annotation(record) if type == AnnotationPlaced::JOURNAL_TYPE
          keep_first(judgement_of(record)) if type == ReviewVerdict::JOURNAL_TYPE
        end

        # The record is REBUILT before the first-wins rule is applied, never
        # after. Written as `... if type == ... && @judgement.verdict.empty?`
        # the condition short-circuited, so a malformed SECOND verdict was
        # never constructed and so never refused -- the one record in a round
        # that could say anything at all and still fold cleanly, which is
        # exactly the exemption the abort rule exists to have none of.
        def keep_first(judged)
          @judgement = judged if @judgement.verdict.empty?
        end

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

        def judgement_of(record)
          ReviewVerdict.new(verdict: record["verdict"], changeset_digest: record["changeset_digest"])
        end
      end
    end
  end
end
