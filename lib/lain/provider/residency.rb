# frozen_string_literal: true

require "digest"
require "fileutils"

module Lain
  class Provider
    # Which model one local endpoint has loaded, held across every process on
    # this machine while a request for it is in flight, so a request for another
    # model cannot make the server swap it out mid-stream.
    #
    # Three files per endpoint. `.meta` is a brief exclusive lock around each
    # decision; `.resident` names the model; `.lock` is held shared by every
    # request for that model. A request for another model takes `.lock`
    # exclusively, which succeeds only once every holder is gone. Linux does not
    # convert LOCK_EX to LOCK_SH atomically, so the conversion happens under
    # `.meta`, where no other request can decide in the window.
    #
    # `.lock` is opened per request, never per Residency: flock conflicts are
    # between open file descriptions, so 2 requests in 1 process share only
    # when each has its own. A dead holder's flock goes with its process, so a
    # stale `.resident` costs nothing.
    #
    # Every wait is a `Kernel#sleep` poll, for {Admission}'s reason: a blocking
    # flock would stall the whole reactor thread.
    class Residency
      # The longest a queued request waits for another model to be released,
      # after which it proceeds without the lock: one `request_timeout`, as {Admission} reasons.
      DEFAULT_DEADLINE = 300.0
      # How long a wait runs before the caller is told whom it waits on, as {FileLock} does.
      DEFAULT_PATIENCE = 5
      POLL_INTERVAL = 0.05
      SKIPPED = :skipped

      # A request that would not queue found another model resident. Raised
      # before the round trip is dispatched, so nothing reached the wire.
      class Skipped < Error
        include PreWire
      end

      # @param endpoint [String] the endpoint the provider resolved for itself
      # @param paths [Paths] whose state home holds the lock files
      # @param patience [Numeric] seconds of waiting before the notice
      # @return [Residency, Null] Null for an endpoint that is not on this machine
      def self.for(endpoint:, paths:, patience: DEFAULT_PATIENCE)
        return Null.new unless Admission::Endpoint.local?(endpoint)

        canonical = Admission::Endpoint.canonical(endpoint)
        dir = File.join(paths.state_home, "locks")
        begin
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          raise Paths::Unwritable.new(dir, e)
        end
        new(base: File.join(dir, "residency-#{Digest::SHA256.hexdigest(canonical)[0, 16]}"), endpoint: canonical,
            patience:)
      end

      # @param base [String] the lock files' path, without the extension
      # @param endpoint [String] the endpoint a journaled wait names
      # @param patience [Numeric] seconds of waiting before the notice
      # @param interval [Numeric] seconds between tries while another model is held
      # @param clock [#call] the monotonic reading the deadline is measured against
      def initialize(base:, endpoint:, patience: DEFAULT_PATIENCE, interval: POLL_INTERVAL,
                     clock: RunClock::MONOTONIC)
        @meta = FileLock.new("#{base}.meta", interval:, label: "the residency of #{endpoint}")
        @lock_path = "#{base}.lock"
        @resident_path = "#{base}.resident"
        @endpoint = endpoint
        @patience = patience
        @interval = interval
        @clock = clock
      end

      # A deadline of 0 is a skip, not a wait, so it journals nothing, as {Admission#try_enter} does.
      # A positive one that passes runs the block without the lock and journals that it proceeded.
      # @param model [String] the model the request asks for
      # @param deadline [Numeric] seconds to wait while another model is held; 0 never waits
      # @param journal [#<<] given a {Waited} once a wait ends
      # @param notice [#call] given a {Waiting} once, when a wait outlasts the patience
      # @return the block's value, or {SKIPPED} without running it for a deadline of 0
      def holding(model:, deadline:, journal:, notice: Isolation::ParentLock::Silent, &)
        File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          resident = attempt(lock, model)
          if resident.nil? then yield
          elsif deadline.positive? then after_waiting(lock, Waiting.new(endpoint: @endpoint, model:, resident:),
                                                      deadline, journal, notice, &)
          else SKIPPED
          end
        end
      end

      # @return [String] the model last held here, "" when none ever was; a snapshot, not a hold
      def resident = @meta.hold { read_resident }

      private

      # Closing the descriptor, in #holding, is what releases the endpoint.
      def after_waiting(lock, waiting, deadline, journal, notice)
        started = @clock.call
        held = waited?(lock, waiting, started, deadline, notice)
        journal << Waited.new(**waiting.to_h, outcome: held ? "held" : "proceeded", waited: @clock.call - started)
        yield
      end

      def waited?(lock, waiting, started, deadline, notice)
        told = false
        until (remaining = deadline - (elapsed = @clock.call - started)) <= 0
          told ||= told?(notice, waiting, elapsed)
          sleep([@interval, remaining].min)
          return true if attempt(lock, waiting.model).nil?
        end
        false
      end

      # Tells the notice once the patience has run out.
      # @return [Boolean] whether the notice has been told
      def told?(notice, waiting, elapsed)
        return false if elapsed < @patience

        notice.call(waiting)
        true
      end

      # @return [String, nil] the model holding the endpoint, or nil once `lock` holds it for `model`
      def attempt(lock, model)
        @meta.hold do
          resident = read_resident
          claimed?(lock, resident, model) ? named(resident, model) : resident
        end
      end

      def read_resident = File.exist?(@resident_path) ? File.read(@resident_path) : ""

      def named(resident, model)
        File.write(@resident_path, model) unless resident == model
        nil
      end

      def claimed?(lock, resident, model)
        return lock.flock(File::LOCK_SH | File::LOCK_NB) if [model, ""].include?(resident)

        lock.flock(File::LOCK_EX | File::LOCK_NB) && lock.flock(File::LOCK_SH)
      end

      # A request that found another model resident, told to whoever narrates the wait.
      Waiting = Data.define(:endpoint, :model, :resident) do
        def initialize(endpoint:, model:, resident:)
          super(endpoint: -endpoint.to_s, model: -model.to_s, resident: -resident.to_s)
        end
      end

      # How a wait for the endpoint ended: `held` once the other model was
      # released, or `proceeded` without the lock once the deadline passed.
      Waited = Data.define(:endpoint, :model, :resident, :outcome, :waited) do
        include Telemetry::Journalable

        def initialize(endpoint:, model:, resident:, outcome:, waited:)
          super(endpoint: -endpoint.to_s, model: -model.to_s, resident: -resident.to_s, outcome: -outcome.to_s,
                waited: Float(waited))
        end

        # @return [String]
        def journal_type = "residency_waited"
      end

      # The residency of an endpoint off this machine, whose loaded models are not ours to hold.
      class Null
        # @return the block's value
        def holding(**) = yield
      end
    end
  end
end
