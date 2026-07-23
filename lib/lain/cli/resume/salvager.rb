# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # T18: computes and, on recovery, WRITES the salvage outcome for one
      # OPEN file -- a real, separate responsibility from the rest of Resume
      # (selecting a file, refusing a mid-tool head, building notices), split
      # into its own file per CLAUDE.md's Metrics/ClassLength guidance ("extract
      # a collaborator", never loosen the limit) -- a nested class in the SAME
      # file would still count toward Resume's own line total, since the cop
      # measures the class NODE, not the file.
      #
      # T3's fork-mode invariant: a fork NEVER constructs a Salvager. Only
      # {Resume#salvage}, on the resume path proper, builds one; {Resume#fork}
      # holds nothing but read-only `File.foreach` enumerators, because the
      # close anchor {#close!} appends would corrupt a LIVE parent's chain for
      # every future reader. spec/lain/cli/resume_spec.rb pins the invariant.
      #
      # {#close!} retroactively closes the crashed file -- the recovered turn,
      # the salvage record, and a `session_closed` anchor naming its head --
      # turning an open (SIGKILLed) file into an ordinary closed one.
      # {Resume#rebuild}'s own comment says why: the rest of Resume then
      # reuses the SAME {Bench::Session::Loader}/{Bench::Session::Anchor}
      # machinery every other closed session already proves, rather than
      # growing a parallel "open-plus-salvaged" shape those classes would
      # have to learn.
      class Salvager
        # @param path [String] the OPEN session file's own path
        # @param timeline [Lain::Timeline] its loaded (pre-salvage) Timeline
        def initialize(path:, timeline:)
          @path = path
          @timeline = timeline
        end

        # @return [SessionRecord::Salvage::Nothing, Recovered, Incomplete]
        def outcome
          @outcome ||= SessionRecord::Salvage.new(entries: File.foreach(@path), frames: wal_frames,
                                                  timeline: @timeline).call
        end

        # Appends the salvage record, the recovered turn, and a
        # `session_closed` anchor -- in that order, so a reader mid-write
        # (a second crash) sees either nothing new or a self-consistent
        # prefix, never a `turn` record with no matching `salvaged` line
        # explaining it.
        #
        # A SECOND crash landing after the `turn` write but before this very
        # append completes is exactly what {#outcome}'s idempotency check
        # (see {SessionRecord::Salvage#already_committed?}) exists for: the
        # re-resume that follows hands {SessionRecord::Salvage} a Timeline
        # that already ends with the recovered content, so `outcome` comes
        # back `newly_committed?` false and {#closing_records} writes ONLY
        # the anchor -- the one record that crash actually left missing,
        # never a second `salvaged`/`turn` pair onto an already-recovered
        # head (the panel's reproduced blocker).
        #
        # @param head_before [String, nil] the Timeline head before recovery
        def close!(head_before:)
          journal = Journal.open(@path, fsync: true)
          closing_records(head_before).each { |record| journal << record }
        ensure
          journal&.close
        end

        private

        def closing_records(head_before)
          anchor = Telemetry::SessionClosed.new(head: outcome.turn.digest, reason: :salvaged)
          return [anchor] unless outcome.newly_committed?

          [Telemetry::Salvaged.new(request_digest: outcome.request_digest, head_before:,
                                   head_after: outcome.turn.digest),
           SessionRecord.turn(outcome.turn),
           anchor]
        end

        # The TOLERANT enumeration: a mis-slotted region (a legacy interleaved
        # WAL) surfaces as a skipped-region notice through {SessionRecord::Salvage},
        # never a raise that would abort recovery of a clean frame written after
        # it -- losing a paid-for response to corruption elsewhere in the file.
        def wal_frames
          Provider::ResponseWal.new(wal_path).salvageable_frames
        end

        # {Paths.wal_for} is the one naming authority; {CLI::Chronicle#spool}
        # writes to the same derivation on the session's own path. One
        # fallback (T3 fix round): a crash BETWEEN promotion's two renames
        # (WAL first) leaves a still-marked `.btw.ndjson` whose wal already
        # wears the promoted name -- the derived path is then absent and the
        # paid-for frames would sit unreachable, with nothing ever triggering
        # the promotion retry. Salvage of a marked journal therefore falls
        # back to the promoted sibling basename when its own is missing.
        def wal_path
          derived = Paths.wal_for(@path)
          return derived if File.exist?(derived) || !Paths.ephemeral?(@path)

          promoted = Paths.wal_for(Paths.promoted_for(@path))
          File.exist?(promoted) ? promoted : derived
        end
      end
    end
  end
end
