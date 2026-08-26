# frozen_string_literal: true

module Lain
  module Epic
    class MalformedDelta < Error; end

    # What the human did to the epic document while lain was not holding it.
    #
    # {.diff} is a pure function of two sides: the bytes and graph lain last
    # WROTE, and the bytes found at settle time. It answers two questions that
    # look like one -- did the bytes move, and did the MEANING move -- because an
    # editor that trims a line and an author who rewrites an acceptance criterion
    # both change bytes, and only one of them changed the epic. That is why the
    # byte digests and the structural account are separate readers rather than
    # one "changed?". It is TOTAL over anything a file can hold: a corrupt
    # heading, a dangling edge, and bytes that are not text at all all come back
    # as a {Delta}. Everything here reports; nothing adjudicates.
    module Intake
      # One predicate per kind, so the account's vocabulary and its detection are
      # one list rather than two that must agree. `discovered_from` counts as an
      # edge here though {EDGE_FIELDS} excludes it as provenance: this account is
      # over the DOCUMENT a human edited, where all three link kinds are the same
      # line shape, and an edited `Discovered from:` falling between the kinds
      # would be an edit the delta silently lost. {Document::LINK_FIELDS} is the
      # list the grammar writes, and a spec pins the whole account against
      # `Issue.members`, so a NEW member cannot fall between them either.
      CHANGED = {
        retitled: ->(before, after) { before.title != after.title },
        redescribed: ->(before, after) { before.description != after.description },
        edges_changed: lambda { |before, after|
          Document::LINK_FIELDS.each_value.any? { |field| before.public_send(field) != after.public_send(field) }
        },
        status_changed: ->(before, after) { before.status != after.status },
        criteria_changed: ->(before, after) { before.criteria != after.criteria }
      }.freeze

      KINDS = [:added, :removed, *CHANGED.keys].freeze
      NO_IDS = [].freeze

      # Gathered because they mean one thing to a caller -- these bytes are not
      # an epic. MalformedIssue is listed even though Document re-raises it as a
      # MalformedDocument naming the line: a delta that crashed because that
      # re-raise moved would be worse than one that reports.
      PARSE_FAILURES = [MalformedDocument, MalformedGraph, MalformedIssue].freeze

      NOT_TEXT = "the document on disk is not valid UTF-8 (%<size>d bytes), so it is not an epic document " \
                 "-- a file saved in another encoding, or a write that did not finish"

      class << self
        def diff(written:, disk:)
          # Measured over the BYTES before the parse can refuse, so the suspicion
          # cannot differ for the same bytes depending on whether they parsed.
          measured = { written_digest: byte_digest(written.bytes), disk_digest: byte_digest(disk),
                       lossy: lossy?(written.bytes, disk) }
          account = Account.between(written.graph, Document.parse_markdown(readable(disk)))
          Delta.new(**measured, account:, error: nil, error_kind: nil)
        rescue *PARSE_FAILURES => e
          Delta.malformed(e, **measured)
        end

        # LESS THAN HALF the bytes came back, which is the whole of what
        # {Delta#lossy?} denotes. Measured in bytes rather than in issues because
        # truncation is a byte phenomenon -- a cut file is a byte prefix -- and
        # because bytes are the one measure available on BOTH branches: swept
        # over 2..6 issues, an issue-count measure gave opposite answers for the
        # same document 15 times in 45, depending only on whether a heading was
        # corrupt. Nothing is lost by dropping it -- "what left" is
        # {Account#removed}, exactly and without a threshold. Doubling rather
        # than a 0.5 factor because integers say "less than half" exactly.
        def lossy?(written_bytes, disk_bytes) = disk_bytes.bytesize * 2 < written_bytes.bytesize

        # As {Workspace::Snapshot::Blob} computes it -- over the RAW bytes under
        # a git-style header, NOT through {Canonical}, which pins UTF-8 and would
        # refuse arbitrary file content. Reused rather than restated so a document
        # reviewed here and one snapshotted into the Store name one address.
        def byte_digest(bytes) = Workspace::Snapshot::Blob.new(bytes:).digest

        private

        # The parse is a regex walk, and every regex operation over bytes that
        # are not valid UTF-8 raises ArgumentError from inside String -- not a
        # Lain::Error, and not something exe/lain renders, though it is exactly
        # what .diff exists to absorb. `dup` because force_encoding mutates and
        # the bytes may be frozen; encoding is a label on the same bytes, so a
        # BINARY-read copy of a UTF-8 file passes here and compares equal.
        def readable(disk)
          text = disk.dup.force_encoding(Encoding::UTF_8)
          raise MalformedDocument, format(NOT_TEXT, size: disk.bytesize) unless text.valid_encoding?

          text
        end
      end

      # The bytes and graph lain last wrote, as one value: a review opens against
      # this and settles against it, so the two travel together. `bytes` defaults
      # to what {Document.to_markdown} emits -- what {Home#write_epic} put on disk.
      Written = Data.define(:bytes, :graph) do
        include Declarative

        # Only the SHAPE of the written side is declared: `raising:` is
        # per-declaration, and {#recorded}'s refusal is a {MalformedDocument}
        # about whether two members AGREE -- a different question with a different
        # answer class. `bytes` is either emitted or parsed, never judged.
        declare raising: MalformedGraph do
          attribute :graph

          validate :must_be_a_graph

          def must_be_a_graph
            return if graph.is_a?(Graph)

            errors.add(:graph, "is the written side of an intake, so it must be an Epic::Graph " \
                               "(got #{graph.inspect})")
          end
        end

        # `bytes:` defaults to nil rather than to the emit because a keyword
        # default is evaluated BEFORE the body, so a `graph` that is not a Graph
        # would reach Document as a NoMethodError instead of a refusal.
        def initialize(graph:, bytes: nil)
          self.class.check!(graph:)
          super(bytes: bytes.nil? ? Document.to_markdown(graph) : recorded(graph, bytes), graph:)
        end

        def byte_digest = Intake.byte_digest(bytes)
        def graph_digest = graph.digest

        private

        # Caller-supplied bytes only. Bytes and graph that disagree make every
        # delta computed from them contradict itself: the disk can match the
        # bytes exactly, and so read byte_identical, while differing from the
        # graph the structural kinds are measured against. The test is the PARSE
        # rather than the bytes, so a write differing only in whitespace is still
        # on record honestly. The EMIT skips it -- Writer refuses every graph it
        # cannot write back and the round trip is pinned generatively.
        def recorded(graph, bytes)
          text = Canonical.normalize(bytes)
          return text if Document.parse_markdown(text).digest == graph.digest

          raise MalformedDocument, "the written bytes parse to a different epic than the written graph " \
                                   "(#{graph.digest} was written as #{text.inspect})"
        end
      end

      # The bytes lain last wrote for an artifact that is PROSE -- research and
      # the issue plan are written to be read, not resolved -- so a review has to
      # be openable over a written side with no graph at all. BESIDE {Written}
      # rather than inside it: Written's invariant is that its bytes and its
      # graph agree, and a Written widened to tolerate a missing graph would hold
      # its invariant only sometimes.
      #
      # {#graph_digest} answers nil because a graph digest is a property of the
      # RESOLVED artifact, and it is the whole seam -- what a reader consults to
      # learn that a delta over these bytes was measured and never compared,
      # rather than compared and found equal. Nothing here parses: running the
      # grammar over a research note would report prose as a malformed epic.
      Prose = Data.define(:bytes) do
        include Declarative

        # `check!` and not `settle!`: settling would hand back `bytes.dup.freeze`
        # where the constructor interns instead.
        declare raising: MalformedDocument do
          attribute :bytes

          validate :must_be_the_written_bytes

          def must_be_the_written_bytes
            return if bytes.is_a?(String)

            errors.add(:bytes, "are what lain wrote, so the written side of a prose intake is a String " \
                               "(got #{bytes.inspect})")
          end
        end

        def initialize(bytes:)
          self.class.check!(bytes:)
          # Interned rather than normalized through {Canonical}, which pins
          # UTF-8: prose is never parsed, and a written side refusing a note
          # saved in another encoding would refuse the file most in need of it.
          super(bytes: -bytes)
        end

        def byte_digest = Intake.byte_digest(bytes)
        def graph_digest = nil
      end
    end
  end
end

# Loaded last: Account is `Data.define(*KINDS)`, so the vocabulary above has to
# exist before this file is read (the same rule effect/handler.rb's children follow).
require_relative "intake/delta"
