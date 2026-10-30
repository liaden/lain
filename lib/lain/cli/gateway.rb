# frozen_string_literal: true

require "securerandom"

module Lain
  module CLI
    # `lain gateway --upstream URL`: serves one allow-listed upstream on
    # loopback until interrupted, asking the human about every request. There
    # is deliberately no bind option and no way to forward without asking.
    class Gateway
      LOOPBACK = "127.0.0.1"
      PORTS = (0..65_535)
      BAD_PORT = "the gateway's port must be an integer in #{PORTS}, not %<port>p".freeze
      NOT_GIT = "%<root>s is not a git checkout, so only the gateway's environment secrets are checked, " \
                "not the project's history or ignored files"

      # @param options [Hash] the command's flags, string or symbol keys
      # @param console [#announce, #approve?] the human, a {Frontend::GatewayConsole} on the terminal
      # @param env [Hash] the gateway process's environment, read for its secrets and
      #   for the start-up key check; {Lain::Gateway::Upstream#forward} still reads
      #   the key itself from ENV
      # @param paths [Paths] supplies the home and the default log's state home
      # @option options [String] upstream the allow-listed base to forward to, required
      # @option options [Integer] port 0, the default, picks a free one
      # @option options [String] root whose git history and ignored files hold secrets; the cwd by default
      # @option options [String] log the gateway's NDJSON log; one under the state home by default
      def initialize(options, console:, env: ENV, paths: Paths.new)
        @options = options.to_h.transform_keys(&:to_sym)
        @console = console
        @env = env
        @paths = paths
      end

      # Serves until interrupted, then closes the listener and the log.
      #
      # @return [Integer] 0, the exit status
      # @raise [Lain::Gateway::Upstream::NotAllowed] for an upstream off the allow-list
      # @raise [Lain::Gateway::Upstream::MissingKey] when the environment lacks the upstream's key
      # @raise [Lain::Error] naming the port, for one outside {PORTS} or one taken or not ours to take,
      #   and naming the token file's path when something other than this user's file holds it
      def run
        port = port!
        upstream = checked(Lain::Gateway::Upstream.for(@options.fetch(:upstream)))
        token = SecureRandom.hex(16)
        Journal.open(log) do |journal|
          server = server(upstream, journal, port, token)
          serve(server, Lain::Gateway::TokenFile.for(server.port, paths: @paths), token)
        end
        0
      end

      private

      # The token file is written before the human is told the URL, and
      # removed however serving ends.
      def serve(server, file, token)
        file.write(token)
        @console.announce(url: server.url, token_file: file.path, log:, caveats:)
        server.run
      rescue Lain::Gateway::TokenFile::Unusable => e
        raise Lain::Error, "the gateway cannot leave its token for the chat: #{e.message}"
      ensure
        server.stop
        file.remove(token)
      end

      def checked(upstream)
        return upstream unless @env.fetch(upstream.key_env, "").to_s.empty?

        raise Lain::Gateway::Upstream::MissingKey, "the gateway's environment has no #{upstream.key_env}"
      end

      # Thor reads `--port` as any number, so 1.5 and 99999 arrive here to be refused.
      def port!
        port = @options.fetch(:port, 0)
        raise Lain::Error, format(BAD_PORT, port:) unless port.is_a?(Integer) && PORTS.cover?(port)

        port
      end

      def caveats = git_checkout? ? [] : [format(NOT_GIT, root:)]

      def git_checkout? = Shell::Out.ok?(Isolation::Checkout.of(root).run("rev-parse", "--show-toplevel"))

      def server(upstream, journal, port, token)
        Lain::Gateway::Server.new(bind: LOOPBACK, port:, upstream:,
                                  inspection: Lain::Gateway::Inspection.new(literals:), console: @console,
                                  journal:, token:)
      end

      def literals
        Sensitivity::Secrets::Source.new(child_env: Exec::ChildEnv.from(@env), history:)
      end

      def history = Sensitivity::HistoryLiterals.new(root:, policy:).prime

      def policy
        home = @paths.home
        Sensitivity::Policy.new(sensitivity: Sensitivity.new(home:, cwd: root, root:), home:, root:)
      end

      def root = @root ||= File.expand_path(@options.fetch(:root, nil) || Dir.pwd)

      def log = @log ||= @options.fetch(:log, nil) || File.join(@paths.state_home, "gateway", Journal.stem)
    end
  end
end
