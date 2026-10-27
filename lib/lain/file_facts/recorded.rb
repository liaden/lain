# frozen_string_literal: true

require "pathname"

module Lain
  module FileFacts
    # The disk as a session recorded it, and nothing more: the places its header names (cwd,
    # root, home), and where its `exec_resolution` records say a path landed. It never asks File
    # or Dir.
    #
    # Anything else is a guess, and a guess is the answer that invents least: a path lands on
    # itself, and is no link, no directory and no entry of a listing. {#observing} reports whether
    # any answer was a guess, which is what a replay calls "state unknown".
    class Recorded
      # @param places [Enumerable<String, nil>] absolute directories the session recorded
      # @param landings [Hash{String=>String}] path => where it lands, for the whole session
      def initialize(places:, landings: {})
        @places = places.compact.to_set { clean(_1) }.freeze
        @session = cleaned(landings)
        @landings = @session
        @guessed = false
      end

      # @param landings [Hash{String=>String}] this call's own, over the session's
      # @return [Boolean] whether any answer given inside the block was a guess
      def observing(landings = {})
        @landings = @session.merge(cleaned(landings))
        @guessed = false
        yield
        @guessed
      ensure
        @landings = @session
      end

      def realpath(path)
        named = clean(path)
        @landings.fetch(named) { known?(named) ? named : guess(named) }
      end

      def symlink?(path)
        named = clean(path)
        return @landings.fetch(named) != named if @landings.key?(named)

        known?(named) ? false : guess(false)
      end

      def exist?(path) = known?(clean(path)) || guess(true)

      def file?(path)
        named = clean(path)
        return landing?(named) unless unrecorded?(named)

        guess(false)
      end

      def directory?(path)
        named = clean(path)
        return @places.include?(named) unless unrecorded?(named)

        guess(false)
      end

      # @raise [Errno::EINVAL] for a path no record names a link
      def readlink(path)
        named = clean(path)
        target = @landings[named]
        return target if target && target != named

        guess(nil)
        raise Errno::EINVAL, named
      end

      def glob(_pattern, **) = guess([])

      def each_child(_directory) = guess(nil)

      private

      def known?(path) = @places.include?(path) || landing?(path)

      def unrecorded?(path) = !known?(path)

      def landing?(path) = @landings.key?(path) || @landings.value?(path)

      def guess(answer)
        @guessed = true
        answer
      end

      def cleaned(landings) = landings.to_h { |path, landing| [clean(path), clean(landing)] }.freeze

      def clean(path) = Pathname.new(path).cleanpath.to_s
    end
  end
end
