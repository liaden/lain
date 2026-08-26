# frozen_string_literal: true

module Lain
  module Isolation
    # The baseline backend: no isolation at all. Every worker leases the shared
    # process environment, and releasing is a no-op because nothing was
    # provisioned to reclaim.
    #
    # {WorkerEnv.default} is recomputed per `acquire`, never a frozen constant,
    # so a lease taken after a `Dir.chdir` still names the current directory.
    class Null
      # @param _worker_id [Object] ignored -- every worker shares one env
      # @return [Lease] a lease over the shared process env; release is a no-op
      def acquire(_worker_id = nil) = Lease.new(worker_env: WorkerEnv.default)
    end
  end
end
