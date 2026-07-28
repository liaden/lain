# frozen_string_literal: true

require "json"
require "fileutils"

module Lain
  class StatusFeed
    # Where the state struct actually lands on disk, extracted from
    # {StatusFeed} when the derivations grew past the class's line budget and
    # the cop named what had been hiding in it: this class's own doc opens
    # "derives one small state struct ... AND republishes it", and the two
    # halves of that sentence change for different reasons. Deriving is an
    # EVENT concern (which record moves which field); publishing is a FILE
    # concern (where the path is, how the bytes replace, what a half-written
    # one would do to a reader), and it is the half with a failure mode a
    # review probe had to go looking for.
    #
    # Atomic replace: the new bytes land in a sibling file in the SAME
    # directory (so the rename is a same-filesystem, single-inode-swap
    # operation), and only `File.rename` -- never a partial `File.write` --
    # ever lands on the published path. A reader polling `.lain/state.json`
    # (tmux's `#(jq …)`) therefore only ever observes a WHOLE, valid struct,
    # never a half-written one; a failed write (ENOSPC, permissions) leaves
    # the prior good state in place instead of corrupting it, and raises,
    # because a state feed that cannot write is not a state feed that should
    # pretend it did.
    #
    # The change token is the caller's, not this object's: {StatusFeed} knows
    # which of its fields are events and which are clock readings, and this
    # object only has to remember the last token it was given and compare.
    class Publication
      # @param path [String] the published file
      def initialize(path)
        @path = path
        @published = nil
      end

      # Publish, unless this exact token was the last one published -- a
      # duplicate delivery or an event the caller recognized nothing about
      # must not cost a write+rename it did not earn.
      #
      # The full struct is built by the BLOCK rather than passed in, so a
      # caller composing it out of something expensive (or something read from
      # a running clock, which must be stamped at write time and not before)
      # pays only on a publish that actually happens.
      #
      # @param token [Object] compared with `==` against the last published
      # @yieldparam token [Object] the same token, for composing the struct
      # @yieldreturn [Object] the JSON-shaped struct to write
      # @return [Boolean] whether bytes actually landed
      def call(token)
        return false if token == @published

        write(yield(token))
        @published = token
        true
      end

      private

      def write(struct)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp-#{Process.pid}-#{object_id}"
        File.write(tmp, JSON.generate(struct))
        File.rename(tmp, @path)
      end
    end
  end
end
