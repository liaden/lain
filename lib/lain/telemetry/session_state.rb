# frozen_string_literal: true

module Lain
  module Telemetry
    # T16's run-state records, all emitted by {Session::Journaled} -- the
    # decorator that keeps {Session} itself journal-ignorant, so neither the
    # Agent nor any tool ever constructs one directly.

    module Guards
      # A read record must name the file read, and say whether the model saw
      # the WHOLE file. `presence:` is wrong for `complete` -- it would reject
      # `false`, which is exactly the partial read this field exists to express
      # (the reason {SessionPin}'s `pinned` avoids it too).
      class SessionRead < Guard
        attribute :path
        attribute :complete
        validates :path, presence: { message: "must name the file read, got nil" }
        validate :complete_is_strictly_boolean

        private

        # An explicit identity test rather than `inclusion: { in: [true, false] }`,
        # which is what this started as and which does NOT deliver the strictness
        # it advertises: ActiveModel's InclusionValidator reads an ARRAY value as
        # "every member must be included", and `[].all?` is vacuously true. So
        # `complete: []` passed a guard whose entire job is to admit true or
        # false, and journaled `"complete":[]`. Replay's own check rejects that,
        # so the security direction held -- but a guard that lies about its own
        # strictness is worth closing where the record is written.
        #
        # {Session::ReadSet#record} carries the same check, and the duplication
        # is deliberate defence in depth: that one owns the in-memory read-set,
        # this one owns the record on its way to disk, and a bare Session
        # reaches the first without ever passing the second. Neither is the
        # redundant copy.
        def complete_is_strictly_boolean
          return if [true, false].include?(complete)

          errors.add(:complete, "must be true or false, got #{complete.inspect}")
        end
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

    # One path, each time the read-set's state for it TRANSITIONS this session.
    # `path` is the SAME `File.expand_path`-normalized form {Session} keys its
    # read-set on (not the model's raw spelling) -- consistent with every other
    # path already reachable from this journal (a `tool_result`'s quoted file
    # contents), and it is what {SessionRecord::Replay} feeds straight back
    # into a fresh Session's `record_read` with no re-normalization required.
    # A RE-read at the same completeness never lands a second record: that
    # dedupe is what keeps a big read/edit loop from journaling one line per
    # iteration.
    #
    # `complete` says whether the model saw the whole file or a redacted
    # rendering of it. It is what makes the stream replayable at all: without
    # it a partial read rebuilds as a whole one, and a resumed run would permit
    # the very clobber the read boundary refuses. A partial read later upgraded
    # to a complete one is therefore TWO records, folding to complete -- the
    # model saw two different things, and the record stream says so.
    SessionRead = Data.define(:path, :complete) do
      include Journalable

      def initialize(path:, complete:)
        Guards::SessionRead.check!(path:, complete:)

        super(path: path.dup.freeze, complete:)
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
