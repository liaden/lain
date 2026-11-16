# frozen_string_literal: true

require "json"

module Lain
  module Herdr
    # Talks to herdr's workspaces from a process that is not a chat in a herdr pane, so there is no
    # {Target}: the binary comes from the environment or PATH. Every failure reads as "did nothing",
    # because a missing herdr must never stop a poll or a cockpit start.
    class Workspaces
      SOURCE = "lain-queue"

      # A call that hangs must not hold the caller open.
      TIMEOUT = 5

      # @param env [Hash{String=>String}]
      # @param shell_out_factory [#call] `Shell::Out.new`, or a double
      def initialize(env: ENV, shell_out_factory: Shell::Out.public_method(:new))
        @env = env
        @shell_out_factory = shell_out_factory
      end

      # @param label [String] the workspace to mark
      # @param name [String] the token key herdr shows in the workspace header
      # @param value [String]
      # @return [void]
      def token(label:, name:, value:)
        id = workspace_id(label) or return

        run("workspace", "report-metadata", id, "--source", SOURCE, "--token", "#{name}=#{value}")
      end

      # @return [void]
      def notify(title:, body:) = run("notification", "show", title, "--body", body)

      # @param cwd [String]
      # @param command [String] typed into the new workspace's root pane
      # @return [void]
      def create(cwd:, command:)
        pane = answer("workspace", "create", "--cwd", cwd).dig("result", "root_pane", "pane_id")
        run("pane", "run", pane, command) if pane
      end

      private

      def workspace_id(label)
        answer("workspace", "list").dig("result", "workspaces")&.find { _1["label"] == label }&.fetch("workspace_id")
      end

      # @return [Hash] herdr's JSON reply, empty when it failed or was not an object
      def answer(*argv)
        parsed = JSON.parse(run(*argv) || "")
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # @return [String, nil] stdout when herdr ran and succeeded
      def run(*argv)
        bin = binary or return
        out = @shell_out_factory.call(bin, *argv, environment: server, timeout: TIMEOUT).tap(&:run_command)
        out.stdout if Shell::Out.ok?(out)
      rescue SystemCallError, Shell::Out::Timeout
        nil
      end

      def binary
        explicit = @env["HERDR_BIN_PATH"]
        explicit.to_s.empty? ? Shell::Path.find("herdr", path: @env.fetch("PATH", "")) : explicit
      end

      def server = @env.slice("HERDR_SOCKET_PATH")
    end
  end
end
