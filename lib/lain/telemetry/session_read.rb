# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A read record must name the file read, the lines it covered and the
      # call that carried it. Checked strictly, because a salvaged or
      # hand-edited journal is exactly what these records must survive, and a
      # span read loosely rebuilds as more of the file than the model saw.
      class SessionRead < Declarative::Carrier
        IDENTITY_MEMBERS = %w[device inode mtime size].freeze

        attribute :path
        attribute :lines
        attribute :identity
        attribute :tool_use_id
        attribute :head
        validates :path, presence: { message: "must name the file read, got nil" }
        validate :lines_name_a_span
        validate :identity_names_a_version
        validate :call_is_named_by_strings

        private

        # `[first, last]`, with `last` nil for a read that reached the end of
        # the file -- the journal's spelling of {Session::WHOLE_FILE}'s Range.
        def lines_name_a_span
          first, last = lines if lines.is_a?(Array) && lines.size == 2
          return if first.is_a?(Integer) && first >= 1 && (last.nil? || (last.is_a?(Integer) && last >= first))

          errors.add(:lines, "must be [first, last] line numbers from 1, last nil at end of file, got #{lines.inspect}")
        end

        # Exactly {Session::FileIdentity}'s members, each an Integer or nil: a
        # replay rebuilds the version from these, and a version it cannot
        # rebuild is refused here, where it is written, not on resume.
        def identity_names_a_version
          return if identity.is_a?(Hash) && identity.keys.sort == IDENTITY_MEMBERS &&
                    identity.values.all? { |value| value.nil? || value.is_a?(Integer) }

          errors.add(:identity, "must carry exactly #{IDENTITY_MEMBERS.join(", ")}, each an Integer or nil, " \
                                "got #{identity.inspect}")
        end

        def call_is_named_by_strings
          { tool_use_id:, head: }.each do |name, value|
            errors.add(name, "must be a String or nil, got #{value.inspect}") unless value.nil? || value.is_a?(String)
          end
        end
      end
    end

    # One read that added lines to what the model had seen of a file's version.
    # Emitted by {Session} as it records, never by the Agent or a tool.
    # `path` is the normalized form {Session} keys its read-set on, so
    # {SessionRecord::Replay} feeds it straight back into a fresh Session with
    # no re-normalization. A RE-read of lines already seen lands no second
    # record, which is what keeps a big read/edit loop from journaling one line
    # per iteration.
    #
    # `tool_use_id` and `head` are what let a replay count the read only on the
    # chain that delivered it: the replay binds the read to the next recorded
    # turn whose parent is `head` and whose `tool_result` answers that call.
    # `identity` is the file version, as {Session::FileIdentity}'s members, so
    # windows add up only over one.
    SessionRead = Data.define(:path, :lines, :identity, :tool_use_id, :head) do
      include Journalable

      # @param path [String] an already-normalized path
      # @param read [Session::ReadSet::Read]
      # @return [SessionRead]
      def self.of(path, read)
        new(path:, lines: [read.lines.begin, read.lines.end], identity: read.identity.to_h.transform_keys(&:to_s),
            tool_use_id: read.tool_use_id, head: read.head)
      end

      def initialize(path:, lines:, identity:, tool_use_id:, head:)
        super(**Carriers::SessionRead.settle!(path:, lines:, identity:, tool_use_id:, head:))
      end
    end
  end
end
