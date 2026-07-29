# frozen_string_literal: true

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

      # Which of the frontend's OWN reactions an inbound editor command
      # triggers. Split out of {RpcThread} when the compose round trip made it
      # the third verb it had to know about: routing is a table of verbs, the
      # RPC thread is a socket and a select loop, and the two only ever met
      # because both were in the same class.
      #
      # Every command still lands in {RpcThread#command_inbox} regardless of
      # what happens here (a future agent-side consumer may want it), and every
      # route runs AFTER the ack, so a slow hand-off never delays the editor.
      # A verb no route claims falls through silently -- the editor's commands
      # are not this object's to validate.
      class Router
        # Each route is handed the WHOLE command and destructures it itself,
        # because the verbs genuinely differ in what they carry: resend sends
        # lines, a compose write sends lines plus the generation it answers, an
        # abandon sends only that generation.
        #
        # @param listener [RpcThread::Listener] duck: #resend(lines),
        #   #compose_written(lines, generation), #compose_abandoned(generation).
        #   {RpcThread} is the only caller and always resolves one first (real
        #   or {RpcThread::Listener::Null}), so there is no default here.
        def initialize(listener:)
          @routes = {
            "resend" => ->(args) { listener.resend(args[1] || []) },
            "compose" => ->(args) { listener.compose_written(args[1] || [], args[2]) },
            "compose_abandon" => ->(args) { listener.compose_abandoned(args[1]) }
          }.freeze
        end

        # @param arguments [Array] the command as the editor sent it: the verb,
        #   then whatever that verb carries
        def call(arguments) = @routes[arguments.first]&.call(arguments)
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

          # The no-op Listener, mirroring {Sink::Null}: satisfies the same duck
          # so an {RpcThread} (or {Router}) built with none of these reactions
          # wired never needs an `if listener` guard. The default for both.
          class Null < Listener
            def died = nil
            def resend(_lines) = nil
            def compose_written(_lines, _generation) = nil
            def compose_abandoned(_generation) = nil
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
          @render_queue = RenderQueue.new(capacity: render_capacity)
          @command_inbox = Thread::Queue.new
          @wake_read, @wake_write = IO.pipe
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

        # Hand a batch of rendered lines to the RPC thread and wake it. Safe from
        # any thread: it touches only the {RenderQueue} and the wake pipe, never
        # nvim. Backpressure and the ClosedQueueError-on-death behavior are
        # {RenderQueue}'s (see its docs); {Neovim#post} rescues that error.
        # @param lines [Array<String>]
        # @return [void]
        def post_render(lines)
          @render_queue.post_render(lines)
          wake
        end

        # Replace a named buffer wholesale. `editable:` distinguishes the
        # read-only state views (4-2.2) from the one editable view, lain://request
        # (4-2.3); see {RenderQueue#post_view}. Same queue, backpressure, and
        # death behavior as {#post_render} -- one render pipeline, not two.
        # @param name [String] the lain:// buffer name
        # @param lines [Array<String>]
        # @param editable [Boolean]
        # @return [void]
        def post_view(name, lines, editable: false)
          @render_queue.post_view(name, lines, editable:)
          wake
        end

        # {Compose}'s editor inlet (T15): open lain://compose on the human's
        # draft. Called from Reline's input loop, so BOTH steps are
        # non-blocking -- {RenderQueue#post_compose} refuses to block on a full
        # queue, and {#wake} never blocks by construction.
        #
        # @param lines [Array<String>] the draft, one entry per line
        # @param generation [Integer] see {RenderQueue#post_compose}
        # @return [String, nil] nil when the draft landed, else the notice
        #   saying it did not. This thread being dead (closed queue) and its
        #   editor having stopped draining (full queue) are one fact from the
        #   prompt's side -- there is no editor taking drafts -- so they share
        #   {Compose::DETACHED} with the never-attached case.
        def open_compose(lines, generation)
          @render_queue.post_compose(Compose::BUFFER, lines, generation)
          wake
          nil
        rescue ClosedQueueError, ThreadError
          Compose::DETACHED
        end

        # Stop the loop, wake it out of its select, join, and close the fds this
        # thread owns. Idempotent enough for a defensive double call.
        # @return [void]
        def stop
          @stopped = true
          wake
          @thread&.join
          @render_queue.close
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
          @render_queue.close
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
          @render_queue.drain(@client)
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

        def dispatch(request)
          if request.method_name == "lain_command"
            @command_inbox.push(request.arguments)
            respond(request.id, true)
            # The frontend's own reaction, driven AFTER the ack ({Router}).
            # Every editor command reaches this thread as an ordinary
            # `lain_command` rpcREQUEST -- the compose round trip's return leg
            # (T15) included -- so nothing here handles notifications and this
            # thread's single-owner discipline is untouched.
            @router.call(request.arguments)
          else
            respond(request.id, nil, "lain: unknown request #{request.method_name}")
          end
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
