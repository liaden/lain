# frozen_string_literal: true

require "forwardable"
require "neovim"
require "socket"

module Lain
  module Frontend
    class Neovim
      # The outbound half of {RpcThread}'s work, split into its own object: the
      # backlog of not-yet-sent render commands and ITS backpressure (the
      # T6-inherited fix). {RpcThread} owns attach, the select loop, and
      # inbound dispatch; this owns nothing nvim-shaped except turning one
      # queued command into the right `nvim_exec_lua` call -- two
      # responsibilities that were, before the split, one class doing both.
      class RenderQueue
        # Append already-rendered plain lines to the journal. Guarded on
        # `_G.__lain` so a render that races a not-yet-injected runtime is a
        # harmless no-op rather than an error notification.
        APPEND = "local lines = ...; if _G.__lain then _G.__lain.render(lines) end"

        # Whole-buffer replace for a named state view (4-2.2). Same
        # not-yet-injected guard as {APPEND}.
        SET_VIEW = "local name, lines = ...; if _G.__lain then _G.__lain.set_view(name, lines) end"

        # Whole-buffer replace for the ONE editable view, lain://request (4-2.3).
        # Distinct from {SET_VIEW} only in the lua entry point it calls (which
        # skips the nomodifiable flip); same not-yet-injected guard.
        SET_REQUEST = "local name, lines = ...; if _G.__lain then _G.__lain.set_request(name, lines) end"

        # Open lain://compose on the human's draft (T15). A third entry point
        # rather than a flag on {SET_REQUEST}: that buffer is `nofile` and
        # never written, this one is `acwrite`, named, and SHOWN -- the two
        # have nothing in common but the word "editable".
        SET_COMPOSE = "local name, lines, gen = ...; if _G.__lain then _G.__lain.set_compose(name, lines, gen) end"

        # Open lain://question on a pending set's rendered document (T12).
        # {SET_COMPOSE}'s shape with the set's content digest in place of the
        # counter -- one more entry point rather than a flag, because that
        # buffer folds per question, indents to the grammar's two spaces, and
        # its write can be REFUSED; none of that is compose's.
        SET_QUESTION = "local name, lines, digest = ...; " \
                       "if _G.__lain then _G.__lain.set_question(name, lines, digest) end"

        OPEN_REVIEW = "local path, gen, slug = ...; if _G.__lain then _G.__lain.open_review(path, gen, slug) end"

        REVIEW_REFUSED = "local message = ...; if _G.__lain then _G.__lain.review_refused(message) end"

        # One queued command: `args` is exactly what the entry point named by
        # `lua` takes, already in order -- `[lines]` for the journal append,
        # `[name, lines]` for a view replace, `[name, lines, generation]` for
        # the compose open. Holding the argument LIST rather than named fields
        # is what lets a third entry point with a third arity share one queue
        # and one sender.
        Command = Data.define(:args, :lua)
        private_constant :Command

        # Default cap on outstanding commands (journal appends AND view
        # replacements share this one queue). T6-inherited fix: the queue was an
        # unbounded Thread::Queue, so a producer outpacing nvim could pile up an
        # unbounded backlog -- an adversarial probe hit ~800K entries, and
        # draining it (which runs BEFORE the RPC thread's select gets a turn)
        # took 6.4s, starving inbound acks. A SizedQueue fixes both at once:
        # {#post_render}/{#post_view} now BLOCK the producer once the queue is
        # full, so the backlog literally cannot exceed this cap, and {#drain}'s
        # per-tick batch is capped the same way for free.
        DEFAULT_CAPACITY = 1024

        def initialize(capacity: DEFAULT_CAPACITY)
          @queue = Thread::SizedQueue.new(capacity)
        end

        # Queue an append. Safe from any thread. BLOCKS the caller once the
        # queue is full, and raises ClosedQueueError once {#close} has run --
        # {Neovim#post} rescues that (see its comment).
        # @param lines [Array<String>]
        def post_render(lines)
          @queue.push(Command.new(args: [lines], lua: APPEND))
        end

        # Queue a whole-buffer replace for a named buffer. `editable:` picks the
        # lua entry point: the read-only state views (4-2.2) get {SET_VIEW}; the
        # one editable view, lain://request (4-2.3), gets {SET_REQUEST}, which
        # skips the nomodifiable flip. Same queue, backpressure, and death
        # behavior either way -- one render pipeline, not two.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param editable [Boolean]
        def post_view(name, lines, editable: false)
          @queue.push(Command.new(args: [name, lines], lua: editable ? SET_REQUEST : SET_VIEW))
        end

        # The ONE non-blocking post (T15). Every other producer is a background
        # thread that can afford to be back-pressured; this one is queued from
        # Reline's INPUT LOOP, inside keypress dispatch, where a blocked push
        # would freeze the prompt's rendering with the human given no feedback
        # at all. A full queue means nvim has stopped draining, which is the
        # same fact as "no editor took the draft" -- so it raises ThreadError
        # here and {RpcThread#open_compose} turns that into the honest answer.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param generation [Integer] stamped onto the buffer so the editor's
        #   answer says WHICH compose it is answering
        def post_compose(name, lines, generation)
          @queue.push(Command.new(args: [name, lines, generation], lua: SET_COMPOSE), true)
        end

        # Non-blocking like {#post_compose}, and for a sharper reason: this one
        # is posted from inside {QuestionView}'s lock, so a blocking push
        # against a full queue would hold that lock -- and the same lock is what
        # a write in the editor takes.
        # @param digest [String] the set's content digest, stamped onto the
        #   buffer so every write and abandon says WHICH set it answers
        def post_question(name, lines, digest)
          @queue.push(Command.new(args: [name, lines, digest], lua: SET_QUESTION), true)
        end

        def post_review(path, generation, epic_slug)
          @queue.push(Command.new(args: [path, generation, epic_slug], lua: OPEN_REVIEW), true)
        end

        def post_review_refusal(message)
          @queue.push(Command.new(args: [message], lua: REVIEW_REFUSED), true)
        end

        # Send everything currently queued, one nvim_exec_lua notify per
        # command; the caller flushes the connection once, after this returns.
        def drain(client)
          @queue.size.times { send_command(client, @queue.pop) }
        end

        # Release any producer blocked in {#post_render}/{#post_view} with a
        # ClosedQueueError, the same shape {Lain::Channel#close} uses to
        # release its own blocked producers. MUST run once nobody will ever
        # call {#drain} again (RPC-thread death, or normal teardown after the
        # sole producer thread has already stopped) -- see RpcThread's callers.
        def close
          @queue.close unless @queue.closed?
        end

        private

        def send_command(client, command)
          client.session.notify("nvim_exec_lua", command.lua, command.args)
        end
      end

      # The way IN to the editor, for every producer that is not the RPC thread
      # itself: queue the work, wake the loop, and answer whether it landed.
      # {RenderQueue} owns the backlog and its backpressure; this owns the
      # PAIR -- a post that is not followed by a wake is a render that sits
      # until the next backstop tick -- and the one policy that pair needs,
      # which is what a refused post answers.
      #
      # It exists because {RpcThread} had grown five copies of it: two blocking
      # posts and three non-blocking opens, each re-stating the queue call, the
      # wake, and (three times, in two disagreeing ways) what a dead or full
      # queue means. The RPC thread's own responsibility is attach, the select
      # loop, and inbound dispatch; being the door every renderer knocks on is
      # a second one, and this is it.
      class RenderInlet
        # The backlog is BUILT here rather than injected: {RpcThread} holding
        # both the queue and the door to it was how the five copies got there
        # in the first place. The loop reaches it through {#drain} and
        # {#close}, which is all the loop ever needed from it.
        #
        # @param waker [#call] wakes the select loop; never blocks
        # @param capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
        # The two surfaces with no view object of their own to keep their
        # sentence in. {Compose::DETACHED} and {QuestionView::DETACHED} live
        # with the objects that answer them; a review has no such half, so its
        # words live here beside the door that speaks them.
        REVIEW_DETACHED = "opening a review in the editor needs an attached editor"

        # The one refusal nobody reads: this leg exists to carry a notice INTO
        # the editor, so its failure is "the notice did not land" and there is
        # no further surface to send it to. Named rather than nil so the four
        # answers are four facts.
        UNREPORTED = "the editor did not take this notice"

        def initialize(waker:, capacity: RenderQueue::DEFAULT_CAPACITY)
          @queue = RenderQueue.new(capacity:)
          @waker = waker
        end

        # The loop's own two messages: send everything queued, and release any
        # blocked producer once nobody will ever drain again (see
        # {RenderQueue#close} for why that MUST happen on death, not only on
        # teardown).
        def drain(client) = @queue.drain(client)
        def close = @queue.close

        # The BLOCKING posts: a background producer outpacing nvim is
        # back-pressured by the queue, and a queue closed by RPC-thread death
        # raises ClosedQueueError through to the caller ({Neovim#post} rescues
        # it, having its own reason to treat the last render as a lost race).
        def post_render(lines) = deliver { @queue.post_render(lines) }

        def post_view(name, lines, editable: false) = deliver { @queue.post_view(name, lines, editable:) }

        # The NON-BLOCKING opens. All four are called from a path that cannot
        # afford to park -- Reline's input loop, the reply consumer's fiber, or
        # (the question) somebody else's lock -- so a full queue refuses instead
        # of blocking, and a refusal is the answer rather than an exception.
        #
        # ONE refusal MECHANISM for all four, because from the caller's side
        # there is one fact: no editor is taking this. A dead thread (closed
        # queue) and an editor that stopped draining (full queue) are
        # indistinguishable from here, and so is never having attached.
        #
        # The SENTENCE is the caller's, and the argument is REQUIRED so it
        # cannot be forgotten. Every refusal here once read "composing needs an
        # attached editor", which is untrue of a human answering a question; a
        # default kept that defect alive one caller over the moment the
        # parameter was added, so there is no default.
        def open_compose(lines, generation)
          refusable(Compose::DETACHED) { @queue.post_compose(Compose::BUFFER, lines, generation) }
        end

        def open_question(lines, digest)
          refusable(QuestionView::DETACHED) { @queue.post_question(QuestionView::BUFFER, lines, digest) }
        end

        def open_review(path, generation, epic_slug)
          refusable(REVIEW_DETACHED) { @queue.post_review(path, generation, epic_slug) }
        end

        def review_refused(message) = refusable(UNREPORTED) { @queue.post_review_refusal(message) }

        private

        def deliver
          yield
          @waker.call
          nil
        end

        def refusable(refusal, &block)
          deliver(&block)
        rescue ClosedQueueError, ThreadError
          refusal
        end
      end

      # Which of the frontend's OWN reactions an inbound editor command
      # triggers. Split out of {RpcThread} when the compose round trip made it
      # the third verb it had to know about: routing is a table of verbs, the
      # RPC thread is a socket and a select loop, and the two only ever met
      # because both were in the same class.
      #
      # An ACKED command lands in {RpcThread#command_inbox} regardless of what
      # happens here (a future agent-side consumer may want it), and its route
      # runs AFTER the ack, so a slow hand-off never delays the editor. A verb
      # no route claims falls through silently -- the editor's commands are not
      # this object's to validate.
      #
      # An ANSWERED command is the other kind, and there is exactly one (T12).
      # Its route's RETURN VALUE is what the editor gets, so it must run BEFORE
      # any ack -- a question `:w` is refused when the document does not parse,
      # and a refusal that arrived after a `true` would be a buffer marked saved
      # over text the grammar rejected. Two tables rather than a flag, because
      # the two kinds differ in every respect that matters: when the route runs,
      # what the editor is told, and whether the inbox ever sees it.
      class Router
        # Each route is handed the WHOLE command and destructures it itself,
        # because the verbs genuinely differ in what they carry: resend sends
        # lines, a compose write sends lines plus the generation it answers, an
        # abandon sends only that generation.
        #
        # @param listener [RpcThread::Listener] duck: #resend(lines),
        #   #compose_written(lines, generation), #compose_abandoned(generation),
        #   #question_written(lines, digest), #question_abandoned(digest).
        #   {RpcThread} is the only caller and always resolves one first (real
        #   or {RpcThread::Listener::Null}), so there is no default here.
        def initialize(listener:)
          @routes = acked(listener)
          @answers = answered(listener)
        end

        # @param arguments [Array] the command as the editor sent it: the verb,
        #   then whatever that verb carries
        def call(arguments) = @routes[arguments.first]&.call(arguments)

        def answers?(verb) = @answers.key?(verb)

        # @return [String, nil] the failure the editor must fail its write with,
        #   or nil once the command has been taken
        def answer(arguments) = @answers.fetch(arguments.first).call(arguments)

        private

        def acked(listener)
          {
            "resend" => ->(args) { listener.resend(args[1] || []) },
            "compose" => ->(args) { listener.compose_written(args[1] || [], args[2]) },
            "compose_abandon" => ->(args) { listener.compose_abandoned(args[1]) },
            "question_abandon" => ->(args) { listener.question_abandoned(args[1]) }
          }.freeze
        end

        def answered(listener)
          { "question" => ->(args) { listener.question_written(args[1] || [], args[2]) } }.freeze
        end
      end

      # The single thread that owns the nvim RPC session -- exactly one, because the
      # neovim gem's {::Neovim::Session} is single-threaded by construction
      # (`main_thread_only` raises off-thread). It attaches over a unix socket,
      # injects {runtime.lua} once, then runs ONE select loop that both serves
      # inbound requests from the editor and drains queued render work outbound --
      # the two directions the gem forces onto one thread (ROADMAP § Interface,
      # verified in planning/rpc_direction_probe.rb).
      #
      # The load-bearing gem traps this is built around:
      #
      # * Every touch of the session happens HERE. Other threads hand render work
      #   in through {#post_render} (a queue plus a wake pipe) and drain inbound
      #   commands from {#command_inbox}; they never call nvim themselves.
      # * The gem flushes writes only on the loop's NEXT read. This loop reads only
      #   when the socket is readable (it must also stay free to render), so it
      #   cannot lean on that -- it flushes the connection by hand after every
      #   write. That is why it constructs the {::Neovim::Connection} itself and
      #   keeps the handle rather than going through {::Neovim.attach_unix}.
      # * Renders go out as NOTIFICATIONS, not requests: a request would nest a
      #   read (waiting its response) that could swallow an inbound request into the
      #   session's pending queue. A notify plus a hand flush keeps reads confined
      #   to {#serve_inbound}, so the session's pending queue stays empty.
      # * Inbound requests are enqueue-and-acked in microseconds -- a slow response
      #   freezes the EDITOR -- so agent work never runs inline here.
      class RpcThread
        extend Forwardable

        # The four hand-offs this thread makes back to its owner: RPC-thread
        # death, an edited lain://request, and lain://compose being written or
        # abandoned. One object with four named methods rather than four
        # positional callbacks -- a caller states its reaction to each as a
        # method instead of a hand-defaulted lambda, and gets {Null} for free
        # when it wants none of them (the {Sink::Null} shape).
        #
        # `compose_written`/`compose_abandoned` are deliberately two methods,
        # not one taking a verb argument: they are two different things that
        # happened -- a write and an abandon carry different data (lines
        # plus a generation, vs. just a generation) -- and a caller forced to
        # branch on a symbol would only be re-deriving what {Router} already
        # knows from the wire.
        class Listener
          # RPC-thread death, after {RpcThread#start} has returned. An attach
          # failure rides {#start}'s own return instead (see
          # {RpcThread#record_death}), so this never fires for one.
          def died
            raise NotImplementedError, "#{self.class} must implement #died"
          end

          # @param lines [Array<String>] the edited lain://request lines (4-2.3)
          def resend(_lines)
            raise NotImplementedError, "#{self.class} must implement #resend"
          end

          # @param lines [Array<String>] the edited lain://compose lines (T15)
          # @param generation [Integer] which compose the editor is answering
          def compose_written(_lines, _generation)
            raise NotImplementedError, "#{self.class} must implement #compose_written"
          end

          # @param generation [Integer] which compose was unloaded unwritten
          def compose_abandoned(_generation)
            raise NotImplementedError, "#{self.class} must implement #compose_abandoned"
          end

          # The ONE hand-off whose RETURN VALUE the editor waits on (T12): the
          # human wrote lain://question, and this answers whether the document
          # parsed. It runs before the ack and inside nvim's own `:w`, so it
          # must not block for the usual reason AND must not raise -- a raise
          # here would kill the session over a mistyped line, which is why
          # {QuestionView#wrote} returns its failure instead.
          #
          # @param lines [Array<String>] the buffer as the human left it
          # @param digest [String] the set this buffer was opened for
          # @return [String, nil] the failure naming the offending line, or nil
          def question_written(_lines, _digest)
            raise NotImplementedError, "#{self.class} must implement #question_written"
          end

          # @param digest [String] the set whose buffer was unloaded unwritten
          def question_abandoned(_digest)
            raise NotImplementedError, "#{self.class} must implement #question_abandoned"
          end

          # The no-op Listener, mirroring {Sink::Null}: satisfies the same duck
          # so an {RpcThread} (or {Router}) built with none of these reactions
          # wired never needs an `if listener` guard. The default for both.
          class Null < Listener
            # The ONE hand-off a Null must not answer with silence. nil means
            # "taken" to the editor, which clears 'modified' and reports the
            # human's text saved -- and `bufhidden = "hide"` means a
            # lain://question buffer OUTLIVES the attach that made it, so a
            # write really can arrive at a frontend wiring no view. Every other
            # answer here is a no-op because nothing downstream reads it.
            UNANSWERABLE = "this editor has no question surface wired, so there is no set to answer -- " \
                           "nothing was submitted and your text is untouched"

            def died = nil
            def resend(_lines) = nil
            def compose_written(_lines, _generation) = nil
            def compose_abandoned(_generation) = nil
            def question_written(_lines, _digest) = UNANSWERABLE
            def question_abandoned(_digest) = nil
          end
        end

        RUNTIME = File.expand_path("runtime.lua", __dir__)

        # How long the readable-wait may block before re-checking the stop flag and
        # the render queue. The wake pipe is the real signal (posts and stop both
        # write it), so this is a pure liveness net bounding recovery from a lost
        # wakeup. It cannot serve a message the msgpack unpacker has already
        # buffered -- a timeout tick performs no read; what prevents buffered-
        # message starvation is nvim itself, which serializes blocking rpcrequests
        # (an unanswered one blocks the editor from sending another).
        BACKSTOP_SECONDS = 0.05

        # @param socket_path [String] a listening nvim's unix socket
        # @param version [String] the gem version, surfaced by :LainVersion
        # @param protocol [String] the runtime.lua handshake token (see {PROTOCOL})
        # @param listener [Listener] this thread's four hand-offs, bundled into
        #   one object (see {Listener}'s own comment for why). Every method
        #   MUST NOT block this thread: each runs inline after the microsecond
        #   ack, so a listener that needs to do real work hands off to a
        #   worker via a non-blocking queue (never straight onto a bounded
        #   Channel, which could wedge this thread against a full render
        #   queue). Defaults to {Listener::Null}, so a caller that wants none
        #   of the four reactions wires nothing.
        # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY};
        #   overridable so a spec can saturate the queue at a scale that runs fast
        def initialize(socket_path:, version: Lain::VERSION, protocol: PROTOCOL,
                       listener: Listener::Null.new,
                       render_capacity: RenderQueue::DEFAULT_CAPACITY)
          @socket_path = socket_path
          @version = version
          @protocol = protocol
          @listener = listener
          @router = Router.new(listener:)
          @command_inbox = Thread::Queue.new
          @wake_read, @wake_write = IO.pipe
          @inlet = RenderInlet.new(waker: method(:wake), capacity: render_capacity)
          @ready = Thread::Queue.new
          @stopped = @announced = false
        end

        # The exception that killed the serving loop after {#start}, or nil while
        # it lives. {Neovim#run} re-raises it so editor death is loud.
        # @return [StandardError, nil]
        attr_reader :failure

        # Commands the editor invoked and this thread enqueue-and-acked, for an
        # agent-side consumer to drain. A queue, never the session.
        # @return [Thread::Queue]
        attr_reader :command_inbox

        # Start the thread and block until it has attached and injected the runtime
        # (or re-raise whatever attach failed with, on the caller's thread).
        # @return [self]
        def start
          @thread = Thread.new { life }
          outcome = @ready.pop
          raise outcome if outcome.is_a?(Exception)

          self
        end

        # Every way IN to the editor, delegated whole to the object that owns
        # the queue-and-wake pair ({RenderInlet}, which documents each). Safe
        # from any thread: they touch only the {RenderQueue} and the wake pipe,
        # never nvim.
        def_delegators :@inlet, :post_render, :post_view, :open_compose, :open_question, :open_review,
                       :review_refused

        # Stop the loop, wake it out of its select, join, and close the fds this
        # thread owns. Idempotent enough for a defensive double call.
        # @return [void]
        def stop
          @stopped = true
          wake
          @thread&.join
          @inlet.close
          [@socket, @wake_read, @wake_write].each { |io| io.close unless io.nil? || io.closed? }
        end

        private

        # The wake pipe is a SIGNAL, not a queue: one unread byte already means
        # "work pending", so a full pipe needs no further write -- and MUST not
        # get one, or a producer would block against a loop that has died (the
        # teardown-hang bug: nvim dies -> loop exits -> nobody drains the pipe ->
        # a blocking write here wedges the drainer, and run's join never returns).
        def wake
          @wake_write.write_nonblock(".")
        rescue IO::WaitWritable, IOError, Errno::EPIPE
          # Full pipe: the loop is already signalled, the byte would be redundant.
          # Closed pipe: the loop is gone and there is nobody left to wake.
        end

        def life
          attach
          @announced = true
          @ready.push(:ready)
          serve until @stopped
        rescue StandardError => e
          record_death(e)
        end

        # Before {#start} has returned, the error rides @ready and re-raises on
        # the caller's thread. After, @ready has no reader ever again -- record
        # the failure where {#failure} exposes it and tell the owner, or the
        # death would be silent and the frontend a zombie.
        #
        # Closing the {RenderQueue} HERE (not only in {#stop}) is what keeps a
        # bounded queue from re-creating the teardown-hang bug the wake pipe
        # already dodges: once this loop is dead, nobody will ever {RenderQueue#drain}
        # again, so a producer mid-post against a full queue would block
        # forever without this (see {RenderQueue#close}).
        def record_death(error)
          @failure = error
          @inlet.close
          @announced ? @listener.died : @ready.push(error)
        end

        # Build the client by hand rather than via {::Neovim.attach_unix} so we keep
        # the socket (to `IO.select` on) and the connection (to flush by hand). This
        # is the public seam {::Neovim.attach} itself uses -- one blocking
        # `nvim_get_api_info` request that self-flushes -- minus the optional
        # client-info notify we do not need.
        def attach
          @socket = Socket.unix(@socket_path)
          @connection = ::Neovim::Connection.new(@socket, @socket)
          @client = ::Neovim::Client.from_event_loop(::Neovim::EventLoop.new(@connection))
          @client.exec_lua(File.read(RUNTIME), [@version, @protocol, @client.channel_id])
        end

        def serve
          drain_renders
          ready, = IO.select([@socket, @wake_read], nil, nil, BACKSTOP_SECONDS)
          react(ready) if ready
        end

        def react(ready)
          clear_wake if ready.include?(@wake_read)
          serve_inbound if ready.include?(@socket)
        end

        def drain_renders
          @inlet.drain(@client)
          @connection.flush
        end

        def clear_wake
          @wake_read.read_nonblock(4096)
        rescue IO::WaitReadable
          # Spurious wakeup -- the pipe had nothing buffered. Nothing to do.
        end

        def serve_inbound
          message = @client.session.next
          dispatch(message) if message.respond_to?(:sync?) && message.sync?
        end

        # Every editor command reaches this thread as an ordinary `lain_command`
        # rpcREQUEST -- the compose and question round trips' return legs
        # included -- so nothing here handles notifications and this thread's
        # single-owner discipline is untouched. What differs is WHEN the route
        # runs relative to the ack, and {Router} owns that distinction.
        def dispatch(request)
          return respond(request.id, nil, "lain: unknown request #{request.method_name}") unless
            request.method_name == "lain_command"

          @router.answers?(request.arguments.first) ? answer(request) : acknowledge(request)
        end

        # The ordinary path: enqueue-and-ack in microseconds, react afterwards,
        # so a slow hand-off never freezes the editor.
        def acknowledge(request)
          @command_inbox.push(request.arguments)
          respond(request.id, true)
          @router.call(request.arguments)
        end

        # The answered path (T12), and the ONLY place a route runs before the
        # ack. A question `:w` is the one editor gesture lain can refuse, so its
        # answer IS the response: a failure comes back as the request's error,
        # which is what makes the write fail and leaves the buffer modified with
        # the human's text. It stays OUT of the command inbox on purpose -- what
        # a consumer wants is the parsed answer set, which the view hands on
        # itself once the document is taken, not the raw lines it refused.
        #
        # THE RESCUE IS THE ORDERING'S PRICE. {#acknowledge} is structurally
        # immune to a raising listener -- the editor already has its answer --
        # and inverting that order inherits the obligation to answer anyway.
        # Measured without it: a listener raising NoMethodError left nvim
        # blocked in `vim.rpcrequest` for over 20 seconds, main loop frozen and
        # the human unable to type, unblocking only when the whole session tore
        # down. {Listener#question_written}'s doc has always said "must not
        # raise"; a comment is not a guard, least of all on the one path where a
        # Ruby exception freezes the editor.
        #
        # It answers a REFUSAL naming the internal error rather than an ack: a
        # frozen editor and a silently-swallowed bug are both worse than a
        # visible failure, and an ack here would clear 'modified' over text
        # nothing consumed. The raise then continues, so the death is still
        # recorded and still loud ({#record_death}).
        def answer(request)
          failure = @router.answer(request.arguments)
          failure.nil? ? respond(request.id, true) : respond(request.id, nil, failure)
        rescue StandardError => e
          respond(request.id, nil, "lain: #{e.class} answering this write, so nothing was submitted and your " \
                                   "text is untouched (#{e.message})")
          raise
        end

        # Answer an inbound request, then flush by hand -- the gem otherwise defers
        # the write to the next read, which this loop may not reach until more
        # editor traffic arrives, freezing the editor on its rpcrequest.
        def respond(id, value, error = nil)
          @client.session.respond(id, value, error)
          @connection.flush
        end
      end
    end
  end
end
