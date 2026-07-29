# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/unpin [digest]` (B1): the retraction half of {Pin}, resolving its
      # argument through the very same {Pin::Target} so the two commands cannot
      # disagree about what a prefix names. It refuses an unresolvable target
      # rather than quietly unpinning nothing -- an operator who mistyped a
      # digest must not read silence as success.
      #
      # Unpinning a turn that was never pinned is NOT a refusal: {Session}'s
      # pin-set is a set, and "make sure this is not pinned" is a legitimate
      # thing to ask of a session whose pins you cannot see. It is not a
      # SUCCESS either -- claiming "unpinned" over a session with no pins is
      # the same silence-read-as-success this command's refusals exist to
      # avoid, one step further in. So the no-op says it was not pinned, and
      # journals nothing: there is no transition, and a retraction record for a
      # pin that never happened would only be noise in the replay log.
      class Unpin
        def initialize = freeze

        def name = "unpin"

        def usage = "/unpin [digest] -- release a pin (default: the last assistant turn)"

        def call(args, env)
          digest = Pin::Target.new(timeline: env.timeline, verb: name).resolve(args.to_s.strip)
          session = env.agent.session
          return "#{digest[0, 19]}... was not pinned -- nothing to release" unless session.pinned?(digest)

          session.record_unpin(digest)
          "unpinned #{digest[0, 19]}... -- compaction may elide this turn again"
        end
      end
    end
  end
end
