# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Lain
  module Bench
    class Altitude
      # The bench's own isolation: every lease is a FRESH COPY of one task's
      # subject project, so an arm works in the project it was asked about and a
      # grader bound to that lease runs THAT project's own suite.
      #
      # Without it an unleased arm works wherever the process happens to stand,
      # which for `lain bench altitude` is lain's own repository -- an arm
      # editing the bench that is measuring it, graded on a suite that is not the
      # subject's. That is the one thing a decomposition bench must never do.
      #
      # A COPY PER LEASE, never the committed fixture itself. An arm edits what
      # it is given, so a shared directory would make every row after the first a
      # measurement of the row before it, and would leave the fixture dirty for
      # the next run.
      #
      # Its own file because a nested class's lines count toward the enclosing
      # class's `Metrics/ClassLength` -- {ArmSweep} splits {ArmSweep::Recordings}
      # and {ArmSweep::Report} out for the same reason.
      class Subject
        # @param project [String] the subject project to copy, already resolved
        #   to an absolute path
        # @param root [String] the directory the copies are made under
        def initialize(project:, root: Dir.tmpdir)
          @project = project
          @root = root
        end

        # @param worker_id [Object] names the copy, so two arms' checkouts are
        #   told apart on disk and in a failure message
        # @return [Isolation::Lease] cwd = the copy; release removes it
        def acquire(worker_id)
          checkout = Dir.mktmpdir("altitude-#{sanitized(worker_id)}-", @root)
          FileUtils.cp_r(File.join(@project, "."), checkout)
          Lain::Isolation::Lease.new(worker_env: WorkerEnv.new(cwd: checkout, env: ENV.to_h),
                                     on_release: ->(**) { FileUtils.remove_entry(checkout, true) },
                                     origin: Lain::Isolation::Lease::Origin.new(path: checkout))
        end

        private

        # An arm's name reaches a directory name, and an arm may be called
        # anything; `mktmpdir` would take a `/` in a prefix as a path.
        def sanitized(worker_id) = worker_id.to_s.gsub(/[^\w.-]/, "-")
      end
    end
  end
end
