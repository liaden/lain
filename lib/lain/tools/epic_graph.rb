# frozen_string_literal: true

module Lain
  module Tools
    # Adds, splits and merges the issues of an epic's graph, so a chat can
    # reshape an epic without a shell. The edit, its refusals and its
    # `graph_revision` record all belong to {CLI::Epic}; this tool names the
    # epic and returns the text that class answers.
    #
    # It asks no approval: it edits the one artifact the epic's own machinery
    # revises, and an issue holding a gate is refused by the verb itself.
    class EpicGraph < Tool
      VERBS = %w[add split merge].freeze

      # The fields each verb cannot run without.
      REQUIRED = { "add" => %w[id title], "split" => %w[id into], "merge" => %w[left right as] }.freeze

      # One field per verb argument; {REQUIRED} says which a verb needs.
      class Input < Tool::Input
        field :verb, :string, required: true, description: "The edit: add, split or merge."
        field :slug, :string, required: true,
                              description: "The epic's slug: #{Epic::Home::NAME_RULE}, for example frugirl-mvp."
        field :id, :string, description: "add: the new issue's id. split: the issue to split."
        field :title, :string, description: "add: the new issue's title. merge: the merged title (optional)."
        field :into, :string, description: "split: the parts' ids, comma-separated, for example cargo-init,ci."
        field :left, :string, description: "merge: one issue to fold in."
        field :right, :string, description: "merge: the other issue to fold in."
        field :as, :string, description: "merge: the merged issue's id."
        field :discovered_from, :string, description: "add: the live issue this one grew out of (optional)."

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

      # @param epics [#add, #split, #merge] the epic verbs, journaling where this chat does
      def initialize(epics:)
        super()
        @epics = epics
      end

      def name = "epic_graph"

      def description
        "Edits an epic's issue graph in epic.md: add an issue, split one into parts, or merge 2 into 1. " \
          "Refuses while a review holds epic.md, for an issue that holds a gate, " \
          "or for an edit that would make a cycle."
      end

      protected

      def perform(input, _invocation)
        Tool::Result.ok(edit(input))
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def edit(input)
        case input.verb
        when "add" then @epics.add(input.id, input.title, input.slug, discovered_from: input.discovered_from)
        when "split" then @epics.split(input.id, input.into, input.slug)
        else @epics.merge(input.left, input.right, input.slug, as: input.as, title: input.title)
        end
      end
    end
  end
end
