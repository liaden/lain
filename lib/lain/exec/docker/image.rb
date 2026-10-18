# frozen_string_literal: true

require "async"
require "json"
require "securerandom"
require "tmpdir"

module Lain
  module Exec
    class Docker
      # Which image a tag names right now. Asked afresh on every call and never
      # memoized: a `docker build -t` of the same tag during a chat takes effect
      # on the next command, at 0.05s an inspect. It never pulls; a tag the
      # client does not have pins nothing, and the run pulls it by tag.
      #
      # What an ID holds never changes, so its {#listing} is exported once and
      # cached on disk under the ID.
      class Image
        # A ceiling, capped by the asking command's deadline like {Prober}'s.
        INSPECT_BUDGET = 5

        # Export time grows with the image's size, and a slow one is cached as a failure.
        LISTING_BUDGET = 60

        REMOVE_BUDGET = 5

        DEFAULT_PATH = "/bin:/usr/bin"

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

        # @!attribute [r] entries
        #   @return [Hash{String => Shell::Executable::ListedStat::Entry}, nil] nil when the image could not be listed
        # @!attribute [r] failure
        #   @return [Failure, nil] why there are no entries
        Listing = Data.define(:entries, :failure)

        # @!attribute [r] reason
        #   @return [String] in words, for a human
        # @!attribute [r] cache
        #   @return [String, nil] the cache file holding this failure, which is deleted to retry; nil when the failure
        #     is remembered only by this process
        Failure = Data.define(:reason, :cache)

        # The client or its daemon refused; unlike a timeout or a bad tar, that need not recur for the ID.
        class Refused < Error; end

        private_constant :Refused

        # @param tag [String] what the operator named with `--exec-image`
        # @param exec [#call] the backend the client runs through, so the
        #   operator's `DOCKER_HOST` reaches the inspect as it reaches the run
        # @param cwd [String] where the client is run from
        def initialize(tag:, exec:, cwd:)
          @tag = tag
          @exec = exec
          @cwd = cwd
          @listings = {}
          @lock = Mutex.new
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

        # The lock is held across the export so parallel subagents export once.
        # A refusal is remembered only by this object, so a new process asks again.
        #
        # @param pin [Pin] the image to list
        # @param paths [Paths] where the cache lives
        # @return [Listing] the image's `PATH` children, their link hops and every ancestor directory, or why not;
        #   deeply frozen
        def listing(pin, paths:)
          file = paths.exec_image_listing(pin.id)
          @lock.synchronize { @listings[file] ||= cached(file) || fetched(pin, file) }
        end

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

        def cached(file)
          case JSON.parse(File.read(file), symbolize_names: true)
          in { entries: Array => rows } if rows.all? { _1 in [String, String, Integer, Integer, Integer, String | nil] }
            listed(rows.to_h { |path, *fields| [path, Shell::Executable::ListedStat::Entry.new(*fields)] })
          in { failure: String => reason } then failed(reason, file)
          else nil
          end
        rescue SystemCallError, JSON::ParserError
          nil
        end

        def fetched(pin, file)
          entries = exported(pin.id) { Export.read(_1) }
          listed(Export.keep(entries, path: pin.env.fetch("PATH", DEFAULT_PATH))).tap { stored(file, rows(_1.entries)) }
        rescue Timeout
          lasting(file, "docker export did not finish in #{LISTING_BUDGET}s")
        rescue Gem::Package::Error => e
          lasting(file, "docker export wrote an unreadable tar: #{e.message}")
        rescue Refused => e
          failed(e.message, nil)
        end

        def listed(entries) = Ractor.make_shareable(Listing.new(entries:, failure: nil))

        def failed(reason, cache)
          Ractor.make_shareable(Listing.new(entries: nil, failure: Failure.new(reason:, cache:)))
        end

        def lasting(file, reason) = failed(reason, (file if stored(file, { failure: reason })))

        # The tar goes to a file, not a pipe, so the inner backend's deadline and kill bound the export.
        def exported(id)
          name = "lain-export-#{SecureRandom.hex(6)}"
          Dir.mktmpdir("lain-export") do |dir|
            tar = File.join(dir, "image.tar")
            created(name, id)
            run(["export", "-o", tar, name], LISTING_BUDGET)
            File.open(tar, "rb") { yield _1 }
          end
        ensure
          removed(name)
        end

        # A dummy command, so an image with no `CMD` still creates.
        def created(name, id)
          run(["create", "--name", name, id, "true"], INSPECT_BUDGET)
        rescue Timeout
          raise Refused, "docker create did not finish in #{INSPECT_BUDGET}s"
        end

        # Shielded because a stop or an interrupt landing in the rm would kill it and leave the container behind.
        def removed(name)
          shielded do
            @exec.call(command: Shell::Term.of([CLI, "rm", "-f", name]), cwd: @cwd, env: {}, timeout: REMOVE_BUDGET)
          end
        rescue Timeout
          nil
        end

        def shielded(&block)
          task = Async::Task.current?
          task ? task.defer_stop(&block) : Thread.handle_interrupt(Object => :never, &block)
        end

        def run(words, budget)
          capture = @exec.call(command: Shell::Term.of([CLI, *words]), cwd: @cwd, env: {}, timeout: budget)
          return if capture.exit_status.zero?

          raise Refused, "docker #{words.first} exited #{capture.exit_status}: #{capture.stderr.strip}"
        end

        # A cache that cannot be written still leaves this process its listing.
        def stored(file, document)
          AtomicFile.write(file, JSON.generate(document))
          true
        rescue SystemCallError
          false
        end

        def rows(entries)
          { entries: entries.map { |path, entry| [path, entry.type, entry.mode, entry.uid, entry.gid, entry.link] } }
        end
      end
    end
  end
end
