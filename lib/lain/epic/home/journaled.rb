# frozen_string_literal: true

module Lain
  module Epic
    class Home
      # A Journal-duck decorator over a {Home} -- {Isolation::Journal}'s shape
      # applied to the artifact seam: every call forwards to the wrapped home
      # untouched, and each write that SUCCEEDS additionally emits a
      # {DocWritten}. The home itself stays journal-ignorant, which is what
      # keeps its own spec free of a journal, and nothing here reimplements a
      # byte of the tempfile-and-rename: the write is the home's.
      #
      # == Write first, journal second
      #
      # The opposite order to the intent-before-effect rule the forge side uses,
      # and deliberately so. {DocWritten} is an ACK, not an intent: a record
      # here means those bytes are on disk, so a reader may join `byte_digest`
      # to the file and expect a match. A refused write -- an unemittable graph,
      # a symlinked home, a full disk -- therefore journals nothing at all,
      # because nothing happened. Do not "fix" this into intent-first; an intent
      # record for an artifact write would claim a file that may not exist.
      #
      # The law holds one way only. A record implies the bytes; the ABSENCE of a
      # record implies nothing, because the journal write is the second of two
      # steps: a `journal << ` that raises leaves the file on disk with no
      # record and propagates, so a reader must never treat "no doc_written" as
      # "no write happened".
      #
      # == The regeneration guard
      #
      # `reviews:` is a duck answering `#open?(path)`, asked before every write.
      # While a human is mid-review on an artifact they hold the baton for it,
      # and lain regenerating underneath them would discard edits nobody has
      # read yet -- so the write refuses as {ReviewPending} rather than winning
      # the race. Reads and `exist?` pass through: an observation is not a
      # regeneration. The path asked about is the artifact's own absolute path,
      # which is what an editor surface opens and what a review is opened on.
      #
      # The gate runs before {Home::Artifact}'s own containment walk, so an
      # artifact that is BOTH under review and behind a symlinked directory
      # answers {ReviewPending} and never {EscapesHome}. Both refuse and neither
      # writes, so nothing is unsafe about the order -- but it is an ordering of
      # two independent refusals, not a security layering, and nobody should
      # read it as one.
      class Journaled
        # Named per the error-taxonomy convention: a refusal subclasses
        # {Lain::Error} next to the owner that raises it (see {EscapesHome}).
        class ReviewPending < Error; end

        # Who may be holding the baton for a path. One message, `#open?(path)`,
        # and one shipped answer to it; {Epic::Review} is the real one.
        #
        # `path` is the artifact's ABSOLUTE path ({Home::Artifact#path}), not
        # the home-relative one {DocWritten} carries. The two representations
        # are deliberate and they are not interchangeable: a review is a live
        # question about a file on this machine -- the exact string an editor
        # surface opens -- while the record is durable and travels with
        # `$XDG_STATE_HOME`, so it must not pin a machine's absolute path. An
        # implementation of this duck keys on the absolute path.
        module Reviews
          # The seam's Null Object, so no write site ever asks whether a reviews
          # duck was supplied. It answers `false` for every path, which is
          # exactly "nobody holds the baton" -- {Sink::Null}'s bargain, kept
          # here: a decorator wired to no review surface behaves precisely like
          # the undecorated home, and nothing writes `if @reviews`.
          module Null
            def self.open?(_path) = false
          end
        end

        # @param home [Home] the real home every call forwards to
        # @param journal [#<<] where {DocWritten} records land
        # @param reviews [#open?] who holds the baton for a path
        def initialize(home, journal:, reviews: Reviews::Null)
          @home = home
          @journal = journal
          @reviews = reviews
        end

        def slug = @home.slug
        def path = @home.path

        def research = written(@home.research, "research")
        def epic = written(@home.epic, "epic")
        def issue(id) = written(@home.issue(id), "issue")
        def plan(id) = written(@home.plan(id), "plan")

        def read_epic = @home.read_epic

        # The graph's own content address rides along with the bytes', because
        # the two answer different questions: `byte_digest` says what is on
        # disk, `graph_digest` says which graph it came from, and an equal graph
        # re-emitted is the case where only the second one is legible.
        #
        # {Document.to_markdown} runs while this argument is evaluated -- before
        # the review is consulted and long before a file is touched -- so a
        # graph the writer refuses leaves the previous epic exactly as it was,
        # which is {Home#write_epic}'s own guarantee kept rather than restated.
        #
        # @return [self] so a chained write stays journaled
        def write_epic(graph)
          written(@home.epic, "epic", graph_digest: graph.digest).write(Document.to_markdown(graph))
          self
        end

        private

        # `graph_digest` is a property of the RESOLVED artifact, never an
        # argument to its write. Passed the other way it would be reachable from
        # the public `research`/`issue`/`plan`, which would put a graph address
        # on a prose record the moment anyone passed one -- and it would widen
        # the write duck past the {Home::Artifact#write} this wraps.
        def written(artifact, kind, graph_digest: nil)
          Written.new(artifact:, kind:, graph_digest:, epic_slug: @home.slug, relative: relative(artifact),
                      journal: @journal, reviews: @reviews)
        end

        # The record names the artifact INSIDE the home. {Home} composed this
        # path from that same prefix a moment ago, so the strip is exact rather
        # than a guess at the layout -- and it is the home, not this decorator,
        # that stays the one place the layout is written down.
        def relative(artifact) = artifact.path.delete_prefix("#{@home.path}#{File::SEPARATOR}")

        # One artifact, wrapped in the two things this decorator adds around its
        # write: the baton check before it and the ack after it. Separate from
        # {Journaled} because "which home is this" and "what happens around one
        # file's write" are different jobs -- {Home}'s own split between itself
        # and its Artifact, kept.
        class Written
          def initialize(artifact:, kind:, epic_slug:, relative:, journal:, reviews:, graph_digest: nil)
            @artifact = artifact
            @kind = kind
            @epic_slug = epic_slug
            @relative = relative
            @journal = journal
            @reviews = reviews
            @graph_digest = graph_digest
          end

          def path = @artifact.path
          def read = @artifact.read
          def exist? = @artifact.exist?

          # Exactly {Home::Artifact#write}'s arity, which is the point: this
          # wraps that method and must not be a wider duck than it.
          # @return [self]
          def write(content)
            refuse_open_review!
            @artifact.write(content)
            @journal << DocWritten.new(epic_slug: @epic_slug, kind: @kind, path: @relative,
                                       byte_digest: address(content), graph_digest: @graph_digest)
            self
          end

          private

          # The bytes' own content address, through the same {Snapshot::Blob}
          # the reviewed-document side uses, so a document has ONE address
          # whether it is journaled here or handed to a review. Not
          # {Canonical.digest}, which would hash the JSON ENCODING of the
          # content (`JSON.generate(content)`) rather than the content: the join
          # would still be sound, but every reader who reached for the bytes
          # would compute a different number, and Canonical pins UTF-8 while a
          # file is arbitrary bytes. See {DocWritten} for the recomputation.
          def address(content) = Workspace::Snapshot::Blob.new(bytes: content).digest

          def refuse_open_review!
            return unless @reviews.open?(path)

            raise ReviewPending, "#{path} is under review, so regenerating it would discard edits nobody " \
                                 "has read yet -- settle the review first"
          end
        end

        # `Written` wraps whatever {Home} handed back, so nothing outside builds
        # one; `private` scopes methods and not constants, which is why it needs
        # its own line ({Home::Artifact}'s reasoning).
        private_constant :Written
      end
    end
  end
end
