# frozen_string_literal: true

module Lain
  class Sensitivity
    module Secrets
      # A {Source} that keeps the last set it built for each lent environment
      # while the child environment, the history's stamps and the credentials
      # are unmoved, so the approval, the announcer, the display and the output
      # scan of 1 call share a build. The stamps are taken before the build, so
      # a file moved during it is seen on the next ask.
      class Remembered
        # Bounded, since a finished subagent's lent environment is never asked again.
        LIMIT = 64

        Entry = Data.define(:environment, :stamps, :set)
        private_constant :Entry

        # @param source [Source]
        def initialize(source)
          @source = source
          @entries = Concurrent::Map.new
        end

        # @param context [#worker_env, nil] as {Source#for}
        # @return [Array<String>] as {Source#for}
        def for(context) = remembered(:for, context) { @source.for(context) }

        # @param context [#worker_env, nil] as {Source#for_reads}
        # @return [Array<String>] as {Source#for_reads}
        def for_reads(context) = remembered(:for_reads, context) { @source.for_reads(context) }

        # @return [Array<String>] as {#for} with no call's worker
        def to_a = self.for(nil)

        # @param released [Set<String>] as {Source#egress}
        # @return [Egress] as {Source#egress}
        def egress(released: Set.new) = @source.egress(released:)

        # @return [Exec::ChildEnv] the source's
        def child_env = @source.child_env

        # @return [#to_a, #refusable, #stamps] the source's
        def history = @source.history

        private

        def remembered(kind, context)
          key = [kind, (context || Session::Null.instance).worker_env.env.to_h].freeze
          environment = @source.child_env.environment
          stamps = @source.history.stamps
          kept = @entries[key]
          return kept.set if kept&.environment == environment && stamps.unchanged_since?(kept.stamps)

          yield.tap { |set| keep(key, Entry.new(environment, stamps, set)) }
        end

        def keep(key, entry)
          @entries.clear if @entries.size >= LIMIT
          @entries[key] = entry
        end
      end
    end
  end
end
