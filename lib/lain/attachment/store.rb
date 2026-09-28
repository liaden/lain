# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Attachment
    # One project's attachments, filed under their content address. The
    # subsystem's argument -- why these bytes are not in {Lain::Store} and not on
    # the Timeline -- is on {Attachment} itself; what is here is the directory
    # and the two refusals.
    #
    # Identity is the directory: two Stores over one root are interchangeable and
    # do not compare equal, because there is no `==` here. Nothing needs one
    # today, and `eq` between two Stores is therefore the wrong reach.
    #
    # @note Nothing prunes it, and retention is a decision deliberately left open
    #   while the tools that write here are still being built. Two kinds of
    #   garbage accumulate and they share one answer: a blob no session file
    #   references any more, and a `.partial` left by a writer that died
    #   mid-write. Neither is ever read -- {#key?} looks only for the digest's
    #   own name -- and the scratch name carries the writing pid, so a sweeper
    #   can tell a dead writer's leavings from a live one's.
    class Store
      # A digest nothing on disk answers. Loud rather than nil: an image block
      # resolved to nothing is a question about a picture the model never saw.
      class Missing < Error; end

      # Bytes that stopped hashing to the name they are filed under. The address
      # is a claim about the bytes, so this is not a miss -- and it is the
      # integrity alarm, which is why {#canonical} exists to keep a merely
      # misspelled digest from raising it.
      class Corrupt < Error; end

      KIND = "attachments"

      # Its own keyspace, for the reason {Sensitivity::Regions::Region} states:
      # sharing the snapshot's `blob` tag would make one digest mean a file the
      # workspace wrote and a picture a tool made, silently.
      TAG = "attachment-v1"

      # Names two hex digits of fan-out, as git does, so one project's directory
      # does not become one flat directory of thousands.
      FANOUT = 2

      PREFIX = "#{Canonical::DIGEST_ALGORITHM}:".freeze
      private_constant :PREFIX

      # The door for a caller holding a project root rather than a container key
      # -- the recipe itself is {ProjectDir#container}'s.
      #
      # @param root [String] the project root
      # @param paths [Paths] the XDG resolver
      # @return [Store]
      def self.for(root:, paths: Paths.new)
        new(root: ProjectDir.new(root:, paths:).container(KIND))
      end

      # @return [String] the directory blobs are filed under, created lazily
      attr_reader :root

      # Interned rather than merely held: a frozen Store over a String the caller
      # still owns relocates when they append to it, which is the failure the
      # freeze is meant to make unrepresentable.
      def initialize(root:)
        @root = -root.to_s
        freeze
      end

      # Idempotent: the digest already names the content, so storing the same
      # bytes twice writes once.
      #
      # That short-circuit is on EXISTENCE while {#fetch} verifies, so re-putting
      # correct bytes does not heal a blob corrupted out of band -- the asymmetry
      # is deliberate (a read that re-hashes costs one pass over bytes already in
      # hand; a write that did would re-read every hit), and healing is the
      # retention decision's business, not a side effect of a put.
      #
      # @param bytes [String]
      # @return [String] the content address
      def put(bytes)
        blob = ContentAddressed::Blob.new(bytes:, tag: TAG)
        write(blob) unless File.exist?(path_for(blob.digest))
        blob.digest
      end

      # @param digest [String]
      # @return [String] the stored bytes, BINARY-encoded
      # @raise [Missing] when nothing on disk answers the digest
      # @raise [Corrupt] when what does no longer hashes to it
      # @raise [ArgumentError] on a string that is not a digest
      def fetch(digest)
        address = canonical(digest)
        path = path_for(address)
        raise Missing, "no attachment #{address} in #{self}" unless File.exist?(path)

        File.binread(path).tap do |bytes|
          raise Corrupt, "attachment #{address} in #{self} no longer hashes to its own name" unless
            ContentAddressed::Blob.new(bytes:, tag: TAG).digest == address
        end
      end

      def key?(digest) = File.exist?(path_for(canonical(digest)))

      def to_s = "#<#{self.class} #{root}>"
      alias inspect to_s

      private

      # ONE reading of a digest string, shared by every door, because a lenient
      # path and a strict comparison disagreeing is how intact bytes come to
      # raise {Corrupt}: a filename match says yes, the re-hash then compares
      # against the caller's spelling rather than the blob's, and the operator is
      # pointed at the disk over a missing prefix.
      #
      # Case is a spelling of the same number, and on a case-insensitive
      # filesystem the two spellings are literally one file, so it is normalized.
      # The algorithm prefix is part of the identity rather than a spelling of
      # it, so its absence is the caller's error and not a miss -- a digest that
      # lost its prefix somewhere (a model echoing one back, say) is worth
      # hearing about where it was mangled.
      def canonical(digest)
        hex = digest.to_s.delete_prefix(PREFIX)
        raise ArgumentError, "not a #{Canonical::DIGEST_ALGORITHM} digest: #{digest.inspect}" unless
          digest.to_s.start_with?(PREFIX) && hex.match?(/\A\h{64}\z/)

        "#{PREFIX}#{hex.downcase}"
      end

      # Takes an address already through {#canonical}, or one this class made.
      def path_for(address)
        hex = address.delete_prefix(PREFIX)
        File.join(root, hex[0, FANOUT], hex)
      end

      # Written beside and renamed, because a reader sharing the directory must
      # never open half a blob: rename is atomic within a filesystem, and the
      # whole directory is one.
      #
      # The scratch name is unique per WRITER and not merely per process. Lain
      # runs subagents as threads over one Store, so a name keyed on the pid
      # alone is one name for all of them: the first rename moves the inode away
      # and every other writer renames a file that is gone. With a name of its
      # own each rename lands, the last one wins, and losing is success -- the
      # bytes are identical by construction, which is what content addressing
      # means.
      def write(blob)
        path = path_for(blob.digest)
        FileUtils.mkdir_p(File.dirname(path))
        partial = "#{path}.#{Process.pid}-#{SecureRandom.hex(8)}.partial"
        File.binwrite(partial, blob.bytes)
        File.rename(partial, path)
      end
    end
  end
end
