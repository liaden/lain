# frozen_string_literal: true

module Lain
  # A command's answer as STRUCTURE: an ordered run of segments, each naming a
  # style TOKEN as a Symbol beside the words it covers. Nothing here knows a
  # colour, which is what lets this value live in `lib/lain/` and be returned by
  # a command without the `cli` layer depending on the frontend -- output
  # discipline. {Frontend::Theme} resolves a Symbol to escape sequences at
  # render time and is the only object that ever does.
  #
  # The alternative loses information: a String return is painted whole by one
  # `theme.paint(:response, ...)` call, so `/status`'s warm marker arrives the
  # same colour as the word "inbox" beside it. A String stays a first-class
  # return for every command that has no such structure.
  #
  # Immutable throughout, so a half-built renderable can be reused as a prefix
  # or shared across Ractors; `Ractor.shareable?` is spec'd.
  class Renderable
    include Enumerable

    # `text` is interned frozen rather than frozen in place: freezing a caller's
    # own String is a side effect nobody asked for (`-str` copies, `str.freeze`
    # would not).
    Segment = Data.define(:token, :text) do
      def initialize(token:, text:) = super(token: token.to_sym, text: -text.to_s)

      # The theme is a collaborator, never a type: an unregistered token raises
      # there rather than rendering plain here.
      def paint(theme) = theme.paint(token, text)
    end

    # Registered in the theme with an EMPTY attribute list rather than left
    # unregistered, so both branches go through a token and a misspelling still
    # fails loudly instead of silently rendering as prose.
    PLAIN = :plain

    # @param segments [Enumerable<Segment>] splatted, never captured -- a
    #   caller's own Array is neither frozen nor aliased by this value
    def initialize(segments = [])
      @segments = [*segments].freeze
      freeze
    end

    def each(&block)
      return enum_for(:each) unless block_given?

      @segments.each(&block)
    end

    # @return [Renderable] this one's segments followed by `text` under `token`
    def with(token, text) = self.class.new([*@segments, Segment.new(token:, text:)])

    def plain(text) = with(PLAIN, text)

    def +(other) = self.class.new([*@segments, *other])

    def empty? = @segments.empty?

    # @param theme [#paint] resolves each segment's token
    # @return [String] the words, each run styled by its own token
    def paint(theme) = map { |segment| segment.paint(theme) }.join

    # For a caller with no theme in reach: a spec, a log line, a non-terminal
    # sink.
    def text = map(&:text).join

    def ==(other) = other.is_a?(self.class) && to_a == other.to_a
    alias eql? ==

    def hash = [self.class, @segments].hash

    def inspect = "#<Lain::Renderable #{map(&:token).inspect}>"
    alias to_s inspect
  end
end
