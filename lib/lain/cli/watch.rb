# frozen_string_literal: true

module Lain
  module CLI
    # `lain watch SELECTOR`: a read-only live view of ONE actor's stream. Tails
    # a session journal (a plain poll on one fd -- surviving rename/rotation is
    # deliberately out of scope), admits only the records whose lineage chains
    # to the spawn the selector names ({LineageFilter}), renders each through
    # the injected sink duck, and stops at the session_closed record. Read-only
    # BY CONSTRUCTION: it opens the journal with mode "r" and holds no Store,
    # no provider, and no Channel -- there is nothing here that could write,
    # push, or spend.
    #
    # {#run} answers an exit status the exe passes straight through: 0 when the
    # watched spawn was seen, 1 when the session closed without the selector
    # ever matching -- a typo'd prefix must be distinguishable from a quiet
    # actor, so it is said on the sink AND in the status, never silent.
    class Watch
      # A bare selector would anchor on the first spawn in the file -- a guess
      # wearing a match's clothes -- so it is refused before any read happens.
      class EmptySelector < Error; end

      # No `path:` and no recorded sessions: nothing to tail, said loudly.
      class NoSession < Error; end

      SESSION_CLOSED_TYPE = "session_closed"
      POLL_SECONDS = 0.2

      # @param selector [String] a prefix of the watched spawn's event digest
      # @param sink [#puts] the IO-shaped sink duck ({Sink::IOAdapter}'s
      #   surface); the exe hands the terminal in, specs hand a StringIO
      # @param path [String, nil] the session file to tail; nil follows this
      #   project's newest recorded session
      # @param sleeper [#call] the poll wait, injectable so a spec tails
      #   deterministically instead of sleeping
      def initialize(selector:, sink:, path: nil, paths: Paths.new, view: View.new,
                     sleeper: ->(seconds) { sleep(seconds) })
        raise EmptySelector, "selector must be a spawn-digest prefix, got #{selector.inspect}" if selector.to_s.empty?

        @selector = selector
        @sink = sink
        @path = path
        @paths = paths
        @view = view
        @sleeper = sleeper
        @filter = LineageFilter.new(selector:, on_shadowed: ->(digest) { shadowed(digest) })
      end

      # @return [Integer] 0 once session_closed lands with the watched spawn
      #   seen; 1 when the session closed and no spawn ever matched
      def run
        File.open(journal_path, "r") { |io| follow(io) }
        conclude
      end

      private

      # The tail as composition: {Tail} yields only COMPLETE lines,
      # {Journal.records} parses them and skips foreign bytes (the shared-fd
      # contract every reader honors), and the first closer stops the pull --
      # `any?` IS the loop, short-circuiting on the closer.
      def follow(io)
        tail = Tail.new(io, wait: -> { @sleeper.call(POLL_SECONDS) })
        Journal.records(tail).any? { |record| closed_by?(record) }
      end

      # One parsed record: render what chains to the watched spawn, and answer
      # whether this record closed the session.
      def closed_by?(record)
        render(record) if @filter.admit?(record)
        record["type"] == SESSION_CLOSED_TYPE
      end

      def render(record)
        @view.lines(record).each { |line| @sink.puts(line) }
      end

      # The no-match verdict, spoken AND returned: an unmatched selector must
      # never end indistinguishable from a quiet actor.
      def conclude
        return 0 if @filter.anchored?

        @sink.puts("no spawn matched selector #{@selector.inspect}")
        1
      end

      # The one loud diagnostic for an ambiguous selector ({LineageFilter}'s
      # `on_shadowed` seam): the later matching spawn is named, then ignored.
      def shadowed(digest)
        @sink.puts("selector also matches #{digest}; watching #{@filter.anchor} only")
      end

      def journal_path
        @path || newest_session
      end

      # {Sessions}' discovery idiom: Dir.children, sorted -- the filenames are
      # UTC-timestamped, so lexicographic IS chronological.
      def newest_session
        dir = @paths.sessions_dir
        names = Dir.children(dir).select { |name| name.end_with?(".ndjson") }.sort
        raise NoSession, "no sessions recorded under #{dir}" if names.empty?

        File.join(dir, names.last)
      end

      # The fd tail as an Enumerable of COMPLETE ("\n"-terminated) lines,
      # composing with {Journal.records}. The fragment buffer lives here: at
      # EOF, IO#gets consumes a torn write's first half WITHOUT its newline,
      # so a tailer that hands that half onward desyncs -- both halves fail
      # parse separately and the record is silently lost (a torn
      # session_closed would hang the watch forever). Held halves are joined
      # with the bytes the writer lands later and yielded whole.
      #
      # Infinite by design: the consumer stops pulling (see {Watch#follow});
      # there is no closer to detect at this altitude.
      class Tail
        include Enumerable

        # @param io [IO] an fd positioned wherever the caller wants the tail
        #   to start
        # @param wait [#call] invoked once per EOF before re-reading
        def initialize(io, wait:)
          @io = io
          @wait = wait
          @fragment = +""
        end

        def each(&block)
          return enum_for(:each) unless block_given?

          loop { pull(&block) }
        end

        private

        def pull
          piece = @io.gets
          if piece.nil?
            @wait.call
          else
            @fragment << piece
          end
          yield take if @fragment.end_with?("\n")
        end

        def take
          line = @fragment
          @fragment = +""
          line
        end
      end

      # The display duck -- {Frontend::Neovim::JournalView}'s shape (#lines:
      # one record in, plain text lines out), over admitted NDJSON records
      # instead of Channel events. Plain text on purpose: the sink may be a
      # terminal or a buffer, and neither wants ANSI invented here.
      class View
        # The digest-prefix width the inspect idiom shows (see Event#inspect).
        SHORT = 19

        # @param record [Hash{String=>Object}] one admitted message record
        # @return [Array<String>] attributed lines, one per body line
        def lines(record)
          prefix = "[#{shorten(record["digest"])} #{record["kind"]}]"
          body(record).chomp.split("\n", -1).map { |line| line.empty? ? prefix : "#{prefix} #{line}" }
        end

        private

        # Dispatches on KIND -- the record's discriminator -- never on which
        # payload keys happen to be present. A payload that is not a Hash (an
        # old or foreign writer's shape) renders as nothing at all: tolerated
        # garbage, like every other skipped line, never a crash.
        def body(record)
          payload = record["payload"]
          return "" unless payload.is_a?(Hash)

          decorated(text_for(record["kind"].to_s, payload), payload["lifecycle"])
        end

        # `text` is what {Tools::Subagent::Lineage#note} carries, `result`
        # what a one-shot's return message does; a :spawn carries neither and
        # renders as its own announcement.
        def text_for(kind, payload)
          kind == "spawn" ? spawn_note(payload) : payload["text"] || payload["result"]
        end

        # The lifecycle marker, when present, is the transition a reader keys
        # on -- surfaced, never parsed away.
        def decorated(text, lifecycle)
          lifecycle.nil? ? text.to_s : "(#{lifecycle}) #{text}"
        end

        def spawn_note(payload)
          "#{payload["prefix"]}/#{payload["posture"]} spawned from #{shorten(payload["spawned_from"])}"
        end

        def shorten(digest) = digest.to_s[0, SHORT]
      end
    end
  end
end

require_relative "watch/lineage_filter"
