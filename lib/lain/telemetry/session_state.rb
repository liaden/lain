# frozen_string_literal: true

module Lain
  module Telemetry
    # The run-state records, all emitted by {Session} as it records -- so
    # neither the Agent nor any tool ever constructs one directly.

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

      # Each withheld round is a `[head, call id]` pair: the head a nil or a
      # String, the call id a String -- the key a read's round is found by.
      class SessionReadWithheld < Declarative::Carrier
        attribute :rounds
        validate :rounds_name_head_and_call

        private

        def rounds_name_head_and_call
          return if rounds.is_a?(Array) && !rounds.empty? && rounds.all? { |round| round?(round) }

          errors.add(:rounds, "must be a non-empty list of [head, call id] pairs, got #{rounds.inspect}")
        end

        def round?(round)
          round.is_a?(Array) && round.size == 2 && (round.first.nil? || round.first.is_a?(String)) &&
            round.last.is_a?(String)
        end
      end

      # A pin record must name the turn it pins and say WHICH WAY the pin
      # moved, as a real boolean -- `presence:` would silently reject `false`,
      # which is exactly the retraction this record exists to express (the
      # same reasoning {RequestSent}'s `stream` carries).
      class SessionPin < Declarative::Carrier
        attribute :digest
        attribute :pinned
        validates :digest, presence: { message: "must name the turn it pins, got nil" }
        validates :pinned, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One read that added lines to what the model had seen of a file's version.
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

    # The rounds {Session#on_chain} withheld because no turn delivered them:
    # a marker, carrying no bytes and no path, that lets {SessionRecord::Replay}
    # withhold the same rounds at the same point in the record rather than bind
    # them to a later delivery from the same head. Written only when a round
    # really was left open, which an ordinary run never does.
    SessionReadWithheld = Data.define(:rounds) do
      include Journalable

      def initialize(rounds:) = super(**Carriers::SessionReadWithheld.settle!(rounds:))
    end

    # One pin transition, recorded so a `--resume` rebuilds the pin-set. A LOG
    # line, not a set member: `pinned` carries the DIRECTION, because a pin
    # followed by an unpin must rebuild as not pinned and a shape that could
    # only say "pinned" could not express the retraction at all.
    # {SessionRecord::Replay} folds these in recorded order, so the last
    # transition for a digest wins by construction.
    #
    # `digest` names a committed Turn, never a path: pins protect turns from
    # compaction, and the digest is what a compaction source matches on.
    SessionPin = Data.define(:digest, :pinned) do
      include Journalable

      def initialize(digest:, pinned:) = super(**Carriers::SessionPin.settle!(digest:, pinned:))
    end

    # The run's ENTIRE todo list, one record per {Tools::TodoWrite} call,
    # matching {Session#write_todos}'s replace-not-merge semantics -- so folding
    # every record in order and keeping the last one's effect IS that contract
    # applied N times, and {SessionRecord::Replay} needs no merge logic.
    TodoSnapshot = Data.define(:todos) do
      include Journalable
      include Declarative

      # Anonymous (`declare`) rather than a named {Carriers} entry because
      # there is no validation here for a reader to go and look up.
      declare do
        attribute :todos, :lain_canonical
      end

      # Built from the duck {Session#write_todos} itself accepts, so the caller
      # hands over the list it already has rather than pre-shaping it.
      def self.from(todos)
        new(todos: todos.map { |todo| { "content" => todo.content, "status" => todo.status } })
      end

      # Explicit keyword: `Canonical.normalize(nil)` is nil, so `new` with no
      # argument would journal `{"todos": null}` as a valid record.
      def initialize(todos:) = super(**self.class.settle!(todos:))
    end
  end
end
