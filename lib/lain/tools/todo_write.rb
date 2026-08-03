# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): REPLACES the run's entire todo list in one call --
    # deterministic, no merge logic, so a stale item can never linger from a
    # partial update the model never intended. The session renders the list as
    # ONE reminder string ({Session#write_todos}, the same render-to-one-string
    # shape as {Memory::Manifest#to_reminder}), and the Agent's existing
    # per-render composition (`@workspace.with(*@session.reminders)`, T11)
    # carries it into the Request tail. The list never enters the Timeline: it
    # rides the Workspace the same way a file read never becomes a Turn, so it
    # can neither compound token cost turn over turn nor resurrect a completed
    # item when the Timeline is rewound.
    #
    # The wire shape is an array of `{content, status}` objects -- the minimal
    # honest shape for a todo: what it is, and where it stands. `status` is a
    # closed enum rather than free text so a rendered list is always one of
    # three unambiguous words, not a model-invented synonym.
    #
    class TodoWrite < Tool
      STATUSES = %w[pending in_progress completed].freeze

      # One declaration, so the schema the model reads and the check the call
      # is refused by cannot drift: the `inclusion` validator on `status` IS
      # the emitted `enum`, and each element arrives as a coerced object
      # answering `#content`/`#status` -- the duck {Session#write_todos}
      # documents -- rather than a Hash whose key spelling a reader would have
      # to guess at. A bad status is therefore refused by {Tool#call}, BEFORE
      # `perform` runs, so there is no error {Result} to return; the executing
      # {Effect::Handler} converts that raise into the one the model sees.
      class Input < Tool::Input
        field :todos, :array, required: true, blank_ok: true,
                              description: "The complete replacement todo list, in the order it should be shown." do
          field :content, :string, description: "What the todo is.", required: true
          field :status, :string, description: "One of pending, in_progress, completed.", required: true
          # The message names the offending value, as the hand-rolled check it
          # replaces did: "is not included in the list" leaves a model guessing
          # which of its items was wrong. Only `in:` reaches the emitted
          # `enum`, so this costs the schema nothing.
          validates :status,
                    inclusion: { in: STATUSES, message: "must be one of #{STATUSES.join(", ")}, got %<value>s" }
        end
      end

      input_model Input

      def name = "todo_write"

      def description
        "Replaces the ENTIRE todo list with the given items -- this is a full " \
          "replacement, not a merge, so include every item that should still " \
          "be tracked. Each item has a `content` string and a `status` of " \
          "pending, in_progress, or completed. The list is shown back to you " \
          "on every following turn until the next todo_write call."
      end

      protected

      # `input.todos` is already the list {Session#write_todos} wants: coerced
      # elements answering `#content`/`#status`, in the order sent. An empty
      # one is a real call -- it is how a run CLEARS its list -- which is what
      # `blank_ok:` admits while still requiring the key.
      def perform(input, invocation)
        session_of(invocation).write_todos(input.todos)
        Tool::Result.ok("todo list replaced with #{input.todos.size} item(s)")
      end
    end
  end
end
