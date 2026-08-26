# frozen_string_literal: true

module Lain
  class Sensitivity
    # Which sensitive regions this RUN has released, and the one question that
    # follows: given the regions this file holds NOW, which has nobody agreed to
    # send yet? The (path, digest) keying argument, the absolute-path rule and
    # the reconcile-on-read containment are all in ARCHITECTURE.md's "The secret
    # boundary"; what stays here is what binds a caller.
    #
    # NOT {Lain::Ledger}, which is the COST ledger, and not
    # {Workspace::Restore::Ledger}, which records what a restore wrote. Three
    # ledgers now, meeting only in the English word -- {Arm::LedgerState}'s note
    # is the precedent for saying so.
    #
    # Nothing here opens, stats or normalizes anything, for {Sensitivity}'s own
    # reason: this must be free to call from any arm, in any order. That is why
    # a relative path RAISES rather than being resolved.
    #
    # == Fiber-safe, not thread-safe
    #
    # {Tools::ReadFile#parallel_safe?} makes sibling reads concurrent FIBERS,
    # and every method here is pure Ruby with no IO and no yield point between a
    # read and its mutate. It is deliberately unguarded against threads --
    # `held(key) | digests` and {#reconcile}'s delete-then-set are both
    # read-modify-writes, and nothing in this harness runs tools on threads.
    #
    # == Run-scoped, mutable, and owned by the Switchboard
    #
    # Deliberately not a value object and not frozen -- {Session}'s posture, for
    # {Session}'s reason: these are the run's accumulating decisions. It is not
    # ON the Session, though. It sits beside the run's one {Approval::Queue} and
    # one {Sensitivity::Policy}, where "ONE, so the two cannot disagree" is
    # already the rule, and it dies with the process.
    #
    # There is no persistence path and no Null. Remembering "yes, send
    # `.env.local`" across runs is precisely the answer
    # {Approval::Risk::Classification#rememberable?} declines to keep, and a Null
    # would answer "nothing outstanding" forever -- a release control that
    # silently releases everything, wearing this codebase's own Null Object idiom
    # as camouflage.
    #
    # Three rules bind every caller, and each is a raise rather than a note:
    #
    # 1. `ledger:` is a REQUIRED keyword everywhere it is injected -- no default.
    #    A defaulted ledger lets a forgotten injection become a SECOND ledger
    #    whose releases nobody ever sees.
    # 2. A path is ABSOLUTE, resolved by the caller against the reading worker's
    #    cwd.
    # 3. `regions` is EVERY region in the file, or `complete: false` says it is
    #    not.
    class Ledger
      ROOT = "/"
      ABSOLUTE_CONTRACT = "the ledger is per-RUN and reaches every child, so it has no cwd to resolve against -- " \
                          "resolve the path against the reading worker's cwd first"

      def initialize
        @released = {}
      end

      # The read event. Reconciles this path's releases against the regions the
      # file holds now, then answers what is still unreleased.
      #
      # `regions` must be EVERY region in the file, which is what makes dropping
      # the rest sound. A caller that saw only part of it -- a size-capped
      # detection, an offset read -- says so with `complete: false` and gets the
      # answer without the reconcile, because discarding releases for regions
      # nobody looked at re-prompts secrets that were already approved.
      #
      # `regions` is materialized once up front: walked twice, a single-pass
      # Enumerable answers "nothing outstanding" on the second pass and releases
      # the whole file in silence. CLAUDE.md tells implementers to hand out
      # Enumerators, so this is a shape a caller is encouraged to produce.
      #
      # @param path [String, Pathname] an ABSOLUTE path; see {#key!}
      # @param regions [Enumerable<#digest>] every region detected in it
      # @param complete [Boolean] whether `regions` covers the whole file
      # @return [Array<#digest>] frozen, in the order given
      # @raise [ArgumentError] on a relative path, or a non-boolean `complete`
      def outstanding(path, regions, complete: true)
        # Strict-boolean, and BEFORE the reconcile below, for {Session::ReadSet#record}'s
        # reason: read for truthiness and `complete: "false"` reconciles anyway.
        raise ArgumentError, "complete must be true or false, got #{complete.inspect}" \
          unless [true, false].include?(complete)

        list = regions.to_a
        key = key!(path)
        reconcile(key, list.map(&:digest)) if complete

        list.reject { |region| held(key).include?(region.digest) }.freeze
      end

      # Adds, never replaces, and never reconciles: what the human agreed to send
      # is not a statement about what else the file holds.
      #
      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param regions [Enumerable<#digest>] the regions they released
      # @return [self]
      # @raise [ArgumentError] on a relative path
      def release(path, regions)
        digests = regions.to_a.map(&:digest)
        key = key!(path)
        @released[key] = held(key) | digests unless digests.empty?

        self
      end

      # @return [Boolean]
      def released?(path, digest) = held(key!(path)).include?(digest)

      # Sorted for {Session#reads}' reason: a consumer must not vary with the
      # order releases arrived.
      #
      # @return [Array<String>] frozen
      def released(path) = held(key!(path)).sort.freeze

      # @return [Boolean] whether this run has released anything at all
      def empty? = @released.empty?

      private

      def held(key) = @released.fetch(key) { Set.new }

      # Deleted rather than left empty, so a path whose every release was
      # reconciled away is indistinguishable from one never read.
      def reconcile(key, digests)
        kept = held(key) & digests
        @released.delete(key)
        @released[key] = kept unless kept.empty?
      end

      # {Sensitivity#text!}'s line, and the same two sides of it: a wrong TYPE is
      # the caller's bug and is loud, and the resulting key is a frozen copy
      # because the caller keeps theirs. Duck-typed on `#to_path` rather than
      # tested against `Pathname`, so an open `File` works, and the message says
      # so rather than naming a class the check does not make.
      #
      # The absolute test is {ABSOLUTE_CONTRACT}, and it subsumes {Session#named!}'s
      # blank refusal: `""` is a String and would otherwise sail straight into
      # the shared bucket the type check above exists to prevent.
      def key!(path)
        text = path.is_a?(String) ? path : (path.to_path if path.respond_to?(:to_path))
        raise ArgumentError, "a path must be a String or answer #to_path, got #{path.inspect}" \
          unless text.is_a?(String)
        raise ArgumentError, "a path must be absolute, got #{text.inspect}: #{ABSOLUTE_CONTRACT}" \
          unless text.start_with?(ROOT)

        text.dup.freeze
      end
    end
  end
end
