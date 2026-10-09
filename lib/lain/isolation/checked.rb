# frozen_string_literal: true

module Lain
  module Isolation
    # A worker's fast checks, then its self-sync, behind the one sync duck both
    # lanes call between a child's answer and its handback. The checks go
    # first so they measure the commits the worker made, before a rebase
    # rewrites them, and while the worker can still be asked to fix its red.
    #
    # What the checks found rides the sync's own record, so the one handback
    # record a reader opens says both.
    class Checked
      FAILED = "checks failed: %<detail>s"

      Result = Data.define(:checks, :sync) do
        # @return [Hash] the sync's record fields, with the checks' merged in
        def to_record = sync.to_record.merge(checks.to_record)

        # @return [String] what the parent is told, empty when nothing is owed
        def note = [sync.note, failed].reject(&:empty?).join("; ")

        private

        def failed = checks.outcome == :failed ? format(FAILED, detail: checks.detail) : ""
      end

      # A project that configured nothing journals exactly what it did before
      # checks existed.
      module Unchecked
        def self.call(_lease, **) = self
        def self.outcome = nil
        def self.to_record = {}
      end

      # @param base [#tip] the working branch a worker's changes are measured from
      # @param layout [TestLayout] says which tests mirror a changed source
      # @param settings [Config::Isolation] names the check, the lint and their retries
      # @return [WorkerChecks, Unchecked]
      def self.configured(base:, layout:, settings:)
        return Unchecked if settings.check.empty? && settings.lint.empty?

        WorkerChecks.new(base:, layout:, check: settings.check, lint: settings.lint,
                         lint_files: settings.lint_files, retries: settings.check_retries)
      end

      # @param checks [#call] {WorkerChecks}, or {Unchecked}
      # @param sync [#call, #unasked, #editorless] {SelfSync}
      def initialize(checks:, sync:)
        @checks = checks
        @sync = sync
      end

      # @param worker_env [WorkerEnv] as leased
      # @return [WorkerEnv] as the sync hands it to the worker
      def editorless(worker_env) = @sync.editorless(worker_env)

      # @param lease [#origin] the live lease whose checkout is checked, then synced
      # @param worker [#askable?, #ask] from {SelfSync.worker}
      # @param worker_id [Object] names the ref the sync anchors under
      # @return [Result]
      def call(lease, worker:, worker_id:)
        checks = @checks.call(lease, worker:, worker_id:)
        Result.new(checks:, sync: @sync.call(lease, worker:, worker_id:))
      end

      # A dispatch that did not return is torn down, not checked: nobody is
      # left to fix a red, and a teardown must not wait on the project's suite.
      #
      # @param lease [#origin] the live lease whose checkout is synced
      # @param worker_id [Object] names the ref the sync anchors under
      # @return [SelfSync::Result] the inner sync's own
      def unasked(lease, worker_id:) = @sync.unasked(lease, worker_id:)
    end
  end
end
