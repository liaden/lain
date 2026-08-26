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
    # ever lands on the published path. A reader polling that path
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
      # The state feed could not be written. Named per the error-taxonomy
      # convention -- a refusal subclasses {Lain::Error} next to the owner that
      # raises it, as {Paths::Unwritable} does. Distinct from that one rather
      # than reusing it: `Unwritable` answers "a directory could not be
      # created", which is one of the three ways this fails, and the sentence
      # an operator needs here is about the state feed and the variable that
      # moves it. The kernel's own error stays reachable as `#cause`.
      class Unpublishable < Error
        def initialize(path, cause)
          super("lain cannot publish the state feed to #{path}: #{cause.message}. " \
                "This is machine state, rewritten every turn and kept out of your project " \
                "on purpose; XDG_STATE_HOME chooses where it lives.")
        end
      end

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

      # Every kernel refusal on this path becomes ONE named error, because the
      # move to `$XDG_STATE_HOME` changed which refusals are reachable. Under
      # `<project>/.lain/` the destination was essentially always writable --
      # the user is working in it -- so a bare `Errno` escaping here was a
      # disk-full curiosity. Under `$XDG_STATE_HOME` it can be read-only, owned
      # by someone else, or have a plain file where the per-project directory
      # belongs, and the raw errno names a path the operator never typed, in a
      # directory named by twelve hex characters, with no mention of lain. That
      # reads as a crash; it is a misconfiguration, and it has a lever.
      def write(struct)
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp-#{Process.pid}-#{object_id}"
        File.write(tmp, JSON.generate(struct))
        File.rename(tmp, @path)
      rescue SystemCallError => e
        raise Unpublishable.new(@path, e)
      end
    end
  end
end
