# frozen_string_literal: true

module Lain
  # T16's run-state records, all emitted by {Session::Journaled} -- the
  # decorator that keeps {Session} itself journal-ignorant, so neither the
  # Agent nor any tool ever constructs one directly.
  module Telemetry
    module Guards
      # A read record must name the file read.
      class SessionRead < Guard
        attribute :path
        validates :path, presence: { message: "must name the file read, got nil" }
      end

      # A pin record must name the turn it pins and say WHICH WAY the pin
      # moved, as a real boolean -- `presence:` would silently reject `false`,
      # which is exactly the retraction this record exists to express (the
      # same reasoning {RequestSent}'s `stream` carries).
      class SessionPin < Guard
        attribute :digest
        attribute :pinned
        validates :digest, presence: { message: "must name the turn it pins, got nil" }
        validates :pinned, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
      end
    end

    # One path, the first time {Session#read?} would flip false -> true for
    # it this session. `path` is the SAME `File.expand_path`-normalized form
    # {Session} keys its read-set on (not the model's raw spelling) --
    # consistent with every other path already reachable from this journal
    # (a `tool_result`'s quoted file contents), and it is what
    # {SessionRecord::Replay} feeds straight back into a fresh Session's
    # `record_read` with no re-normalization required. A RE-read never lands
    # a second record: that dedupe is what keeps a big read/edit loop from
    # journaling one line per iteration.
    SessionRead = Data.define(:path) do
      include Journalable

      def initialize(path:)
        Guards::SessionRead.check!(path:)

        super(path: path.dup.freeze)
      end
    end

    # One pin transition, recorded so a `--resume` rebuilds the pin-set. This
    # is a LOG line, not a set member: `pinned` carries the DIRECTION (true =
    # pinned, false = retracted), because a pin followed by an unpin must
    # rebuild as not pinned, and a record shape that could only say "pinned"
    # could not express the retraction at all. {SessionRecord::Replay} folds
    # these in recorded order, so the last transition for a digest wins by
    # construction -- the same replace-not-merge reasoning {TodoSnapshot} uses,
    # one digest at a time.
    #
    # `digest` names a committed Turn (the same content address {TurnUsage}'s
    # own `digest` is), never a path: pins protect turns from compaction, and
    # the digest is what a compaction source matches on.
    SessionPin = Data.define(:digest, :pinned) do
      include Journalable

      def initialize(digest:, pinned:)
        Guards::SessionPin.check!(digest:, pinned:)

        super(digest: digest.dup.freeze, pinned:)
      end
    end

    # The run's ENTIRE todo list, one record per {Tools::TodoWrite} call --
    # matching {Session#write_todos}'s own replace-not-merge semantics, so
    # {SessionRecord::Replay} needs no merge logic of its own either: folding
    # every record in order and keeping only the last one's effect IS
    # {Session#write_todos}'s contract, applied N times. `todos` holds
    # `{content, status}` pairs in canonical wire form (String keys), the
    # same shape {Tools::TodoWrite}'s own Item carries.
    TodoSnapshot = Data.define(:todos) do
      include Journalable

      # Built from the duck {Session#write_todos} itself accepts -- any
      # Enumerable of objects answering `#content`/`#status` -- so the
      # decorator forwards its argument here unchanged rather than
      # pre-shaping it into hashes.
      def self.from(todos)
        new(todos: todos.map { |todo| { "content" => todo.content, "status" => todo.status } })
      end

      def initialize(todos:)
        super(todos: Canonical.normalize(todos))
      end
    end
  end
end
