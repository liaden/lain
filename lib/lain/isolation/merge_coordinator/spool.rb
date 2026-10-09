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

            report.with(paths: report.paths.map { |path| legible(path) }, detail: legible(report.detail))
          end

          def legible_verification(verification)
            return nil if verification.nil?
            unless verification.is_a?(LandingQueue::Verification)
              raise ArgumentError, "verification must be a LandingQueue::Verification or nil, got #{verification.class}"
            end

            verification.with(detail: legible(verification.detail))
          end

          def batch!(batch)
            unless batch.nil? || batch.is_a?(Integer)
              raise ArgumentError, "batch must be an Integer or nil, got #{batch.inspect}"
            end

            batch
          end

          def legible(text) = text.dup.force_encoding(Encoding::UTF_8).scrub
        end

        # @param home [Home] whose entries and results directories hold the files
        # @param clock [#call] answers monotonic seconds, which order the ids
        # @param wall_clock [#call] answers the Time an entry is enqueued at
        def initialize(home, clock: RunClock::MONOTONIC, wall_clock: -> { Time.now })
          @home = home
          @clock = clock
          @wall_clock = wall_clock
          @last_ns = 0
        end

        # @param worker [LandingQueue::Worker]
        # @return [Entry]
        def enqueue(worker)
          entry = Entry.new(id: next_id, worker:, enqueued_at: @wall_clock.call.to_f)
          write_whole(entry_path(entry.id), JSON.generate(worker: worker.to_h, enqueued_at: entry.enqueued_at))
          entry
        end

        # An entry that already has a result was completed by a drainer that
        # stopped before deleting it, so it is deleted here and never lands twice.
        # @return [Array<Entry>] oldest first
        # @raise [Lain::Error] naming an entry file that cannot be read back
        def pending
          completed, waiting = Dir.glob("*.json", base: @home.entries).sort
                                  .map { |name| entry_named!(File.basename(name, ".json")) }
                                  .partition { |id| File.exist?(result_path(id)) }
          completed.each { |id| FileUtils.rm_f(entry_path(id)) }
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
          FileUtils.rm_f(entry_path(id))
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
