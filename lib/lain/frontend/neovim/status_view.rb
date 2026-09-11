# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # lain://status: where the mounted epic stands, as one markdown buffer --
      # its progress, its issue graph as a mermaid code fence an image plugin can
      # draw, and the fleet still running. {InboxView}'s shape (`initial` /
      # `update(event)`, plain lines, never nvim).
      #
      # The epic half is FOLDED FROM DISK rather than accumulated from events:
      # the issue and gate records it shows are written by other processes
      # (`lain epic submit` in another terminal), and those never reach this Channel. A
      # completed turn is therefore the tick that notices them, and an epic
      # record this process journaled is another. Nothing else refolds, because
      # a tool's stdout arrives many times a second and the fold walks every
      # session journal the project has.
      #
      # The fleet half is the opposite: it is read only off this Channel's
      # `:spawn` and `:message` records, through the same {StatusFeed::Fleet}
      # the HUD keeps, so the two agree about what is still running.
      class StatusView
        NAME = "lain://status"

        # {Buffers::TimelineView::NEWLINES}' reason: one rendered line is one
        # buffer line, and the transport refuses a line that holds a newline.
        NEWLINES = /\R+/

        # No epic resolved for this chat -- the frontend's null, answering the
        # one message the view asks of an epic.
        module Unmounted
          LINES = ["# lain status", "",
                   "no epic is mounted -- start the chat with `--epic SLUG` to see one here"].freeze

          def self.lines = LINES
        end

        # A chat seated in an epic, read through {CLI::Epic#progress}: the same
        # public seam `lain epic status` reads, so this buffer and that report can
        # never disagree about which issue is ready.
        class Mounted
          # @param slug [String] the epic the chat is mounted into, already resolved
          # @param status [#progress] folds that slug from disk ({CLI::Epic})
          def initialize(slug:, status:)
            @slug = slug
            @status = status
          end

          # @return [Array<String>] the progress text and the mermaid fence
          # @raise [StandardError] whatever the fold raises; {StatusView} draws it
          def lines
            progress = @status.progress(@slug)
            ["# epic `#{@slug}`", "", progress.summary, "", *issues(progress), "", *fence(progress)]
          end

          private

          def issues(progress) = progress.graph.map { |issue| "- #{glyph(issue)} -- #{state(progress, issue)}" }

          # The document's own marks, so an issue reads here the way epic.md spells it.
          def glyph(issue) = "[#{Lain::Epic::Document::STATUS_MARKS.fetch(issue.status)}] `#{issue.id}` #{issue.title}"

          # Pending splits the way {Epic::Mermaid} splits it: free to start, or
          # held -- and by WHICH blockers, the question a pending issue raises.
          def state(progress, issue)
            return issue.status unless issue.status == "pending"

            holding = progress.graph.blocked_by(issue.id).reject { |id| progress.status(id) == Lain::Epic::DONE }
            holding.empty? ? "pending, ready" : "pending, blocked by #{holding.map { |id| "`#{id}`" }.join(", ")}"
          end

          # Split per line: {Epic::Mermaid.render} joins its source with
          # newlines, which is one line too many for a buffer.
          def fence(progress) = ["```mermaid", *Lain::Epic::Mermaid.render(progress).split("\n"), "```"]
        end

        # @param epic [#lines] {Mounted}, or {Unmounted} for a chat in no epic
        # @param fleet [StatusFeed::Fleet] the spawns still running
        def initialize(epic: Unmounted, fleet: StatusFeed::Fleet.new)
          @epic = epic
          @fleet = fleet
          @epic_lines = nil
          @fleet_lines = nil
          @shown = nil
        end

        # @return [Array<String>]
        def initial
          @epic_lines = folded
          @shown = composed
        end

        # @param event [Object] one Channel event
        # @return [Array<String>, nil] the whole buffer, or nil when nothing it
        #   shows moved -- a refold that found no change redraws nothing
        def update(event)
          @epic_lines = folded if refold?(event)
          @fleet_lines = observed(event) if event.respond_to?(:kind)
          lines = composed
          return nil if lines == @shown

          @shown = lines
        end

        private

        def composed = [*epic_lines, "", *fleet_lines]

        def epic_lines = @epic_lines ||= folded

        def fleet_lines = @fleet_lines ||= fleet_listing

        def fleet_listing
          digests = @fleet.digests
          ["## fleet", "", *(digests.empty? ? ["(nothing running)"] : digests.map { |digest| "- #{digest}" })]
        end

        # {#folded}'s reason, for the other half: a malformed `:spawn` or
        # `:message` raises inside the fleet on the same drain thread, so it
        # costs this buffer its fleet listing and nothing else.
        def observed(event)
          observe(event)
          fleet_listing
        rescue StandardError => e
          unavailable("## fleet unavailable", e)
        end

        # This runs on the frontend's one drain thread, where a raise records a
        # worker death that takes EVERY view dark. So any failure of the fold --
        # not only the epic tier's own refusals, but an unreadable epic.md or a
        # session file torn mid-write -- is drawn into this buffer instead, and
        # the next trigger tries again.
        def folded
          @epic.lines.map { |line| line.gsub(NEWLINES, " ") }
        rescue StandardError => e
          unavailable("# epic status unavailable", e)
        end

        # Scrubbed before it is split: `String#split` raises on invalid UTF-8,
        # and this is the one place a raise has nowhere left to go.
        def unavailable(heading, error)
          message = error.message.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
          [heading, "", "it failed with #{error.class}:", *message.split(NEWLINES).map { |line| "    #{line}" }]
        end

        # Matched by class, as {StatusFeed}'s own arms are. Reached at call time
        # because the epic tier loads after the frontend; the approval tier
        # loads before it.
        def refold?(event)
          [Telemetry::TurnUsage, Lain::Epic::IssueTransition, Lain::Epic::StageTransition,
           Lain::Approval::GateDecision].any? { |type| event.is_a?(type) }
        end

        def observe(event)
          case event.kind
          when :spawn then @fleet.launched(event)
          when :message then @fleet.completed(event)
          end
        end
      end
    end
  end
end
