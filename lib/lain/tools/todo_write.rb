# frozen_string_literal: true

require_relative "../session"
require_relative "../tool"

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
    # This tool declares its schema directly (no {Tool::Input} subclass): an
    # array of nested objects is exactly the shape {Tool#input_schema}
    # documents the raw-Hash path for, and {Tool::SchemaValidator} already
    # walks array/object nesting and required keys. `perform` still checks the
    # one thing the validator does not -- that `status` is one of the three
    # allowed words -- and reports a bad one as an error {Result} rather than
    # writing a list the render would show verbatim.
    class TodoWrite < Tool
      STATUSES = %w[pending in_progress completed].freeze

      # One todo, as the session stores and renders it. A tiny value object
      # rather than a bare Hash so {Session#write_todos} can depend on the
      # `#content`/`#status` message rather than on a key-spelling convention.
      Item = Data.define(:content, :status)
      private_constant :Item

      ITEM_SCHEMA = {
        "type" => "object",
        "properties" => {
          "content" => { "type" => "string", "description" => "What the todo is." },
          "status" => {
            "type" => "string",
            "description" => "One of pending, in_progress, completed.",
            "enum" => STATUSES
          }
        },
        "required" => %w[content status],
        "additionalProperties" => false
      }.freeze
      private_constant :ITEM_SCHEMA

      INPUT_SCHEMA = {
        "type" => "object",
        "properties" => {
          "todos" => {
            "type" => "array",
            "description" => "The complete replacement todo list, in the order it should be shown.",
            "items" => ITEM_SCHEMA
          }
        },
        "required" => ["todos"],
        "additionalProperties" => false
      }.freeze
      private_constant :INPUT_SCHEMA

      def name = "todo_write"

      def description
        "Replaces the ENTIRE todo list with the given items -- this is a full " \
          "replacement, not a merge, so include every item that should still " \
          "be tracked. Each item has a `content` string and a `status` of " \
          "pending, in_progress, or completed. The list is shown back to you " \
          "on every following turn until the next todo_write call."
      end

      def input_schema = INPUT_SCHEMA

      protected

      def perform(input, invocation)
        items = dig(input, "todos").map { |raw| item_for(raw) }
        session_of(invocation).write_todos(items)
        Tool::Result.ok("todo list replaced with #{items.size} item(s)")
      rescue ArgumentError => e
        Tool::Result.error(e.message)
      end

      private

      # Keys are the String forms the schema declares, so {Tool#dig} resolves
      # them with the SAME precedence {Tool::SchemaValidator} used to validate
      # -- on a mixed-key item, the value stored is the value validated, never
      # a different spelling's.
      def item_for(raw)
        content = dig(raw, "content")
        status = dig(raw, "status")
        unless STATUSES.include?(status)
          raise ArgumentError, "status #{status.inspect} must be one of #{STATUSES.join(", ")}"
        end

        Item.new(content: content, status: status)
      end

      # The session rides {Tool::Invocation#context}, which is
      # documented-nullable (a bare unit call threads no context). Coalesce
      # that one legitimate nil to the Null session here, matching
      # {Tools::ReadFile}'s own `session_of`.
      def session_of(invocation)
        invocation&.context || Session::Null.instance
      end
    end
  end
end
