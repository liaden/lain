# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module Epic
    class Home
      # A Journal-duck decorator over a {Home} -- {Isolation::Journal}'s shape
      # applied to the artifact seam: every call forwards untouched, and each
      # write that SUCCEEDS additionally emits a {DocWritten}.
      #
      # {DocWritten} is an ACK, not an intent -- the opposite order to the
      # intent-before-effect rule the forge side uses, and deliberately so. A
      # record here means those bytes are on disk, so a reader may join
      # `byte_digest` to the file and expect a match, and a refused write
      # journals nothing at all because nothing happened. The law holds ONE WAY
      # only: a record implies the bytes, but the ABSENCE of a record implies
      # nothing, since the journal write is the second of two steps and a
      # `journal << ` that raises leaves the file on disk with no record.
      #
      # `signoffs:` is a duck answering `#reopened_among(epic_slug:, issue_ids:)`, asked after an issue's or
      # an epic.md's write is acknowledged: it says which issues the new bytes took back from an approved plan.
      #
      # `reviews:` is a duck answering `#open?(path)`, asked before every write.
      # While a human is mid-review they hold the baton, and lain regenerating
      # underneath them would discard edits nobody has read yet -- so the write
      # refuses as {ReviewPending}. Reads and `exist?` pass through: an
      # observation is not a regeneration. The gate runs before
      # {Home::Artifact}'s containment walk, so an artifact BOTH under review and
      # behind a symlinked directory answers {ReviewPending} and never
      # {EscapesHome} -- an ordering of two independent refusals, not a security
      # layering, and nobody should read it as one.
      class Journaled
        # Error taxonomy: a refusal subclasses {Lain::Error} beside its raiser.
        class ReviewPending < Error; end

        # Who may be holding the baton for a path. One message, `#open?(path)`;
        # {Epic::Review} is the shipped answer to it.
        #
        # `path` is the artifact's ABSOLUTE path ({Home::Artifact#path}), not
        # the home-relative one {DocWritten} carries, and the two are not
        # interchangeable: a review is a live question about a file on this
        # machine -- the exact string an editor surface opens -- while the record
        # is durable and travels with `$XDG_STATE_HOME`, so it must not pin a
        # machine's absolute path.
        module Reviews
          # The seam's Null Object: `false` for every path is exactly "nobody
          # holds the baton", so nothing writes `if @reviews`.
          module Null
            def self.open?(_path) = false
          end
        end

        # Who reopens the plans an edit changed. One message, `#reopened_among(epic_slug:, issue_ids:)`, which
        # yields each issue it reopened; {Epic::Reopen} is the shipped answer to it.
        module Signoffs
          # The seam's Null Object: nothing is reopened, so nothing writes `if @signoffs`.
          module Null
            def self.reopened_among(**) = nil
          end
        end

        # @param home [Home] the real home every call forwards to
        # @param journal [#<<] where {DocWritten} records land
        # @param reviews [#open?] who holds the baton for a path
        # @param signoffs [#reopened_among] who takes an issue's approval back when its file or epic.md changes
        def initialize(home, journal:, reviews: Reviews::Null, signoffs: Signoffs::Null)
          @home = home
          @journal = journal
          @reviews = reviews
          @signoffs = signoffs
        end

        # What this decorator does NOT acknowledge: a read answers no DocWritten,
        # and the home's own identity is not a write at all.
        delegate :slug, :path, :read_epic, :sources, to: :@home

        def research = written(@home.research, "research")
        def epic = written(@home.epic, "epic", issue_ids: -> { @home.read_epic.ids })
        def issue(id) = written(@home.issue(id), "issue", issue_ids: -> { [id] })
        def source(name) = written(@home.source(name), "source")

        # The graph's own content address rides along with the bytes', because
        # the two answer different questions: `byte_digest` says what is on disk,
        # `graph_digest` says which graph it came from, and an equal graph
        # re-emitted is the case where only the second one is legible.
        #
        # {Document.to_markdown} runs while this argument is evaluated -- before
        # the review is consulted and long before a file is touched -- so a graph
        # the writer refuses leaves the previous epic exactly as it was.
        #
        # `preamble:` defaults empty rather than reading the artifact's current
        # one, the same choice {Document.to_markdown} itself makes: a caller
        # that wants the epic's existing preamble kept through this write reads
        # it first and hands it back, the way {CLI::Epic#apply} does, rather
        # than this method reaching behind its own write to find it.
        #
        # @return [self] so a chained write stays journaled
        def write_epic(graph, preamble: "")
          written(@home.epic, "epic", graph_digest: graph.digest,
                                      issue_ids: graph.method(:ids)).write(Document.to_markdown(graph, preamble:))
          self
        end

        private

        # `graph_digest` is a property of the RESOLVED artifact, never an
        # argument to its write: passed the other way it would be reachable from
        # `research`/`issue`, putting a graph address on a prose record,
        # and would widen the write duck past the {Home::Artifact#write} this
        # wraps.
        def written(artifact, kind, graph_digest: nil, issue_ids: -> { [] })
          Written.new(artifact:, kind:, graph_digest:, epic_slug: @home.slug, relative: relative(artifact),
                      journal: @journal, reviews: @reviews, signoffs: @signoffs, issue_ids:)
        end

        # {Home} composed this path from that same prefix a moment ago, so the
        # strip is exact rather than a guess at a layout only {Home} owns.
        def relative(artifact) = artifact.path.delete_prefix("#{@home.path}#{File::SEPARATOR}")

        # One artifact wrapped in the two things this decorator adds around its
        # write: the baton check before it and the ack after it. {Home}'s own
        # split between itself and its Artifact, kept.
        class Written
          # @return [Array<String>] the issues the last write took back from an approved plan
          attr_reader :reopened

          # @return [String, nil] why the reopen step could not run, after the bytes had landed
          attr_reader :reopen_failure

          # What the reopen step really raises: the journal write, and a fold that refuses a damaged
          # decision line (kept fail-closed there, so it is named here rather than swallowed).
          REOPEN_FAILURES = [JournalUnreadable, SignoffQueue::UnreadableRecord, SystemCallError].freeze
          private_constant :REOPEN_FAILURES

          def initialize(artifact:, kind:, epic_slug:, relative:, journal:, reviews:, signoffs:, issue_ids:,
                         graph_digest: nil)
            @artifact = artifact
            @kind = kind
            @epic_slug = epic_slug
            @relative = relative
            @journal = journal
            @reviews = reviews
            @graph_digest = graph_digest
            @signoffs = signoffs
            @issue_ids = issue_ids
            @reopened = []
          end

          delegate :path, :read, :exist?, to: :@artifact

          # Exactly {Home::Artifact#write}'s arity, which is the point: this
          # wraps that method and must not be a wider duck than it.
          # @return [self]
          def write(content)
            refuse_open_review!
            @artifact.write(content)
            @journal << DocWritten.new(epic_slug: @epic_slug, kind: @kind, path: @relative,
                                       byte_digest: address(content), graph_digest: @graph_digest)
            reopen
            self
          end

          private

          # The bytes' own content address, through the same {Snapshot::Blob}
          # the reviewed-document side uses, so a document has ONE address
          # whether it is journaled here or handed to a review. Not
          # {Canonical.digest}, which would hash the JSON ENCODING of the content
          # rather than the content, and which pins UTF-8 where a file is
          # arbitrary bytes.
          def address(content) = Workspace::Snapshot::Blob.new(bytes: content).digest

          def reopen
            @reopened = []
            ids = @issue_ids.call
            @signoffs.reopened_among(epic_slug: @epic_slug, issue_ids: ids) { @reopened << _1 } if ids.any?
          rescue *REOPEN_FAILURES => e
            @reopen_failure = e.message
          end

          def refuse_open_review!
            return unless @reviews.open?(path)

            raise ReviewPending, "#{path} is under review, so regenerating it would discard edits nobody " \
                                 "has read yet -- settle the review first"
          end
        end

        # `Written` wraps whatever {Home} handed back, so nothing outside builds
        # one; `private` scopes methods and not constants ({Home::Artifact}'s).
        private_constant :Written
      end
    end
  end
end
