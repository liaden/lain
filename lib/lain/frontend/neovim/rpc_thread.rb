# frozen_string_literal: true

require "neovim"
require "socket"

module Lain
  module Frontend
    class Neovim
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
        RUNTIME = File.expand_path("runtime.lua", __dir__)

        # Append already-rendered plain lines. Guarded on `_G.__lain` so a render
        # that races a not-yet-injected runtime is a harmless no-op rather than an
        # error notification.
        APPEND = "local lines = ...; if _G.__lain then _G.__lain.render(lines) end"

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
        # @param on_death [#call] invoked (on this thread) if the loop dies after
        #   {#start} -- the owner's chance to make the loss observable
        def initialize(socket_path:, version: Lain::VERSION, protocol: PROTOCOL, on_death: -> {})
          @socket_path = socket_path
          @version = version
          @protocol = protocol
          @on_death = on_death
          @renders = Thread::Queue.new
          @command_inbox = Thread::Queue.new
          @wake_read, @wake_write = IO.pipe
          @ready = Thread::Queue.new
          @stopped = false
          @announced = false
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
        # any thread: it touches only a queue and a pipe, never nvim.
        # @param lines [Array<String>]
        # @return [void]
        def post_render(lines)
          @renders.push(lines)
          wake
        end

        # Stop the loop, wake it out of its select, join, and close the fds this
        # thread owns. Idempotent enough for a defensive double call.
        # @return [void]
        def stop
          @stopped = true
          wake
          @thread&.join
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
        def record_death(error)
          @failure = error
          @announced ? @on_death.call : @ready.push(error)
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
          @renders.size.times { @client.session.notify("nvim_exec_lua", APPEND, [@renders.pop]) }
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
