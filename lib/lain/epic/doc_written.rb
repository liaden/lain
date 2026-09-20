# frozen_string_literal: true

module Lain
  module Epic
    # One artifact landed on disk, journaled by {Home::Journaled} AFTER the write
    # returns. An ack and never an intent: a record here means those bytes were
    # on disk, so a reader may join `byte_digest` to the file and expect them to
    # match until the next write of the same path. The converse does not hold --
    # see {Home::Journaled} for why a missing record proves nothing.
    #
    # `path` is relative to the epic home rather than absolute, because an epic
    # home moves with `$XDG_STATE_HOME` and travels between machines when it
    # lives in the repo; an absolute path would stop naming what it describes.
    #
    # `byte_digest` addresses the RAW BYTES through {Workspace::Snapshot::Blob},
    # the same address the reviewed-document side computes. It is recomputed with
    # exactly:
    #
    #   Workspace::Snapshot::Blob.new(bytes: File.binread(path)).digest
    #
    # and with nothing else. It is NOT `b3sum <file>`: Blob domain-separates with
    # a git-style `blob <size>\0` header so file content cannot collide with the
    # JSON-canonical digests every other Store object uses. Nor is it
    # {Canonical.digest}, which hashes `JSON.generate(content)` -- injective, so
    # the join would work, but no reader holding the bytes would arrive at the
    # number, and Canonical pins UTF-8 where a file is arbitrary bytes.
    #
    # `graph_digest` is the epic write's second address: the same bytes can be
    # re-emitted from an equal graph, and a reader auditing "which graph is on
    # disk" wants the graph's own content address rather than a re-parse. It is
    # nil for the three prose artifacts, and structurally so -- a graph digest is
    # a property of the resolved artifact, which prose has no way to acquire.
    DocWritten = Data.define(:epic_slug, :kind, :path, :byte_digest, :graph_digest) do
      include Telemetry::Journalable

      def initialize(epic_slug:, kind:, path:, byte_digest:, graph_digest: nil)
        epic_slug = -epic_slug.to_s
        kind = -kind.to_s
        path = -path.to_s.strip
        byte_digest = -byte_digest.to_s
        # `&&=`, so an absent graph stays absent rather than interning to "" --
        # a blank digest would read as a graph nothing can match.
        graph_digest &&= -graph_digest.to_s
        Contracts::DocWritten.check!(epic_slug:, kind:, path:, byte_digest:)

        super
      end
    end

    class DocWritten
      # See {IssueTransition::JOURNAL_TYPE}.
      JOURNAL_TYPE = "doc_written"
    end
  end
end
