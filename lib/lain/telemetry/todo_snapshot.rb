# frozen_string_literal: true

module Lain
  module Telemetry
    # The run's ENTIRE todo list, one record per {Tools::TodoWrite} call,
    # matching {Session#write_todos}'s replace-not-merge semantics -- so folding
    # every record in order and keeping the last one's effect IS that contract
    # applied N times, and {SessionRecord::Replay} needs no merge logic.
    # Emitted by {Session} as it records, never by the Agent or a tool.
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
