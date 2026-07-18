# frozen_string_literal: true

module Lain
  module Grader
    # The "build it once" substrate GR-2 (T10, selection frequency) and GR-3
    # (T11, outcome-lineage walks) both read from: an offline projection over a
    # Journal's `turn` records pairing every `tool_use` with its outcome.
    #
    # No production writer emits a standalone `tool_result` RECORD -- results
    # ride as `tool_result` content BLOCKS inside the FOLLOWING turn, the same
    # shape {Bench::Session::MemoryReplay#outcomes} already pairs for
    # `memory_write` alone (memory_replay.rb:77). This generalizes that recipe
    # from "one tool name, is_error only" to "every tool, the full outcome",
    # without coupling to it -- MemoryReplay stays private and untouched.
    #
    # Pairing keys on `tool_use_id`, never `name`: a turn of parallel_safe?
    # tools (Agent::ToolRunner#gather) yields two `tool_use` blocks sharing a
    # name, and only the id is unique, so name-keying would silently merge
    # them.
    #
    #   ToolCallIndex.new(Journal.records(entries)).calls.fetch(turn_digest)
    #   #=> [Call(tool_use_id: "tu_1", name: "echo", args: {...}, is_error: false, result: "hi")]
    class ToolCallIndex
      include Enumerable

      # A referenced predecessor (a turn's `parent` or root `spawned_from`)
      # names a digest absent from this index's entry set -- {Bench::Session::Corrupt}'s
      # precedent, applied to lineage: a partial journal slice must never
      # read as a shorter-but-genuine chain root, or GR-3 (T11) could not
      # tell the two apart.
      class DanglingLineage < Error; end

      # One paired call, keyed by the issuing (assistant) turn's digest in
      # {#calls}. `is_error`/`result` are nil for a `tool_use` with no
      # recorded outcome -- it never executed, so nothing is fabricated for
      # it (the `== false` precedent {Bench::Session::MemoryReplay#write_calls}
      # already established).
      #
      # `tool_use_id`/`name`/`args`/`result` are run through
      # {Canonical.normalize} regardless of source, so every field is deeply
      # frozen even when built from plain JSON.parse output (the real
      # production path, `Journal.records(File.foreach(path))`, freezes
      # nothing -- unlike an in-memory `Turn#content`, which normalizes on
      # construction). {#calls} is memoized, so every reader shares these
      # same Call objects; without this, one caller mutating `call.args` in
      # place would leak into every later read -- the {Memory::Item}
      # precedent for "value objects are deeply frozen" applied here.
      Call = Data.define(:tool_use_id, :name, :args, :is_error, :result)

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      def initialize(entries)
        @turns = Journal.records(entries, type: "turn").to_a.freeze
        @by_digest = @turns.to_h { |record| [record.fetch("digest"), record] }.freeze
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
      # view a selection-frequency fold (GR-2) wants. `Enumerable` rides this.
      def each(&block)
        return enum_for(:each) unless block_given?

        calls.each_value { |paired| paired.each(&block) }
      end

      # The causal lineage of `turn_digest`: itself, then each render-parent
      # within its own chain, and -- at a chain root whose meta names
      # `spawned_from` -- the turn it was spawned from, continuing the walk
      # into the PARENT chain. This is how GR-3 resolves an outcome back to
      # its causing turn across a fan-out: the walk follows the content
      # addresses the records carry (`parent`, `meta.spawned_from`), never
      # the order entries happen to sit in the journal, so it agrees no
      # matter how the parent and child chains were interleaved on disk.
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
      # this index actually has -- {DanglingLineage} names the missing
      # digest rather than the walk silently ending one step early.
      def record_for(digest)
        @by_digest.fetch(digest) do
          raise DanglingLineage, "lineage references turn #{digest.inspect}, which is absent from " \
                                 "this entry set -- a dangling predecessor reads as a corrupted or " \
                                 "partial journal slice, never as a chain root"
        end
      end

      # A turn's render-parent within its own chain, or -- only at a root,
      # where there is no render-parent -- the turn named by its
      # `spawned_from` meta. `||` is exactly this precedence: a non-root turn
      # always has a `parent` and is never consulted for `spawned_from`. A
      # digest present with NEITHER field is a legitimate root and answers
      # nil here without raising -- {DanglingLineage} is for a predecessor
      # digest that is itself absent from the entry set, not for the absence
      # of a predecessor field.
      def predecessor(record)
        record["parent"] || record.dig("meta", "spawned_from")
      end

      def tool_uses(record)
        blocks(record).select { |block| block["type"] == "tool_use" }
      end

      def blocks(record)
        content = record.fetch("content")
        content.is_a?(Array) ? content.grep(Hash) : []
      end

      def pair(tool_use)
        outcome = outcomes[tool_use["id"]]
        Call.new(tool_use_id: Canonical.normalize(tool_use["id"]), name: Canonical.normalize(tool_use["name"]),
                 args: Canonical.normalize(tool_use["input"]), is_error: outcome && outcome["is_error"],
                 result: outcome && Canonical.normalize(outcome["content"]))
      end

      # tool_use_id => its tool_result block, across the WHOLE entry set: a
      # result answers its tool_use from a later turn (its own chain or a
      # spawned one), and ids are unique within a run, so one flat map is the
      # pairing -- {Bench::Session::MemoryReplay#outcomes}'s recipe,
      # generalized from "is_error only" to the full block. Two tool_result
      # blocks sharing a tool_use_id should never happen (ids are unique per
      # run), but `Hash#to_h` resolves it last-write-wins (journal order) if
      # it ever did, the same silent-tolerance shape `Hash#merge` gives every
      # other fold in this codebase -- never a raise, since a duplicate id
      # is a wire anomaly to investigate, not a corrupt-lineage signal.
      def outcomes
        @outcomes ||= @turns.flat_map { |record| blocks(record) }
                            .select { |block| block["type"] == "tool_result" }
                            .to_h { |block| [block["tool_use_id"], block] }
      end
    end
  end
end
