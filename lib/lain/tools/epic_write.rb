# frozen_string_literal: true

module Lain
  module Tools
    # Writes one of an epic's 4 markdown artifacts into the project's epic home,
    # so a skill can land `research.md` without knowing where that home is.
    #
    # It asks no approval: the model names a slug and an artifact kind, never a
    # path, {Epic::Home} owns the layout and refuses a symlinked segment, and
    # {Epic::Home::Journaled} journals every write it lets through. The same
    # decorator refuses a write while a review this working directory's
    # sessions recorded holds the file, so a human's unread edits are never
    # regenerated underneath them.
    class EpicWrite < Tool
      ARTIFACTS = {
        "research" => ->(home, _issue) { home.research },
        "epic" => ->(home, _issue) { home.epic },
        "issue" => ->(home, issue) { home.issue(issue) },
        "plan" => ->(home, issue) { home.plan(issue) }
      }.freeze
      NEEDS_ISSUE = %w[issue plan].freeze

      # The heading form an issue takes in epic.md, quoted when none parsed.
      ISSUE_HEADING = "### [ ] `a1` title"

      # The slug's grammar is left to {Epic::Home.resolve}, which owns it and
      # quotes it in the refusal.
      class Input < Tool::Input
        field :slug, :string, required: true,
                              description: "The epic's slug: #{Epic::Home::NAME_RULE}, for example frugirl-mvp."
        field :artifact, :string, required: true,
                                  description: "Which artifact to write: research (research.md), epic (epic.md), " \
                                               "issue (issues/<issue>.md) or plan (plans/<issue>.md)."
        field :issue, :string, description: "The issue id. Required for artifact issue and plan, ignored otherwise."
        field :content, :string, required: true, description: "The whole markdown file; it replaces what is there."

        validates :artifact, inclusion: { in: ARTIFACTS.keys, message: "must be one of #{ARTIFACTS.keys.join(", ")}" }
        validates :issue, presence: true, if: -> { NEEDS_ISSUE.include?(artifact) }
      end

      input_model Input

      # @param homes [#for] answers `for(slug)` with that epic's {Epic::Home::Journaled}
      def initialize(homes:)
        super()
        @homes = homes
      end

      def name = "epic_write"

      def description
        "Writes one artifact of an epic (research, epic, issue or plan) into this project's epic home, " \
          "replacing the file. Refuses while a review holds the file."
      end

      protected

      def perform(input, invocation)
        parsed = parsed_issues(input)
        home = @homes.for(input.slug)
        artifact = ARTIFACTS.fetch(input.artifact).call(home, input.issue)
        journaled_write(artifact, input.content)
        session_of(invocation).record_document(document_name(home, artifact))
        Tool::Result.ok("wrote #{input.content.bytesize} bytes to #{artifact.path}#{parsed}")
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def document_name(home, artifact)
        "#{home.slug}/#{artifact.path.delete_prefix("#{home.path}#{File::SEPARATOR}")}"
      end

      # An epic.md is read back by every epic command, so one they would refuse
      # is refused here, at write time, rather than at their next read.
      def parsed_issues(input)
        return "" unless input.artifact == "epic"

        graph = Epic::Document.parse_markdown(input.content)
        Epic::Home.refuse_unwritable_ids!(graph)
        count = graph.count
        if count.zero?
          raise Error, "epic.md holds no issue heading, so nothing was written: each issue takes the form " \
                       "#{ISSUE_HEADING}"
        end

        ", #{count} #{count == 1 ? "issue" : "issues"} parsed"
      end

      # {Epic::Home::Artifact#write} raises every system error of its own as a
      # {Lain::Error}, so a raw one here is the journal append, after the bytes
      # landed. IOError is left alone: the file write can raise one too.
      def journaled_write(artifact, content)
        artifact.write(content)
      rescue SystemCallError => e
        raise Error, "#{artifact.path} was written, but the write was not journaled: #{e.message}"
      end
    end
  end
end
