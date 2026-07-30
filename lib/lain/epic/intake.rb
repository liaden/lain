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
    # one "changed?".
    #
    # It is TOTAL over anything a file can hold. A human handing work back is not
    # an error condition, so a corrupt heading, a dangling edge, a half-written
    # file, and bytes that are not text at all all come back as a {Delta}. The
    # values are total in the other direction too: {Written} refuses bytes that
    # disagree with its graph and {Delta} refuses the states this comment calls
    # impossible, so no consumer has to trust a convention.
    #
    # Everything here reports; nothing adjudicates. The one judgement a delta
    # ventures ({Delta#lossy?}) is named as the suspicion it is.
    module Intake
      # What "the same issue changed" means, one predicate per kind, so the
      # account's vocabulary and its detection are one list rather than two that
      # must agree.
      #
      # `discovered_from` counts as an edge here though {EDGE_FIELDS} excludes it
      # as provenance: this account is over the DOCUMENT a human edited, where
      # all three link kinds are the same line shape, and an edited
      # `Discovered from:` that fell between the kinds would be an edit the delta
      # silently lost. {Document::LINK_FIELDS} is the list the grammar itself
      # writes, so the two cannot drift -- and a spec pins the whole account
      # against `Issue.members`, so a NEW member cannot fall between them either.
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

      # The failures a disk read may hit, gathered because they mean one thing to
      # a caller -- these bytes are not an epic. Document converts an issue-level
      # refusal into a MalformedDocument naming the line, and Graph raises its own
      # for duplicate ids, dangling edges, and cycles, which a truncated file
      # reaches easily. MalformedIssue is listed anyway: a delta that crashed
      # because that re-raise moved would be worse than one that reports.
      PARSE_FAILURES = [MalformedDocument, MalformedGraph, MalformedIssue].freeze

      NOT_TEXT = "the document on disk is not valid UTF-8 (%<size>d bytes), so it is not an epic document " \
                 "-- a file saved in another encoding, or a write that did not finish"

      class << self
        def diff(written:, disk:)
          # Everything measured over the BYTES is settled before the parse can
          # refuse, so both branches carry the same three values: T15 journals
          # the digests either way, and the suspicion cannot come out different
          # for the same bytes depending on whether they happened to parse.
          measured = { written_digest: byte_digest(written.bytes), disk_digest: byte_digest(disk),
                       lossy: lossy?(written.bytes, disk) }
          account = Account.between(written.graph, Document.parse_markdown(readable(disk)))
          Delta.new(**measured, account:, error: nil, error_kind: nil)
        rescue *PARSE_FAILURES => e
          Delta.malformed(e, **measured)
        end

        # Much less came back than went out: LESS THAN HALF the bytes, which is
        # the whole of what {Delta#lossy?} denotes.
        #
        # Measured in bytes rather than in issues because truncation is a byte
        # phenomenon -- a cut file is a byte prefix -- and because bytes are the
        # one measure available on BOTH branches. An issue-count measure could
        # not answer at all when the parse failed, and a predicate that changes
        # measure with the branch answers a different question on each: swept
        # over 2..6 issues, it gave opposite answers for the same document 15
        # times in 45 depending only on whether a heading was corrupt.
        #
        # Nothing is lost by dropping the issue count. "What left" is
        # {Account#removed}, which states it exactly, always, and without a
        # threshold; `lossy?` is only ever "was this file cut short?".
        #
        # Doubling rather than a 0.5 factor, because "less than half the bytes
        # came back" is what the sentence says and integers say it exactly.
        # Public: a caller building its own Delta must be able to answer the
        # module's own question rather than guess at it.
        def lossy?(written_bytes, disk_bytes) = disk_bytes.bytesize * 2 < written_bytes.bytesize

        # The address of a file's bytes, as {Workspace::Snapshot::Blob} computes
        # it -- over the RAW bytes under a git-style header, NOT through
        # {Canonical}, which pins UTF-8 and would refuse arbitrary file content.
        # Reused rather than restated so that a document reviewed here and the
        # same document snapshotted into the Store name one address; a second
        # copy of the formula is a second thing that can drift.
        def byte_digest(bytes) = Workspace::Snapshot::Blob.new(bytes:).digest

        private

        # The parse is a regex walk, and every regex operation over bytes that
        # are not valid UTF-8 raises ArgumentError from inside String -- not a
        # Lain::Error, and not something exe/lain renders. `Home::Artifact#read`
        # is `File.read`, so an editor that saved Latin-1 and a write that died
        # mid-file both arrive here, and both are exactly what .diff exists to
        # absorb. `dup` because force_encoding mutates and the bytes may be
        # frozen; encoding is a label on the same bytes, so a BINARY-read copy of
        # a UTF-8 file passes here and compares equal.
        def readable(disk)
          text = disk.dup.force_encoding(Encoding::UTF_8)
          raise MalformedDocument, format(NOT_TEXT, size: disk.bytesize) unless text.valid_encoding?

          text
        end
      end

      # The bytes and graph lain last wrote, as one value: a review opens against
      # this and settles against it, so the two have to travel together. `bytes`
      # defaults to what {Document.to_markdown} emits, which is exactly what
      # {Home#write_epic} put on disk -- pass them explicitly only when the write
      # is on record as something else.
      Written = Data.define(:bytes, :graph) do
        # `bytes:` defaults to nil rather than to the emit because a keyword
        # default is evaluated BEFORE the body, so a `graph` that is not a Graph
        # would reach Document as a NoMethodError instead of a refusal.
        def initialize(graph:, bytes: nil)
          refuse_stranger!(graph)
          super(bytes: bytes.nil? ? Document.to_markdown(graph) : recorded(graph, bytes), graph:)
        end

        def byte_digest = Intake.byte_digest(bytes)
        def graph_digest = graph.digest

        private

        def refuse_stranger!(graph)
          return if graph.is_a?(Graph)

          raise MalformedGraph, "the written side of an intake must be an Epic::Graph (got #{graph.inspect})"
        end

        # Caller-supplied bytes only. Bytes and graph that disagree make every
        # delta computed from them contradict itself: the disk can match the
        # bytes exactly, and so read byte_identical, while differing from the
        # graph the structural kinds are measured against. The test is the PARSE
        # rather than the bytes, so a write differing only in whitespace is still
        # on record honestly.
        #
        # The EMIT skips this: Document::Writer refuses every graph it cannot
        # write back and the round trip is pinned generatively in
        # document_spec, so a defaulted `bytes` can never disagree -- checking it
        # would be a second parse of a document we just wrote.
        def recorded(graph, bytes)
          text = Canonical.normalize(bytes)
          return text if Document.parse_markdown(text).digest == graph.digest

          raise MalformedDocument, "the written bytes parse to a different epic than the written graph " \
                                   "(#{graph.digest} was written as #{text.inspect})"
        end
      end
    end
  end
end

# Loaded last: Account is `Data.define(*KINDS)`, so the vocabulary above has to
# exist before this file is read (the same rule effect/handler.rb's children follow).
require_relative "intake/delta"
