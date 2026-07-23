# frozen_string_literal: true

module Lain
  module CLI
    # Resolves `--fork "<session>@<digest-prefix>"` into the parent file and
    # the FULL digest of the fork point. The file part reuses
    # {Resume::Selector}'s rules unchanged (empty picks the newest, prefix
    # must be unique); the digest prefix resolves against the turn digests
    # RECORDED in that file -- the same set the fold later verifies as chain
    # membership ({Bench::Session::Loader#on_chain?}) -- so a selector can
    # only ever name a turn the parent actually recorded. Resolution only
    # READS: verification stays where it lives, in the load's re-commit fold.
    class ForkPoint
      SHAPE = "<session>@<digest-prefix>"

      # Where a fork starts: the parent journal's path and the full digest of
      # the recorded turn the new run's Timeline checks out.
      Point = Data.define(:path, :digest)

      # @param dir [String] the project's session directory
      def initialize(dir:)
        @dir = dir
      end

      # @param selector [String] `<session>@<digest-prefix>`; an empty file
      #   part forks the newest session, and the digest prefix matches with
      #   or without its `blake3:` scheme
      # @return [Point]
      # @raise [Resume::Refusal] -- including for a file that vanishes
      #   between the Selector's listing and this read (a reaped ephemeral,
      #   an external rename): the TOCTOU maps to a refusal, never a raw
      #   Errno::ENOENT
      def call(selector)
        file_part, digest_part = parts(selector)
        path = Resume::Selector.new(dir: @dir).call(file_part)
        Point.new(path:, digest: resolved(path, digest_part))
      rescue Errno::ENOENT
        # `path || selector`: the read that can ENOENT happens after the
        # Selector resolved the path, but a vanished DIRECTORY would land
        # here earlier -- name whatever we have rather than a nil basename.
        raise Resume::Refusal, "#{File.basename(path || selector.to_s)} vanished before its turns could " \
                               "be read (reaped or renamed underneath the fork); list and retry"
      end

      private

      def parts(selector)
        file_part, digest_part = selector.to_s.split("@", 2)
        return [file_part.to_s, digest_part] unless digest_part.to_s.empty?

        raise Resume::Refusal, "a fork selector needs a fork point: #{SHAPE} (got #{selector.inspect})"
      end

      def resolved(path, prefix)
        matches = recorded_digests(path).select { |digest| match?(digest, prefix) }
        return matches.first if matches.size == 1

        raise Resume::Refusal, "no turn matching #{prefix.inspect} recorded in #{File.basename(path)}" if matches.empty?

        raise Resume::Refusal, "#{prefix.inspect} is ambiguous in #{File.basename(path)}: #{matches.join(", ")}"
      end

      # Hex-only below a full "blake3:" prefix: a partial scheme spelling
      # ("b", "bla") would otherwise match EVERY digest through the scheme
      # string and silently resolve on a one-turn file (T3 fix round).
      def match?(digest, prefix)
        return digest.start_with?(prefix) if prefix.start_with?("blake3:")

        digest.delete_prefix("blake3:").start_with?(prefix)
      end

      # A turn record without a "digest" key (hand-edited, foreign writer)
      # refuses namedly rather than leaking a raw KeyError backtrace.
      def recorded_digests(path)
        Journal.records(File.foreach(path), type: SessionRecord::TURN_TYPE)
               .map { |record| digest_of(record, path) }.to_a.uniq
      end

      def digest_of(record, path)
        record.fetch("digest") do
          raise Resume::Refusal, "#{File.basename(path)} holds a turn record with no \"digest\" field; " \
                                 "the file is malformed, so no fork point can be trusted from it"
        end
      end
    end
  end
end
