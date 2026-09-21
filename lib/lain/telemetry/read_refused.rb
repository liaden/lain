# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A read refusal must name why it refused AND which path it refused.
      # Widens {WriteRefused}'s "name what matched, never the matched bytes"
      # contract to also require `path`: the path itself can be the finding
      # (`/home/joel/.ssh/id_ed25519`), and a refusal a reader cannot attribute
      # to a file is not actionable.
      class ReadRefused < Declarative::Carrier
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
    end

    # ANY tool call refused at the path boundary before the tool ran -- the path
    # gate's denial path, and {WriteRefused}'s counterpart on the read side of the
    # house. `reason` names WHAT refused (a pattern name or a declined
    # judgment), never the file's bytes, matching {WriteRefused}'s discipline;
    # `path` is the deliberate widening documented on {Carriers::ReadRefused}.
    # `path` is coerced with `to_s` because the gate plausibly hands this a
    # `Pathname`, and an uncoerced one would leave the in-process field and the
    # journaled JSON string disagreeing.
    #
    # It is NOT reads only, though the name says so: refusing a WRITE to
    # `~/.ssh/id_ed25519` is as much this boundary's job, so `tool` carries the
    # verb and a Journal reader tallies on it rather than counting a refused
    # write as a refused read. The derived type stays `read_refused`, because
    # renaming a shipped record would break every replay reader keyed on it to
    # fix a word.
    ReadRefused = Data.define(:tool_use_id, :tool, :path, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, reason:)
        Carriers::ReadRefused.check!(path:, reason:, tool:)

        super(tool_use_id: tool_use_id.dup.freeze, tool: tool.to_s.dup.freeze,
              path: path.to_s.dup.freeze, reason: reason.dup.freeze)
      end
    end
  end
end
