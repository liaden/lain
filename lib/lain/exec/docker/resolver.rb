# frozen_string_literal: true

module Lain
  module Exec
    class Docker
      # Resolves a stage the way the container's execvp would: an image path
      # from the image's listing, a mounted one from the host. Where the image
      # cannot say what runs, every stage stays unresolved with the
      # `container_backend` anomaly, so the ladder sends the call on to the
      # judge or the human.
      #
      # An image with an `ENTRYPOINT` is not resolved: the argv goes to the
      # entrypoint, and the listing cannot say what that runs.
      class Resolver
        # @param docker [Docker] the backend whose image, mounts and crossing env are read
        # @param root [String] the project root, a realpath
        # @param fresh [#fresh?] the session's freshness, asked only about a mounted path
        # @param journal [#<<] where each image ID's {Telemetry::ExecImage} is written
        # @param paths [Paths] where the image listings are cached
        # @param notice [#call] told when an image could not be listed
        def initialize(docker:, root:, fresh:, journal:, paths:, notice:)
          @docker = docker
          @root = root
          @fresh = fresh
          @journal = journal
          @paths = paths
          @notice = notice
          @told = Set.new
          @stats = {}
          @lock = Mutex.new
        end

        # @param worker_env [WorkerEnv]
        # @return [Shell::Executable::Resolver::Bound, Shell::Executable::Resolver::Null]
        def for(worker_env)
          pin = @docker.image.pin(Image::INSPECT_BUDGET)
          listing = @docker.image.listing(pin, paths: @paths) if pin&.entrypoint&.empty?
          tell(pin, listing)
          return Shell::Executable::Resolver::CONTAINER.for(worker_env) unless listing&.entries

          bound(pin, listing.entries, worker_env)
        end

        private

        # The worker's PATH does not cross, so the search reads the image's.
        def bound(pin, entries, worker_env)
          mounts = @docker.mount_points(worker_env.cwd)
          stat = Shell::Executable::MountedStat.new(mounts:, image: listed(pin.id, entries))
          fresh = Shell::Executable::MountedFresh.new(mounts:, host: @fresh)
          Shell::Executable::Resolver.new(root: @root, fresh:, stat:, host_env: pin.env)
                                     .for(worker_env.with(cwd: @docker.workdir(worker_env.cwd),
                                                          env: @docker.crossing(worker_env.env)))
        end

        def listed(id, entries) = @lock.synchronize { @stats[id] ||= Shell::Executable::ListedStat.new(entries) }

        def tell(pin, listing)
          return unless @lock.synchronize { @told.add?(pin&.id) }

          record(pin, listing)
          failure = listing&.failure
          @notice.call(notice_of(failure)) if failure
        end

        def record(pin, listing)
          @journal << Telemetry::ExecImage.new(image: @docker.tag, id: pin&.id, listed: !listing&.entries.nil?,
                                               reason: reason(pin, listing))
        rescue SystemCallError, IOError, Journal::Closed
          nil
        end

        def reason(pin, listing)
          return "docker image inspect named no image ID for #{@docker.tag}" unless pin
          return listing.failure&.reason if pin.entrypoint.empty?

          "the image declares ENTRYPOINT #{pin.entrypoint.inspect}, which the argv would go to"
        end

        def notice_of(failure)
          retry_hint = "; delete #{failure.cache} and relaunch to retry" if failure.cache
          "container programs could not be listed (#{failure.reason}), so every docker bash call goes to " \
            "the judge or to the human#{retry_hint}"
        end
      end
    end
  end
end
