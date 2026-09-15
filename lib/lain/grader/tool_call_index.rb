# frozen_string_literal: true

module Lain
  module Grader
    # The "build it once" substrate the selection-frequency detector and the
    # outcome-lineage walks both read from: an offline projection over a
    # Journal's `turn` records pairing every `tool_use` with its outcome.
    #
    # No production writer emits a standalone `tool_result` RECORD -- results
    # ride as `tool_result` content BLOCKS inside the FOLLOWING turn, the shape
    # {Bench::Session::MemoryReplay#outcomes} already pairs for `memory_write`
    # alone. This generalizes that recipe from "one tool name, is_error only" to
    # "every tool, the full outcome", without coupling to it.
    #
    # Pairing keys on `tool_use_id`, never `name`: a turn of parallel_safe?
    # tools yields two `tool_use` blocks sharing a name, and only the id is
    # unique, so name-keying would silently merge them.
    #
    #   ToolCallIndex.new(Journal.records(entries)).calls.fetch(turn_digest)
    #   #=> [Call(tool_use_id: "tu_1", name: "echo", args: {...}, is_error: false, result: "hi")]
    class ToolCallIndex
      include Enumerable

      # One paired call, keyed by the issuing turn's digest in {#calls}.
      # `is_error`/`result` are nil for a `tool_use` with no recorded outcome:
      # it never executed, so nothing is fabricated for it.
      #
      # Every field is run through {Canonical.normalize} regardless of source,
      # so it is deeply frozen even when built from plain JSON.parse output --
      # the real production path, `Journal.records(File.foreach(path))`, freezes
      # nothing, unlike an in-memory `Turn#content`. {#calls} is memoized, so
      # every reader shares these same Call objects and one caller mutating
      # `call.args` in place would otherwise leak into every later read.
      Call = Data.define(:tool_use_id, :name, :args, :is_error, :result)

      # A subagent's turns are indexed beside the parent's. They are no `turn`
      # records -- a chat records them as `child_turn`s under a `:spawn` -- so
      # they come from {Bench::Session::Lineages}, in the `turn` record shape
      # everything below reads.
      #
      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @param lineages [Enumerable<Bench::Session::Lineages::Lineage>] the
      #   subagent lineages `entries` record; read off them by default
      def initialize(entries, lineages: Bench::Session::Lineages.recorded_in(entries))
        records = Journal.records(entries).to_a
        own = records.select { |record| record["type"].to_s == "turn" }
        read = lineages.to_a
        @turns = (own + child_records(read)).uniq { |record| record.fetch("digest") }.freeze
        @by_digest = @turns.to_h { |record| [record.fetch("digest"), record] }.freeze
        @spawned_from = spawn_edges(read, own.to_set { |record| record.fetch("digest") })
        @continued = continued_heads(records)
      end

      # @return [Hash{String=>Array<Call>}] issuing turn digest => its paired
      #   calls, in `tool_use` order. A turn that issued no `tool_use` is
      #   absent -- never present with an empty Array a caller must filter.
      def calls
        @calls ||= @turns.each_with_object({}) do |record, index|
          paired = tool_uses(record).map { |block| pair(block) }
          index[record.fetch("digest")] = paired.freeze unless paired.empty?
        end.freeze
      end

      # Every paired call, in turn order then `tool_use` order -- the flat
      # view a selection-frequency fold wants. `Enumerable` rides this.
      def each(&block)
        return enum_for(:each) unless block_given?

        calls.each_value { |paired| paired.each(&block) }
      end

      # The causal lineage of `turn_digest`: itself, then each render-parent
      # within its own chain, and -- at a subagent's root -- the parent turn its
      # spawn ran from, continuing into the PARENT chain. The walk follows the
      # content addresses the records carry, never the order entries happen to
      # sit in the journal, so it agrees no matter how the parent and child
      # chains were interleaved on disk.
      #
      # @param turn_digest [String]
      # @return [Enumerator<String>] turn digests, nearest first
      def lineage(turn_digest)
        return enum_for(:lineage, turn_digest) unless block_given?

        digest = turn_digest
        while digest
          record = record_for(digest)
          yield digest
          digest = predecessor(record)
        end
      end

      private

      # Every digest the walk visits is validated BEFORE it is yielded, so a
      # dangling predecessor never gets treated as (or yielded as) a turn
      # this index actually has -- the refusal below names the missing
      # digest rather than the walk silently ending one step early.
      def record_for(digest)
        @by_digest.fetch(digest) do
          # A referenced predecessor (a turn's `parent` or a child root's spawn
          # point) names a digest absent from this index's entry set. Loud, because a
          # partial journal slice must never read as a shorter-but-genuine chain
          # root -- the lineage walk could not tell the two apart.
          raise Error, "lineage references turn #{digest.inspect}, which is absent from " \
                       "this entry set -- a dangling predecessor reads as a corrupted or " \
                       "partial journal slice, never as a chain root"
        end
      end

      # A turn's render-parent within its own chain, or -- only at a root,
      # where there is no render-parent -- the parent turn its spawn ran from.
      # `||` is exactly this precedence: a non-root turn always has a `parent`
      # and is never looked up as a spawn's root. A digest present with NEITHER
      # is a legitimate root and answers nil here without raising -- the
      # dangling-lineage refusal is for a predecessor digest that is itself
      # absent from the entry set, not for the absence of a predecessor.
      def predecessor(record)
        digest = record["parent"] || @spawned_from[record.fetch("digest")]
        @continued.include?(digest) ? nil : digest
      end

      # Where a resumed file's own turns continue a chain its prior files hold:
      # the head it resumed from, and any turn it rewound to. A walk ends there
      # -- this entry set is one file -- rather than refusing a head that is
      # not missing, only recorded elsewhere. A file that resumes nothing
      # continues nothing, so there its rewound targets are its own turns and
      # a missing one is still a hole.
      def continued_heads(records)
        resumed = records.filter_map { |record| record.dig("resumed_from", "head") if record["type"] == "session" }
        return Set.new.freeze if resumed.empty?

        rewound = records.filter_map { |record| record["to"] if record["type"] == SessionRecord::REWOUND_TYPE }
        (resumed + rewound).reject { |digest| @by_digest.key?(digest) }.to_set.freeze
      end

      def child_records(lineages)
        lineages.flat_map { |lineage| lineage.child_turns.map { |turn| SessionRecord.turn(turn) } }
      end

      # child root digest => the parent turn its spawn ran from. An inheriting
      # child's lowest turn renders onto that turn already, so only a root needs
      # the edge, and only onto a turn this index holds: a spawn from a child
      # still running names a turn no completed lineage carries, and the walk
      # ends at the root rather than at a turn it cannot see. Content addressing
      # makes two more cases ambiguous, and both get none: a root that is ALSO a
      # turn of the session's own chain (a fresh child seeded with the human's
      # opening text commits that very turn), and a root two spawns from
      # different heads share. An edge from either could walk the lineage back
      # onto a chain it came from, and never end.
      def spawn_edges(lineages, own)
        spawn_roots(lineages).group_by { |root, _head| root.digest }
                             .transform_values { |claims| claims.map(&:last).uniq }
                             .reject { |root, heads| own.include?(root) || heads.size > 1 }
                             .transform_values(&:first)
                             .select { |_root, head| @by_digest.key?(head) }.freeze
      end

      # [child root, the turn its spawn ran from], for every child that has a
      # root of its own.
      def spawn_roots(lineages)
        lineages.map { |lineage| [lineage.child_turns.first, lineage.spawned_from] }
                .select { |root, _head| !root.nil? && root.parent.nil? }
      end

      # The `type` test is a raw key read and stays one: {Response::ToolUse.wrap}
      # accepts any Hash and checks no type, so a block must be KNOWN a tool_use
      # before it is lensed -- a text block put behind this lens would raise on
      # a `name` it was never going to carry.
      def tool_uses(record)
        blocks(record).select { |block| block["type"] == "tool_use" }
                      .map { |block| Response::ToolUse.wrap(block) }
      end

      def blocks(record)
        content = record.fetch("content")
        content.is_a?(Array) ? content.grep(Hash) : []
      end

      # Every field is normalized from the object the lens hands back, which is
      # the object the block already holds -- {Response::ToolUse#input} and
      # {Tool::ResultBlock#content} read through `fetch`, they do not rebuild --
      # so the Call's fields are what they were before the lens went on.
      def pair(tool_use)
        outcome = outcomes[tool_use.id]
        Call.new(tool_use_id: Canonical.normalize(tool_use.id), name: Canonical.normalize(tool_use.name),
                 args: Canonical.normalize(tool_use.input), is_error: outcome&.error?,
                 result: outcome && Canonical.normalize(outcome.content))
      end

      # tool_use_id => its tool_result block, across the WHOLE entry set: a
      # result answers its tool_use from a later turn, and ids are unique within
      # a run, so one flat map is the pairing. Two tool_result blocks sharing an
      # id should never happen, and `Hash#to_h` resolves it last-write-wins
      # rather than raising -- a duplicate id is a wire anomaly to investigate,
      # not a corrupt-lineage signal.
      #
      # The `type` test is a raw key read for the reason {#tool_uses} gives, and
      # here it is load-bearing: a turn mixes text blocks in with its results,
      # and behind the lens those would raise.
      def outcomes
        @outcomes ||= @turns.flat_map { |record| blocks(record) }
                            .select { |block| block["type"] == "tool_result" }
                            .map { |block| Tool::ResultBlock.wrap(block) }
                            .to_h { |block| [block.tool_use_id, block] }
      end
    end
  end
end
