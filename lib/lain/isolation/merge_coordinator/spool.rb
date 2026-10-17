# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Lain
  module Isolation
    module MergeCoordinator
      # The queue between the processes that enqueue landings and the one that
      # drains them: a file per entry and a file per result, each named by the
      # entry's id. Every file lands by a rename from a partial name, so a
      # reader in another process sees all of it or none of it.
      #
      # An id leads with the monotonic clock, padded so 9 digits never sort
      # after 10, which orders entries within one boot and one time namespace
      # only: a reboot, or a container whose clock is offset, starts it over.
      class Spool
        ID = /\A\d{20}-\d+-\h{4}\z/

        # Each queued commit under a ref of its own, from enqueue until its
        # result is written. A worker ref is reused by the next handback under
        # the same worker id, so it cannot be what keeps a queued commit from
        # gc; this ref is, and nobody else writes it.
        class QueuedRefs
          NAMESPACE = "refs/lain/queued"

          # @param home [Home] whose git dir and branch key place the refs
          # @param shell_out_factory [#call] builds the git subprocess
          # @return [QueuedRefs]
          def self.for(home, shell_out_factory: Shell::Out.public_method(:new))
            new(git_dir: home.git_dir, key: home.key, shell_out_factory:)
          end

          # @param git_dir [String] the repository's common git directory
          # @param key [String] the branch's key, as its {Home} names it
          # @param shell_out_factory [#call] builds the git subprocess
          def initialize(git_dir:, key:, shell_out_factory: Shell::Out.public_method(:new))
            @git = Checkout.new(git_dir, shell_out_factory:)
            @key = key
          end

          # @param id [String] as {Spool#enqueue} minted it
          # @return [String] the ref the entry's commit is held under
          def ref(id) = "#{NAMESPACE}/#{@key}/#{id}"

          # @param id [String] as {Spool#enqueue} minted it
          # @param sha [String] the commit to hold
          # @raise [Lain::Error] when git will not write the ref
          def hold(id, sha)
            write = @git.update_ref(ref(id), sha, "", reason: "lain land: queued")
            raise Error, "could not hold #{sha} at #{ref(id)}: #{write.stderr.strip}" unless write.exitstatus.zero?
          end

          # A ref left behind keeps one landed commit from gc and nothing
          # more, so a failed delete is not worth failing a completed landing.
          # @param id [String] as {Spool#enqueue} minted it
          def release(id) = @git.run("update-ref", "-d", ref(id))
        end

        Entry = Data.define(:id, :worker, :enqueued_at) do
          def initialize(id:, worker:, enqueued_at:) = super(id: -id.to_s, worker:, enqueued_at: Float(enqueued_at))
        end

        # What became of one entry. Text from git and from a verifier may be
        # any bytes, and JSON carries only UTF-8, so the report's paths and
        # detail and the verification's detail are scrubbed.
        Result = Data.define(:id, :report, :verification, :batch) do
          def initialize(id:, report:, verification:, batch:)
            super(id: -id.to_s, report: legible_report(report), verification: legible_verification(verification),
                  batch: batch!(batch))
          end

          private

          def legible_report(report)
            raise ArgumentError, "report must be a WorkerHandoff::Report, got #{report.class}" unless
              report.is_a?(WorkerHandoff::Report)

            report.with(paths: report.paths.map { |path| Utf8.legible(path) }, detail: Utf8.legible(report.detail))
          end

          def legible_verification(verification)
            return nil if verification.nil?
            unless verification.is_a?(LandingQueue::Verification)
              raise ArgumentError, "verification must be a LandingQueue::Verification or nil, got #{verification.class}"
            end

            verification.with(detail: Utf8.legible(verification.detail))
          end

          def batch!(batch)
            unless batch.nil? || batch.is_a?(Integer)
              raise ArgumentError, "batch must be an Integer or nil, got #{batch.inspect}"
            end

            batch
          end
        end

        # @param home [Home] whose entries and results directories hold the files
        # @param clock [#call] answers monotonic seconds, which order the ids
        # @param wall_clock [#call] answers the Time an entry is enqueued at
        # @param refs [#hold, #release] holds each queued commit under its own ref; see {QueuedRefs}
        def initialize(home, clock: RunClock::MONOTONIC, wall_clock: -> { Time.now }, refs: QueuedRefs.for(home))
          @home = home
          @clock = clock
          @wall_clock = wall_clock
          @refs = refs
          @last_ns = 0
        end

        # The commit is held before the entry exists, so no drainer can read
        # an entry whose commit nothing keeps.
        # @param worker [LandingQueue::Worker]
        # @return [Entry]
        # @raise [Lain::Error] when the commit cannot be held
        def enqueue(worker)
          entry = Entry.new(id: next_id, worker:, enqueued_at: @wall_clock.call.to_f)
          @refs.hold(entry.id, worker.sha)
          written(entry)
        end

        # An entry that already has a result was completed by a drainer that
        # stopped before deleting it, so it is deleted here and never lands twice.
        # @return [Array<Entry>] oldest first
        # @raise [Lain::Error] naming an entry file that cannot be read back
        def pending
          completed, waiting = Dir.glob("*.json", base: @home.entries).sort
                                  .map { |name| entry_named!(File.basename(name, ".json")) }
                                  .partition { |id| File.exist?(result_path(id)) }
          completed.each { |id| finished(id) }
          waiting.filter_map { |id| read_entry(id) }
        end

        # @param id [String] the entry the result is for
        # @param result [Result]
        # @raise [ArgumentError] when the result names another entry
        # @raise [Lain::Error] when the id is not one {#enqueue} mints
        def complete(id, result)
          minted!(id)
          raise ArgumentError, "a result for #{result.id} cannot complete entry #{id}" unless result.id == id.to_s

          write_whole(result_path(id), JSON.generate(report: result.report.to_h,
                                                     verification: result.verification&.to_h, batch: result.batch))
          finished(id)
        end

        # @param id [String]
        # @return [Result, nil] nil until the entry is complete
        # @raise [Lain::Error] when the id is not one {#enqueue} mints, or its result cannot be read back
        def result(id)
          minted!(id)
          read_back(result_path(id)) do |fields|
            verification = fields.fetch(:verification)&.then { |each| LandingQueue::Verification.new(**each) }
            Result.new(id:, report: WorkerHandoff::Report.new(**fields.fetch(:report)), verification:,
                       batch: fields.fetch(:batch))
          end
        rescue Errno::ENOENT
          nil
        end

        private

        # An id arrives from the command line and becomes a path, so only the
        # shape {#next_id} mints may reach the filesystem.
        def minted!(id)
          raise Error, "#{id.inspect} is not a landing entry id" unless ID.match?(id.to_s)
        end

        def entry_named!(id)
          raise Error, "the landing spool file #{entry_path(id)} is not named as an entry" unless ID.match?(id)

          id
        end

        # The bump keeps one process's entries in order when the clock reads
        # the same nanosecond twice.
        def next_id
          @last_ns = [(@clock.call * 1_000_000_000).to_i, @last_ns + 1].max
          format("%<ns>020d-%<pid>d-%<salt>s", ns: @last_ns, pid: Process.pid, salt: SecureRandom.hex(2))
        end

        def written(entry)
          write_whole(entry_path(entry.id), JSON.generate(worker: entry.worker.to_h, enqueued_at: entry.enqueued_at))
          entry
        rescue StandardError
          @refs.release(entry.id)
          raise
        end

        def finished(id)
          FileUtils.rm_f(entry_path(id))
          @refs.release(id)
        end

        # An entry completed between the listing and the read is gone, and no longer pending.
        def read_entry(id)
          read_back(entry_path(id)) do |fields|
            Entry.new(id:, worker: LandingQueue::Worker.new(**fields.fetch(:worker)),
                      enqueued_at: fields.fetch(:enqueued_at))
          end
        rescue Errno::ENOENT
          nil
        end

        # Lets ENOENT through, since a missing file is an answer and not a
        # corruption.
        def read_back(path)
          yield JSON.parse(File.read(path, encoding: Encoding::UTF_8), symbolize_names: true)
        rescue JSON::ParserError, KeyError, ArgumentError, TypeError => e
          raise Error, "the landing spool file #{path} cannot be read back: #{e.message}"
        end

        # The fsync is what lets a result survive a power loss after the
        # entry's deletion.
        def write_whole(path, json)
          FileUtils.mkdir_p(File.dirname(path))
          partial = "#{path}.#{Process.pid}-#{SecureRandom.hex(8)}.partial"
          File.open(partial, File::WRONLY | File::CREAT | File::EXCL) do |file|
            file.write(json)
            file.fsync
          end
          File.rename(partial, path)
        end

        def entry_path(id) = File.join(@home.entries, "#{id}.json")
        def result_path(id) = File.join(@home.results, "#{id}.json")
      end
    end
  end
end
