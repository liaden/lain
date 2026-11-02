# frozen_string_literal: true

module Lain
  module Tools
    # Adds, splits and merges the issues of an epic's graph, links and unlinks
    # their edges, and rewrites an issue's title, description or subject, so a
    # chat can reshape an epic without a shell. The edit, its refusals and its
    # `graph_revision` record all belong to {CLI::Epic}; this tool names the
    # epic and returns the text that class answers.
    #
    # It asks no approval: it edits the one artifact the epic's own machinery
    # revises, and an issue holding a gate is refused by the verb itself.
    class EpicGraph < Tool
      # The fields each verb cannot run without.
      REQUIRED = { "add" => %w[id title], "split" => %w[id into], "merge" => %w[left right as],
                   "link" => %w[kind from to], "unlink" => %w[kind from to], "retitle" => %w[id title],
                   "describe" => %w[id description], "subject" => %w[id subject] }.freeze

      VERBS = REQUIRED.keys.freeze

      # One field per verb argument; {REQUIRED} says which a verb needs.
      class Input < Tool::Input
        field :verb, :string, required: true, description: "The edit: #{VERBS.join(", ")}."
        field :slug, :string, required: true,
                              description: "The epic's slug: #{Epic::Home::NAME_RULE}, for example frugirl-mvp."
        field :id, :string, description: "add: the new issue's id. split, retitle, describe, subject: the issue."
        field :title, :string,
              description: "add: the new issue's title. merge: the merged title (optional). retitle: the new title."
        field :into, :string, description: "split: the parts' ids, comma-separated, for example cargo-init,ci."
        field :left, :string, description: "merge: one issue to fold in."
        field :right, :string, description: "merge: the other issue to fold in."
        field :as, :string, description: "merge: the merged issue's id."
        field :kind, :string, description: "link, unlink: the edge kind, blocks or related."
        field :from, :string, description: "link, unlink: the issue that holds the edge."
        field :to, :string, description: "link, unlink: the issue the edge names."
        field :description, :string, description: "describe: the issue's new description."
        field :subject, :string, description: "subject: the issue's test subject path."
        field :discovered_from, :string, description: "add: the live issue this one grew out of (optional)."

        validates :kind, inclusion: { in: Epic::EDGE_FIELDS.map(&:to_s), message: "must be blocks or related" },
                         allow_nil: true
        validates :verb, inclusion: { in: VERBS, message: "must be one of #{VERBS.join(", ")}" }
        validate :verb_has_its_fields

        private

        def verb_has_its_fields
          REQUIRED.fetch(verb, []).each do |name|
            errors.add(name.to_sym, "is required for verb #{verb}") if public_send(name).to_s.empty?
          end
        end
      end

      input_model Input

      # @param epics [CLI::Epic] the epic verbs, journaling where this chat does
      def initialize(epics:)
        super()
        @epics = epics
      end

      def name = "epic_graph"

      def description
        "Edits an epic's issue graph in epic.md: add an issue, split one into parts, merge 2 into 1, " \
          "link or unlink a blocks or related edge, or retitle, describe or set the subject of an issue. " \
          "retitle, describe and subject cannot blank a field. " \
          "Refuses while a review holds epic.md, for an issue that holds a gate (either end of an edge), " \
          "or for an edit that would make a cycle."
      end

      protected

      def perform(input, _invocation)
        Tool::Result.ok(edit(input))
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      EDITS = {
        "add" => ->(epics, i) { epics.add(i.id, i.title, i.slug, discovered_from: i.discovered_from) },
        "split" => ->(epics, i) { epics.split(i.id, i.into, i.slug) },
        "merge" => ->(epics, i) { epics.merge(i.left, i.right, i.slug, as: i.as, title: i.title) },
        "link" => ->(epics, i) { epics.link(i.kind, i.from, i.to, i.slug) },
        "unlink" => ->(epics, i) { epics.unlink(i.kind, i.from, i.to, i.slug) },
        "retitle" => ->(epics, i) { epics.retitle(i.id, i.title, i.slug) },
        "describe" => ->(epics, i) { epics.describe(i.id, i.description, i.slug) },
        "subject" => ->(epics, i) { epics.subject(i.id, i.subject, i.slug) }
      }.freeze
      private_constant :EDITS

      def edit(input) = EDITS.fetch(input.verb).call(@epics, input)
    end
  end
end
