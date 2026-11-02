# frozen_string_literal: true

module Lain
  module Tools
    # Writes one of an epic's markdown artifacts into the project's epic home,
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
        "research" => ->(home, _input) { home.research },
        "epic" => ->(home, _input) { home.epic },
        "issue" => ->(home, input) { home.issue(input.issue) },
        "source" => ->(home, input) { home.source(input.name) }
      }.freeze
      NEEDS_ISSUE = %w[issue].freeze
      NEEDS_NAME = %w[source].freeze

      # Told to a model that still asks for the retired plan file.
      PLAN_GONE = "a plan file no longer exists: put an issue's test subject on a `Subject:` line " \
                  "in its section of epic.md"

      # The heading form an issue takes in epic.md, quoted when none parsed.
      ISSUE_HEADING = "### [ ] `a1` title"

      # The slug's grammar is left to {Epic::Home.resolve}, which owns it and
      # quotes it in the refusal.
      class Input < Tool::Input
        field :slug, :string, required: true,
                              description: "The epic's slug: #{Epic::Home::NAME_RULE}, for example frugirl-mvp."
        field :artifact, :string, required: true,
                                  description: "Which artifact to write: research (research.md), epic (epic.md), " \
                                               "issue (issues/<issue>.md) or source (sources/<name>.md)."
        field :issue, :string, description: "The issue id. Required for artifact issue, ignored otherwise."
        field :name, :string, description: "The source's name: #{Epic::Home::NAME_RULE}. Required for artifact " \
                                           "source, ignored otherwise."
        field :content, :string, required: true, description: "The whole markdown file; it replaces what is there."

        validates :artifact, inclusion: { in: ARTIFACTS.keys, message: lambda { |_record, data|
          data[:value] == "plan" ? PLAN_GONE : "must be one of #{ARTIFACTS.keys.join(", ")}"
        } }
        validates :issue, presence: true, if: -> { NEEDS_ISSUE.include?(artifact) }
        validates :name, presence: true, if: -> { NEEDS_NAME.include?(artifact) }
      end

      input_model Input

      # @param homes [#for] answers `for(slug)` with that epic's {Epic::Home::Journaled}
      def initialize(homes:)
        super()
        @homes = homes
      end

      def name = "epic_write"

      def description
        "Writes one artifact of an epic (research, epic, issue or source) into this project's epic home, " \
          "replacing the file. A source is a fact a research cites, kept beside it. Refuses while a review " \
          "holds the file. An issue file is the authored half of the issue's view, so its link lines, its own " \
          "header, a Links heading, a gherkin fence outside Acceptance criteria and restated scenarios are refused."
      end

      protected

      def perform(input, invocation)
        parsed = parsed_issues(input)
        home = @homes.for(input.slug)
        artifact = ARTIFACTS.fetch(input.artifact).call(home, input)
        refuse_derived!(home, input)
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

      # The issue file is only the authored half of the view, so a line lain
      # renders from epic.md would be a second copy free to drift from it.
      def refuse_derived!(home, input)
        return unless input.artifact == "issue"

        graph = home.read_epic
        Epic::IssueView.new(issue: graph.fetch(input.issue), graph:, authored: input.content).refuse_derived!
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
