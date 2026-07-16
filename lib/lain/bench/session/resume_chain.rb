# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Follows a header's `resumed_from` (T14) to the prior file's own
      # {Loader}, and shares ONE Store across the whole chain -- a later
      # file's turns and `message` records must land in the SAME store an
      # earlier file's did, since a render `parent` or a causal_parent can
      # name a digest across the file boundary. Absent `resumed_from`, this
      # is a fresh Store and no prior Loader at all -- the ordinary,
      # unchained case, {#present?} false.
      #
      # The resolver duck (`resolve.call(basename) -> entries`) is the seam
      # that keeps filesystem knowledge out of {Loader}: this class never
      # reads a path itself, only what {Loader} was handed (the escalation
      # trigger this card was built around).
      #
      # Resuming from a never-closed (open) predecessor is allowed: B's
      # recorded `resumed_from` head retroactively re-anchors A's otherwise
      # unverified tail, since any A-side truncation changes A's rebuilt head
      # and then disagrees with what B recorded at resume time.
      class ResumeChain
        # Wraps the caller's resolve duck with the basenames already on the
        # walk, so a cyclic `resumed_from` chain (A->A, A->B->A) refuses as
        # {Corrupt} instead of recursing into a SystemStackError -- an
        # Exception, not a StandardError, so no caller could have rescued the
        # crash as the refusal this format owes. The same seam turns a
        # resolver answering nil into a refusal NAMING the missing file,
        # rather than a NoMethodError three frames later.
        class GuardedResolver
          def initialize(resolve:, visited: [].freeze)
            @resolve = resolve
            @visited = visited
          end

          # @return [Enumerable] the resolved entries
          # @raise [Corrupt] on a basename already walked, or one the
          #   resolver answers nil for
          def call(basename)
            revisit!(basename)
            entries = @resolve.call(basename)
            return entries unless entries.nil?

            raise Corrupt, "the resolver answered nil for #{basename.inspect}; " \
                           "resumed_from names a file that cannot be read"
          end

          # The guard the prior file's own Loader walks with: `basename` now
          # counts as visited.
          def visiting(basename)
            self.class.new(resolve: @resolve, visited: (@visited + [basename]).freeze)
          end

          private

          def revisit!(basename)
            return unless @visited.include?(basename)

            raise Corrupt, "resumed_from revisits #{basename.inspect} " \
                           "(walk: #{[*@visited, basename].join(" -> ")}); a resume chain must not cycle"
          end
        end

        # @param resumed_from [Hash, nil] the header's own `resumed_from`
        #   field: `{"file" => <basename>, "head" => <recorded head digest>}`
        # @param context_factory [#call] threaded to the prior file's own
        #   Loader, so a whole chain rebuilds under one Context pipeline
        # @param resolve [#call] `basename -> entries`, consulted only when
        #   `resumed_from` is present
        # @param loader_factory [#new] builds the prior file's Loader;
        #   defaults to {Loader} itself, injectable only so this file need
        #   not load after it
        def initialize(resumed_from:, context_factory:, resolve:, loader_factory: Loader)
          @resumed_from = resumed_from
          @context_factory = context_factory
          @resolve = resolve
          @loader_factory = loader_factory
        end

        def present?
          !@resumed_from.nil?
        end

        # @return [Store] the ONE store this file (and every prior one in its
        #   chain) rebuilds into
        def store
          @store ||= present? ? prior_loader.store : Store.new
        end

        # The prior file's own rebuilt Timeline, verified against the head
        # THIS header recorded at resume time. The prior file's own anchor
        # already verified its own prefix (inside `prior_loader.timeline`);
        # this checks the SEAM between the two files.
        #
        # @return [Timeline]
        # @raise [Corrupt] when the recorded resumed_from head disagrees with
        #   what the prior file actually rebuilds to
        def prior_timeline
          expected = @resumed_from.fetch("head")
          rebuilt = prior_loader.timeline
          return rebuilt if rebuilt.head_digest == expected

          raise Corrupt, "resumed_from names head #{expected.inspect} for #{@resumed_from.fetch("file").inspect} " \
                         "but it actually rebuilds to #{rebuilt.head_digest.inspect}; the resume chain is broken"
        end

        # @return [Array<Event>] the prior file's own already-verified
        #   messages, or none when this file did not resume one
        def prior_messages
          present? ? prior_loader.messages : []
        end

        private

        # Memoized: {#store}, {#prior_timeline}, and {#prior_messages} all
        # reach the same prior file, and re-resolving it twice would ask the
        # injected `resolve` duck for the same file twice. The prior Loader
        # walks with `guard.visiting(basename)` -- the cycle detection lives
        # in the resolve seam itself, so it threads through the recursion
        # without widening {Loader}'s constructor with walk-state.
        def prior_loader
          @prior_loader ||= begin
            basename = @resumed_from.fetch("file")
            @loader_factory.new(guard.call(basename),
                                context_factory: @context_factory, resolve: guard.visiting(basename))
          end
        end

        # An already-guarded resolver (mid-walk, answering #visiting) rides
        # as-is; a caller's raw duck gets wrapped fresh. Duck-checked, not
        # is_a?-checked: depend on the message, not the type.
        def guard
          @guard ||= @resolve.respond_to?(:visiting) ? @resolve : GuardedResolver.new(resolve: @resolve)
        end
      end
    end
  end
end
