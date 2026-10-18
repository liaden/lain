# frozen_string_literal: true

require "json"

module Lain
  module Exec
    class Docker
      # Which image a tag names right now. Asked afresh on every call and never
      # memoized: a `docker build -t` of the same tag during a chat takes effect
      # on the next command, at 0.05s an inspect. It never pulls; a tag the
      # client does not have pins nothing, and the run pulls it by tag.
      class Image
        # A ceiling, capped by the asking command's deadline like {Prober}'s.
        INSPECT_BUDGET = 5

        ID = /\A[0-9a-f]{64}\z/

        # Only the fields read, 1 per line: the whole inspect carries the build
        # history and the whole Config its labels, and either outgrows the
        # capture ceiling, where cut JSON does not parse. A bare `{{.Id}}`,
        # since podman refuses `{{json .Id}}`.
        FORMAT = "{{.Id}}\n{{json .Config.Env}}\n{{json .Config.Entrypoint}}"

        # @!attribute [r] id
        #   @return [String] 64 hex characters, no `sha256:` prefix
        # @!attribute [r] env
        #   @return [Hash{String => String}] the image's `Config.Env`
        # @!attribute [r] entrypoint
        #   @return [Array<String>] the image's `Config.Entrypoint`, empty for none
        Pin = Data.define(:id, :env, :entrypoint)

        # @param tag [String] what the operator named with `--exec-image`
        # @param exec [#call] the backend the client runs through, so the
        #   operator's `DOCKER_HOST` reaches the inspect as it reaches the run
        # @param cwd [String] where the client is run from
        def initialize(tag:, exec:, cwd:)
          @tag = tag
          @exec = exec
          @cwd = cwd
          freeze
        end

        attr_reader :tag

        # @param timeout [Numeric] the asking command's deadline, of which this
        #   spends at most {INSPECT_BUDGET}
        # @return [Pin, nil] nil for a missing image, a client that did not
        #   answer in time, or an answer that is not one image's listing --
        #   invalid UTF-8 included
        def pin(timeout)
          capture = @exec.call(command: question, cwd: @cwd, env: {}, timeout: [INSPECT_BUDGET, timeout].min)
          parsed(capture.stdout) if capture.exit_status.zero?
        rescue Timeout, JSON::ParserError
          nil
        end

        # @param timeout [Numeric] as for {#pin}
        # @return [String] the pinned ID, or the tag when nothing is pinned
        def reference(timeout) = pin(timeout)&.id || tag

        private

        def question = Shell::Term.of([CLI, "image", "inspect", "--format", FORMAT, @tag])

        def parsed(stdout)
          id, env, entrypoint = stdout.lines(chomp: true)
          return unless id && env && entrypoint

          pinned(id.delete_prefix("sha256:"), JSON.parse(env) || [], JSON.parse(entrypoint) || [])
        end

        def pinned(id, env, entrypoint)
          return unless strings?([id]) && ID.match?(id) && strings?(env) && strings?(entrypoint)

          Ractor.make_shareable(Pin.new(id:, env: env.to_h { named(_1) }, entrypoint:))
        end

        def named(pair) = pair.split("=", 2).then { |name, value| [name, value.to_s] }

        def strings?(value) = value.is_a?(Array) && value.all? { _1.is_a?(String) && _1.valid_encoding? }
      end
    end
  end
end
