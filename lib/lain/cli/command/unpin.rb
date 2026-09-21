# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/unpin [digest]`: the retraction half of {Pin}, resolving its
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
      #
      # Releases the {Pin::Counterpart} too, WHEN it is itself pinned -- the
      # mirror of {Pin}'s own drag, so a pair {Pin} protected together does not
      # half-strand on the way back out. The "was not pinned" refusal still
      # reads on `digest` alone: a companion that happens not to be pinned (an
      # explicit digest named only one half) is not this command's business.
      class Unpin
        def initialize = freeze

        def name = "unpin"

        def usage = "/unpin [digest] -- release a pin (default: the last assistant turn)"

        def call(args, env)
          timeline = env.timeline
          session = env.agent.session
          digest = Pin::Target.new(timeline:, verb: name).resolve(args.to_s.strip)
          return "#{digest[0, 19]}... was not pinned -- nothing to release" unless session.pinned?(digest)

          companion = pinned_companion(timeline:, session:, digest:)
          session.record_unpin(digest)
          session.record_unpin(companion) if companion
          reply(digest, companion)
        end

        private

        def pinned_companion(timeline:, session:, digest:)
          companion = Pin::Counterpart.new(timeline:).of(digest)
          companion if companion && session.pinned?(companion)
        end

        def reply(digest, companion)
          return "unpinned #{digest[0, 19]}... -- compaction may elide this turn again" if companion.nil?

          "unpinned #{digest[0, 19]}... and its tool counterpart #{companion[0, 19]}... -- compaction may elide " \
            "both again"
        end
      end
    end
  end
end
