# frozen_string_literal: true

module Lain
  module Telemetry
    # The run-state records, all emitted by {Session::Journaled} -- the
    # decorator that keeps {Session} itself journal-ignorant, so neither the
    # Agent nor any tool ever constructs one directly.

    module Carriers
      # A read record must name the file read, and say whether the model saw
      # the WHOLE file. `presence:` is wrong for `complete` -- it would reject
      # `false`, which is exactly the partial read this field exists to express
      # (the reason {SessionPin}'s `pinned` avoids it too).
      class SessionRead < Declarative::Carrier
        attribute :path
        attribute :complete
        validates :path, presence: { message: "must name the file read, got nil" }
        validate :complete_is_strictly_boolean

        private

        # An explicit identity test rather than `inclusion: { in: [true, false] }`,
        # which does NOT deliver the strictness it advertises: ActiveModel's
        # InclusionValidator reads an ARRAY value as "every member must be
        # included", and `[].all?` is vacuously true, so `complete: []` passed a
        # guard whose entire job is to admit true or false.
        #
        # {Session::ReadSet#record} carries the same check, and the duplication
        # is deliberate defence in depth: that one owns the in-memory read-set,
        # this one owns the record on its way to disk, and a bare Session
        # reaches the first without ever passing the second.
        def complete_is_strictly_boolean
          return if [true, false].include?(complete)

          errors.add(:complete, "must be true or false, got #{complete.inspect}")
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

    # One path, each time the read-set's state for it TRANSITIONS this session.
    # `path` is the `File.expand_path`-normalized form {Session} keys its
    # read-set on, so {SessionRecord::Replay} feeds it straight back into a
    # fresh Session with no re-normalization. A RE-read at the same completeness
    # lands no second record, which is what keeps a big read/edit loop from
    # journaling one line per iteration.
    #
    # `complete` is what makes the stream replayable at all: without it a
    # partial read rebuilds as a whole one, and a resumed run would permit the
    # very clobber the read boundary refuses. A partial read later upgraded to a
    # complete one is therefore TWO records, folding to complete.
    SessionRead = Data.define(:path, :complete) do
      include Journalable

      # `settle!` is safe on `path` because {Session::Journaled} normalizes it
      # through `File.expand_path` before it ever gets here, so what arrives is
      # a String; a Pathname would be refused rather than silently stringified.
      def initialize(path:, complete:) = super(**Carriers::SessionRead.settle!(path:, complete:))
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

      # Built from the duck {Session#write_todos} itself accepts, so the
      # decorator forwards its argument unchanged rather than pre-shaping it.
      def self.from(todos)
        new(todos: todos.map { |todo| { "content" => todo.content, "status" => todo.status } })
      end

      # Explicit keyword: `Canonical.normalize(nil)` is nil, so `new` with no
      # argument would journal `{"todos": null}` as a valid record.
      def initialize(todos:) = super(**self.class.settle!(todos:))
    end
  end
end
