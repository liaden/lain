# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A read refusal must name why it refused AND which path it refused.
      # Widens {WriteRefused}'s "name what matched, never the matched bytes"
      # contract to also require `path`: the path itself can be the finding
      # (`/home/joel/.ssh/id_ed25519`), and a refusal a reader cannot attribute
      # to a file is not actionable.
      class ReadRefused < Guard
        attribute :path
        attribute :reason
        attribute :tool
        validates :path, presence: { message: "must name the refused path, got nil" }
        validates :reason, presence: { message: "must name what refused, got nil" }
        # The record covers writers as well as readers, so a Journal reader
        # tallying by verb needs the tool NAME rather than having to infer one
        # from the record's own. Required, not optional: a refusal that cannot
        # say which call it refused is the same unattributable record `path`
        # exists to prevent.
        validates :tool, presence: { message: "must name the refused tool, got nil" }
      end

      # A redaction record must carry two non-negative Integer COUNTS, never
      # anything else -- {Guards::Dropped}'s shape (the exact reuse target the
      # card named), doubled onto `regions`/`released`. Without this, `Data`
      # freezing the record but never its members let a mutable String
      # ("3") or a Hash of leaked bytes sail straight through, both silently
      # breaking `Ractor.shareable?` and, for the Hash case, defeating the
      # entire point of a record whose job is counts instead of content.
      #
      # `released <= regions` is asserted too: released is a SUBSET of what
      # was found, so "released > regions" is not an unsafe value, it is an
      # impossible one -- shape, same as every other guard here, not a second
      # security check layered on top.
      class ReadRedacted < Guard
        attribute :path
        attribute :regions
        attribute :released
        # {ReadRefused} validates `path` for a record that only DESCRIBES a
        # refusal; this one now drives a control. `SessionRecord::Replay` folds
        # a `read_redacted` back into the masked read-set, so a record with no
        # path is a mask applied to `path.to_s` -> `""` -> whatever the resume's
        # cwd normalizes to: the mask lands on a directory, the file it was
        # meant to protect reads back as wholly seen, and `write_file` replaces
        # the secret with its own placeholder. Not reachable from the live
        # writer, which always has a resolved path -- but a salvaged or
        # hand-edited journal is exactly what these records exist to survive
        # (`replay.rb`'s own doctrine), and that is where an unguarded field
        # gets its value.
        validates :path, presence: { message: "must name the redacted path, got nil" }
        validates :regions, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                            message: "must be a non-negative Integer, got %<value>s" }
        validates :released, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                             message: "must be a non-negative Integer, got %<value>s" }
        validate :released_within_regions

        private

        # Skipped when either count already failed numericality above: a Hash
        # has no `#to_i` a raw comparison could fall back on, and the
        # numericality error already names the real problem.
        def released_within_regions
          return if errors[:regions].any? || errors[:released].any?
          return if released.to_i <= regions.to_i

          errors.add(:released, "must be <= regions (#{regions}), got #{released}")
        end
      end
    end

    # ANY tool call refused at the path boundary before the tool ran -- T12's
    # denial path, and {WriteRefused}'s counterpart on the read side of the
    # house. `reason` names WHAT refused (a pattern name or a declined
    # judgment), never the file's bytes, matching {WriteRefused}'s discipline;
    # `path` is the deliberate widening documented on {Guards::ReadRefused}.
    # `path` is coerced with `to_s` because T12 plausibly hands this a
    # `Pathname`, and an uncoerced one would leave the in-process field and the
    # journaled JSON string disagreeing.
    #
    # It is NOT reads only, though the name says so.
    # {Sensitivity::Policy::PATH_FIELDS} names `write_file`, `edit_file`, `bash`
    # and `core_exec` beside the readers, and refusing a WRITE to
    # `~/.ssh/id_ed25519` is as much this boundary's job as refusing a read --
    # so `tool` carries the verb and a Journal reader tallies on it rather than
    # counting a refused write as a refused read. The derived type stays
    # `read_refused`: renaming a shipped record mid-chunk would break every
    # replay reader keyed on it, to fix a word.
    ReadRefused = Data.define(:tool_use_id, :tool, :path, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, reason:)
        Guards::ReadRefused.check!(path:, reason:, tool:)

        super(tool_use_id: tool_use_id.dup.freeze, tool: tool.to_s.dup.freeze,
              path: path.to_s.dup.freeze, reason: reason.dup.freeze)
      end
    end

    # A `read` whose bytes were released with some regions masked -- T15's
    # redaction path. `regions` and `released` are COUNTS, never the masked or
    # released bytes themselves: the same "name what matched, never the
    # matched bytes" discipline {WriteRefused} established for a full refusal,
    # extended here to a partial release. Coerced to `Integer` with `to_i`
    # rather than passed through raw: {Guards::ReadRedacted} has already
    # proven the value numeric by the time this runs, so the coercion only
    # ever normalizes a numeric-looking String (or an actual Integer) to the
    # frozen-by-nature Integer the record must hold to stay
    # `Ractor.shareable?`.
    ReadRedacted = Data.define(:tool_use_id, :path, :regions, :released) do
      include Journalable

      def initialize(tool_use_id:, path:, regions:, released:)
        Guards::ReadRedacted.check!(path:, regions:, released:)

        super(tool_use_id: tool_use_id.dup.freeze, path: path.to_s.dup.freeze,
              regions: regions.to_i, released: released.to_i)
      end
    end
  end
end
