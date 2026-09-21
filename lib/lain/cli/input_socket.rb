# frozen_string_literal: true

require "fileutils"
require "json"
require "socket"

module Lain
  module CLI
    # The chat's end of the input rail when the human types somewhere else: a
    # Unix socket the chat listens on and {Frontend::InputPane} connects to. It
    # is a rail PRODUCER like {Frontend::StdinPump} is, and the chat running one
    # reads no stdin at all.
    #
    # THE PATH CARRIES NO PID, deliberately. `lain up` writes both pane commands
    # before either process exists, so the name has to be derivable from the
    # project and the tmux session alone -- and a chat restarted in the same
    # window binds the same path, which is what lets a pane that outlived it
    # reconnect. A path that is a FILE and not a live listener is therefore
    # ordinary rather than exceptional: it is unlinked and rebound, under a lock
    # that makes the refusal of a second live chat an enforced one.
    #
    # Threads, not fibers: the rail is explicitly safe across both, and an accept
    # loop on the conversation's reactor would tie the human's input to the
    # scheduling of the run it is meant to interrupt -- the reactor can spend a
    # long stretch inside work that yields to nothing.
    #
    # NOTHING HERE EVER BLOCKS ON A PANE. A pane that is alive but has stopped
    # reading -- a Ctrl-Z'd `lain input` keeps its descriptor open -- would
    # otherwise park the publish thread in `write(2)`, darken every other pane,
    # and, because the goodbye is written on the chat's own exit path, stop the
    # chat exiting at all. So every write is a {Client}'s non-blocking one and a
    # pane past its backlog is dropped rather than waited on.
    #
    # The wire is newline-delimited JSON of the rail's own values. Three frames
    # are not rail values and are here because the rail's PRODUCER contract
    # needs them: `context` carries what the pane cannot derive (the command
    # names it completes against, since it holds no registry), `touch` is the
    # pane's answer to `untouched?`, and `closed` is the goodbye that tells a
    # clean shutdown from a kill.
    class InputSocket
      # What an `--input` option asks for. The name is the tmux session's, so
      # two cockpits on one project do not share a socket.
      PREFIX = "socket:"
      DEFAULT_NAME = "chat"

      # How often the header is recomposed for a pane that is drawing. The HUD
      # moves on turns, not on keystrokes, so this is a cadence rather than a
      # poll of anything expensive -- and nothing is composed at all while no
      # pane is connected.
      TICK = 0.25

      # What a dropped pane and a refused line are told to the chat's screen as.
      DROPPED = "input pane dropped: it stopped reading and fell too far behind. " \
                "It reconnects on its own; the frames it missed are gone."
      # The bound is filled in at the call, since {Client} is defined below.
      OVER_LIMIT = "input pane sent one line past %<bytes>d bytes and it was refused whole. " \
                   "Nothing of it reached the chat."

      # Another chat is already listening. Named rather than a sentence because
      # the refusal has to name the path: the human's next move is to look at
      # the other pane or delete the file.
      class InUse < Error
        def initialize(path)
          super("another lain chat is already listening on #{path}. " \
                "One chat owns one input socket; close that one, or name a different --input socket:<name>.")
        end
      end

      # The path cannot be a socket at all -- a directory sits there, its parent
      # is missing, or it is past the kernel's 108-byte limit. Distinct from
      # {InUse} because the human's move is different and because the kernel's
      # own wording lies here: a directory on the path fails `connect(2)` with
      # EADDRINUSE, which reads exactly like the refusal it is not.
      class Unusable < Error
        # The kernel's own wording cannot be passed through here. A directory
        # on the path fails `connect(2)` with EADDRINUSE -- "Address already in
        # use" -- which reads exactly like the {InUse} refusal this is not. So
        # each errno lain can actually meet on this path is translated, and
        # only one it has never met is named by its class.
        REASONS = {
          Errno::EADDRINUSE => "something that is not a lain input socket is already on that path",
          Errno::ENOENT => "the directory it would live in does not exist",
          Errno::EACCES => "lain is not allowed to write there",
          Errno::EPERM => "lain is not allowed to write there",
          Errno::ENOTDIR => "a file sits where one of its directories should be",
          Errno::EISDIR => "a directory sits where the socket should be",
          Errno::ENAMETOOLONG => "the path is longer than a Unix socket may be",
          Errno::ENOLCK => "the filesystem cannot lock files, so two chats could not be told apart"
        }.freeze

        # An ArgumentError here is only ever Ruby refusing a path past the
        # kernel's 108-byte `sun_path`.
        def self.because(error)
          return "the path is longer than a Unix socket may be (108 bytes)" if error.is_a?(ArgumentError)

          REASONS.fetch(error.class, "#{error.class.name.split("::").last} from the kernel")
        end

        def initialize(path, reason)
          super("lain cannot open an input socket at #{path}: #{reason}. " \
                "The path is derived from the project and the --input name; check that name, " \
                "or that $XDG_RUNTIME_DIR is a directory lain may write in.")
        end
      end

      # The frame codec. Nothing here knows what a frame MEANS -- that is the
      # server's half and the pane's -- so both ends share one spelling of the
      # wire.
      module Codec
        def self.dump(frame) = "#{JSON.generate(frame)}\n"

        # @return [Hash, nil] nil for a line that is not a frame, which a stream
        #   half-written by a killed peer can be
        def self.load(line)
          parsed = JSON.parse(line.to_s)
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end
      end

      # @param option [String, nil] the `--input` value
      # @return [String, nil] the socket's name, or nil when no socket was asked for
      def self.named(option)
        return nil unless option.to_s.start_with?(PREFIX)

        name = option.to_s.delete_prefix(PREFIX)
        name.empty? ? DEFAULT_NAME : name
      end

      # {CLI::Up::Cockpit#derived_socket}'s recipe, for the input socket: one
      # project resolves to one path everywhere, and the directory is ours to
      # create so it is created at 0700.
      # `cwd:` is the project's, never the shell's: the caller has already
      # resolved which project this chat belongs to, and a default here would
      # name a different socket from the same project opened elsewhere.
      def self.path(cwd:, name: DEFAULT_NAME, paths: Paths.new)
        File.join(paths.runtime_dir, "input-#{paths.project_hash(cwd)}-#{name}.sock").tap do |sock|
          FileUtils.mkdir_p(File.dirname(sock), mode: 0o700)
        end
      end

      # @param rail [Frontend::Intake] where the pane's lines and signals go
      # @param path [String] the socket, from {.path}
      # @param header [#call] the line a pane draws above its editor, recomposed
      #   whenever it is asked -- {StatusFeed::Reading#hud} in a live chat
      # @param commands [#call] the `/command` names a pane completes against
      # @param layers [#call] the {Frontend::InputPane::LAYERS} in force, which
      #   ride WITH the prompt rather than in a frame of their own: a `/mode`
      #   flip has to reach the editor's keymap at the next prompt and not a
      #   tick later
      # @param tick [Numeric] the header's recomposition cadence, in seconds
      # @param notice [#call] where this object says what it did to a pane --
      #   {Frontend::TTY#render_warning} in a live chat. A pane dropped or a
      #   line refused in SILENCE is a flicker the human cannot account for,
      #   and the pane itself is the one surface that cannot report it
      def initialize(rail:, path:, header: -> { "" }, commands: -> { [] }, layers: -> { [] }, tick: TICK,
                     notice: SILENT)
        @rail = rail
        @path = path
        @header = header
        @commands = commands
        @layers = layers
        @tick = tick
        @notice = notice
        @bound = false
        @clients = []
        @lock = Mutex.new
        @threads = []
        @sent = nil
      end

      # Take the path, replacing whatever a killed chat left on it.
      #
      # @raise [InUse] when another live chat holds it
      # @raise [Unusable] when the path cannot carry a socket
      def bind
        @guard = claim
        refuse(occupancy)
        FileUtils.rm_f(@path)
        @server = listening_server
        File.chmod(0o600, @path)
        @bound = true
        self
      rescue Lain::Error
        # The lock is what makes the refusal enforced, so a chat that was
        # REFUSED must not keep holding it: it would become the thing refusing
        # everybody else, outliving the listener it was turned away by.
        release
        raise
      end

      # @param _task [Async::Task] the conversation's task, which this producer
      #   does not use: see the class comment on threads
      # @return [InputSocket] what {CLI::Repl} stops at the end of the conversation
      def start(_task)
        @told = @rail.attach(self)
        spawn { accepting }
        spawn { publishing }
        self
      end

      # A producer that cannot see a terminal has nothing typed at one.
      def sweep = nil

      # Whether nothing has been typed at `prompt` in ANY pane drawing it, which
      # is what {Frontend::Intake#untouched?}'s `all?` means for an
      # in-process producer. One pane mid-edit is enough to keep an answer's
      # prompt from taking the terminal, even beside a pane sitting idle. A pane
      # that has said nothing has said nothing was typed.
      def untouched?(prompt) = connected.all? { |client| client.untouched?(prompt.generation) }

      # Say goodbye, then take the path down. The order is the contract: a pane
      # that reads `closed` exits, and one whose stream simply ends waits for
      # the chat to come back. The goodbye cannot block -- this runs on the
      # chat's own exit path, and a pane that stopped reading must not be able
      # to keep the chat alive.
      def stop
        broadcast(Codec.dump({ "v" => "closed" }))
        @rail.detach(self)
        @lock.synchronize { @threads.dup }.each(&:kill)
        connected.each { |client| drop(client) }
        @server&.close
        # ONLY a path this object took: a chat that was refused must not delete
        # the socket the chat that owns it is still listening on. The path goes
        # before the lock does, so no successor can take the name while this
        # one's socket is still on it.
        FileUtils.rm_f(@path) if @bound
        release
        self
      end

      private

      def refuse(held)
        raise InUse, @path if held == :live
        raise Unusable.new(@path, "the path is there and is not a socket lain can replace") if held == :unusable
      end

      def release
        @guard&.close
        @guard = nil
      end

      # The path is HELD rather than merely probed. `flock` is released by the
      # kernel however a chat dies, so a leftover lock file is never a false
      # refusal, and two chats starting together cannot both decide the path is
      # theirs -- which probe-then-unlink let them do, the second deleting the
      # first's freshly bound socket. The file is never unlinked: removing it
      # would let a third chat create a new inode while a second still held a
      # lock on the old one.
      def claim
        # `File.new`, not `File.open`: this descriptor must OUTLIVE the method --
        # closing it is what releases the lock -- so the block form would hand
        # the path straight back to the next chat.
        guard = File.new(lock_path, File::CREAT | File::RDWR, 0o600)
        return guard if guard.flock(File::LOCK_EX | File::LOCK_NB)

        guard.close
        raise InUse, @path
      rescue SystemCallError, ArgumentError => e
        raise Unusable.new(@path, Unusable.because(e))
      end

      def lock_path = "#{@path}.lock"

      # A connect probe rather than a lock file alone: the lock says no other
      # LAIN chat owns the path, and this says whether anything at all is
      # accepting on it. Three answers, not two -- "nobody is accepting" and "I
      # was not allowed to ask" are different, and only the first licenses an
      # unlink.
      #
      # @return [Symbol] `:live`, `:stale` or `:unusable`
      def occupancy
        UNIXSocket.new(@path).close
        :live
      rescue Errno::ECONNREFUSED, Errno::ENOENT
        :stale
      rescue Errno::EACCES, Errno::EPERM
        :live
      rescue SystemCallError, ArgumentError
        :unusable
      end

      # Every kernel refusal at the bind becomes one named error: the raw ones
      # are not {Lain::Error}, so `exe/lain` renders a backtrace where the human
      # is owed a sentence naming the path they did not type.
      def listening_server
        UNIXServer.new(@path)
      rescue SystemCallError, ArgumentError => e
        raise Unusable.new(@path, Unusable.because(e))
      end

      # Registered under the lock as it is started, so {#stop} owns every thread
      # this object ever began -- including the per-connection readers, which
      # start on the accept thread and remove themselves as they end.
      def spawn(&body)
        thread = Thread.new(&body)
        @lock.synchronize { @threads << thread }
        thread
      end

      def connected = @lock.synchronize { @clients.dup }

      def accepting
        Enumerator.produce { @server.accept }.each { |io| welcome(io) }
      rescue IOError, SystemCallError
        nil
      end

      # A fresh pane is told everything at once: what it completes against, and
      # whatever is drawn right now. The sent-frame latch is cleared so the
      # current prompt reaches it even though nothing has changed.
      def welcome(io)
        client = Client.new(io)
        @lock.synchronize do
          @clients << client
          @sent = nil
        end
        deliver(client, Codec.dump({ "v" => "context", "commands" => asked(@commands, []).map(&:to_s) }))
        spawn { receiving(client) }
      end

      def receiving(client)
        # Lazy, and that is load-bearing: an eager `take_while` over an endless
        # producer buffers every line until the stream ends, so nothing the pane
        # typed would reach the rail until the pane went away.
        Enumerator.produce { client.read_line }.lazy
                  .take_while { |line| !line.nil? }.each { |line| heard(client, line) }
      rescue IOError, SystemCallError
        nil
      ensure
        drop(client)
        @lock.synchronize { @threads.delete(Thread.current) }
      end

      # One line off a pane. A refusal is SAID: the pieces of an over-long line
      # are each unparseable, so dropping them quietly leaves the chat's prompt
      # never answering and the human with nothing to read.
      def heard(client, line)
        return @notice.call(format(OVER_LIMIT, bytes: Client::FRAME_LIMIT)) if line.equal?(Client::OVERLONG)

        receive(client, Codec.load(line))
      end

      # A frame the pane sent, as the rail value it names. An unknown frame is
      # dropped: a newer pane talking to an older chat must not take the chat
      # down.
      def receive(client, frame)
        case frame&.fetch("v", nil)
        when "line" then @rail << Frontend::Intake::Line.new(text: frame["text"].to_s,
                                                             generation: frame["generation"].to_i)
        when "signal" then @rail << Frontend::Intake::Signal.new(name: frame["name"].to_s.to_sym)
        when "eof" then @rail << Frontend::Intake::Eof.new
        when "touch" then client.touched(frame["generation"].to_i, frame["untouched"] == true)
        end
      end

      # The rail's nudge says the prompt changed; the tick says the header may
      # have. One loop serves both, so a pane's header is live while it waits
      # and a withdrawn prompt reaches it with no clock at all.
      def publishing
        Enumerator.produce { @told.pop(timeout: @tick) }.each { published }
      rescue IOError, SystemCallError
        nil
      end

      # Nothing is composed while nobody is looking: the HUD, the command names
      # and the layer list are all recomposed per tick, and a chat with no pane
      # attached would pay that four times a second for its whole life.
      def published
        return if @lock.synchronize { @clients.empty? }

        frame = Codec.dump(drawn)
        fresh?(frame) ? broadcast(frame) : flush_pending
      end

      # One critical section, so a pane connecting between the compare and the
      # store cannot lose the latch reset that is how it gets its first prompt.
      def fresh?(frame)
        @lock.synchronize do
          changed = @sent != frame
          @sent = frame
          changed
        end
      end

      # The prompt as the pane draws it. The header rides WITH the prompt rather
      # than in a frame of its own: a redrawn header and a redrawn prompt are
      # the same event to a line editor, and one frame cannot arrive half-applied.
      def drawn
        prompt = @rail.published
        return { "v" => "unpublished" } if prompt.kind.nil?

        { "v" => "prompt", "kind" => prompt.kind.to_s, "text" => prompt.text.to_s,
          "header" => asked(@header, "").to_s, "keys" => prompt.keys.transform_values(&:to_s),
          "layers" => asked(@layers, []).map(&:to_s), "generation" => prompt.generation }
      end

      # A thunk is the caller's code, read on this object's own thread, and a
      # raise there would retire the thread the human types through -- for a
      # header, which is decoration. {Frontend::PromptComposer}'s containment,
      # with the same reasoning and no notify seam to warn through.
      def asked(thunk, fallback)
        thunk.call
      rescue StandardError
        fallback
      end

      def broadcast(frame) = connected.each { |client| deliver(client, frame) }

      def deliver(client, frame)
        let_go(client) unless client << frame
      end

      # A short write leaves bytes queued and only a write moves them, so the
      # tick moves what a broadcast could not.
      def flush_pending = connected.each { |client| let_go(client) unless client.drain }

      def let_go(client)
        @notice.call(DROPPED) if client.overflowed?
        drop(client)
      end

      def drop(client)
        @lock.synchronize { @clients.delete(client) }
        client.close
      end
    end

    class InputSocket
      # Reopened rather than nested, tty.rb's idiom.

      # One connected pane's end of the wire: what it has not taken yet, and
      # what it last said about the prompt it is drawing.
      #
      # THE WRITES ARE NON-BLOCKING AND BOUNDED, and that is this object's whole
      # reason to exist. A pane that is alive but has stopped reading fills its
      # socket buffer in a few hundred ordinary HUD frames; a blocking write
      # there parks the chat's publish thread, darkens every other pane, and --
      # because the goodbye is written on the chat's exit path -- stops the chat
      # exiting. So a frame is queued and flushed with `write_nonblock`, and a
      # pane more than {BACKLOG} behind is dropped rather than waited on.
      class Client
        # What a pane may fall behind by: 64 KiB, about two socket buffers of
        # ordinary HUD frames. A pane that has not read that much is not slow,
        # it has stopped -- a Ctrl-Z'd `lain input` keeps its descriptor open.
        # Measured tolerance is ~150 s of today's HUD at the production tick,
        # and ~30 s once a header carries a multi-line fleet tree.
        BACKLOG = 64 * 1024

        # What ONE frame from a pane may be, which is a DIFFERENT budget and
        # was a silent regression while it shared {BACKLOG}'s: a human pastes
        # into the pane, a plain `lain chat` has no ceiling on a pasted line,
        # and a paste past the cap arrived as pieces that were each dropped as
        # unparseable. Generous enough that no paste reaches it, and still a
        # bound on a peer that never sends a newline at all.
        FRAME_LIMIT = 8 * 1024 * 1024

        # What {#read_line} answers for a line past {FRAME_LIMIT}: refused
        # WHOLE, its tail read off and discarded, so the caller can say so
        # rather than handing the codec pieces.
        OVERLONG = :overlong

        def initialize(io)
          @io = io
          # BINARY, and every frame appended as bytes. `write_nonblock` counts
          # BYTES where `String#slice!` counts CHARACTERS, so on a UTF-8 buffer
          # a short write discards more than actually went out -- and the HUD
          # leads with a multibyte glyph, so every real frame is one where the
          # two disagree.
          @pending = String.new(encoding: Encoding::BINARY)
          @touch = {}
          @lock = Mutex.new
          @open = true
          @overflowed = false
        end

        # @return [String, Symbol, nil] the next frame line, {OVERLONG} for one
        #   past {FRAME_LIMIT}, nil once the pane's stream has ended
        def read_line
          line = @io.gets(FRAME_LIMIT)
          return line if line.nil? || line.end_with?("\n")

          rest_of_the_line
          OVERLONG
        end

        # Queue a frame, then move what the kernel will take.
        #
        # @return [Boolean] whether this pane is still worth writing to
        def <<(frame)
          @lock.synchronize { @pending << frame.b }
          drain
        end

        # Move what a short write left behind. Called on the publish tick too:
        # only a write moves the queue, and a steady prompt writes nothing for
        # minutes, so residue would otherwise sit there and the pane would hold
        # half a frame and draw nothing.
        #
        # @return [Boolean] whether this pane is still worth writing to
        def drain
          @lock.synchronize do
            flush
            @overflowed = @open && @pending.bytesize > BACKLOG
            @open &&= !@overflowed
          end
        end

        # Whether this pane was let go for falling behind, rather than for
        # going away -- the only one of the two a human is owed a word about.
        def overflowed? = @overflowed

        # What this pane last said about the prompt it is drawing. Only the
        # newest generation is kept: a report about a prompt that has gone
        # answers nothing anyone will ask.
        def touched(generation, untouched) = @lock.synchronize { @touch = { generation => untouched } }

        def untouched?(generation) = @lock.synchronize { @touch.fetch(generation, true) }

        def close
          @lock.synchronize do
            @open = false
            @io.close unless @io.closed?
          end
        rescue IOError, SystemCallError
          nil
        end

        private

        # A peer that is not reading leaves its frames queued rather than
        # blocking anyone; a peer that has gone leaves the queue cleared and the
        # client shut.
        def flush
          written = @io.write_nonblock(@pending, exception: false)
          @pending = @pending.byteslice(written..) if written.is_a?(Integer)
        rescue IOError, SystemCallError
          @open = false
          @pending = String.new(encoding: Encoding::BINARY)
        end

        # The tail of a line already refused, read off so the NEXT frame starts
        # at a frame boundary. Ends at the line ending or at the stream's end.
        def rest_of_the_line
          Enumerator.produce { @io.gets(FRAME_LIMIT) }.lazy
                    .take_while { |chunk| !chunk.nil? }.find { |chunk| chunk.end_with?("\n") }
        end
      end
    end
  end
end
