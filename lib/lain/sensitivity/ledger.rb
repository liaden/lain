# frozen_string_literal: true

module Lain
  class Sensitivity
    # Which sensitive regions this RUN has released, and the one question that
    # follows: given the regions this file holds NOW, which has nobody agreed to
    # send yet?
    #
    # NOT {Lain::Ledger}, which is the COST ledger (tokens -> dollars, joined off
    # the Journal), and not {Workspace::Restore::Ledger}, which records what a
    # restore wrote. Three ledgers now, meeting only in the English word --
    # {Arm::LedgerState}'s note is the precedent for saying so here.
    #
    # {Sensitivity::Regions} addresses a region by its own bytes, so a release
    # survives an edit somewhere else in the file. The masking arm re-runs the
    # detector on every read and diffs the result against this ledger, which is
    # what makes a key added a minute after the file was approved prompt anyway,
    # while the two keys already approved stay quiet.
    #
    # == Keyed by (path, digest), and the path half is the containment
    #
    # A region is the VALUE alone, so two identical values in one file share a
    # digest and one decision covers both -- accepted, because identical bytes
    # are the same secret. Across files it is not the same secret, and content
    # addressing cannot tell them apart on its own: the header of every HS256 JWT
    # is the identical byte string `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`, so
    # keying on the digest alone would let one released token pre-release that
    # segment everywhere. The path is what keeps a release where it was made.
    #
    # The trade is real and was taken deliberately: a lockfile hash approved in
    # one crate of a monorepo is asked about again in the next. That is the
    # direction the gated half of this boundary errs in everywhere else -- a
    # spurious match costs one prompt, and a release that travels costs a secret.
    #
    # == The path must be ABSOLUTE, and that is enforced rather than normalized
    #
    # Nothing here opens, stats or normalizes anything, for {Sensitivity}'s own
    # reason: this must be free to call from any arm, in any order. But "any
    # spelling is merely its own key" is FALSE for a relative one. `config/.env`
    # under a parent's cwd and under a child worktree's cwd are two different
    # files behind one key -- a release that travels between them, which is the
    # one direction this boundary must never fail in. So a relative path raises.
    #
    # Normalizing instead would not fix it. This ledger is per-RUN and reaches
    # every child through the board thunk, so there is no single cwd to normalize
    # against: a cwd injected at construction is the PARENT's, and the child's
    # reads are exactly the colliding case. A per-call cwd would put a second
    # contract on every caller. Raising needs no cwd at all, and the arm that
    # holds the effect and the worker cwd can resolve before it calls -- the
    # raise is how it finds out it forgot.
    #
    # The same guard takes the blank String, which is a String and would
    # otherwise sail into the shared bucket the type check exists to prevent --
    # {Session#named!}'s refusal, for {Session#named!}'s reason.
    #
    # Among ABSOLUTE spellings the original claim does hold, and those splits are
    # all fail-closed: `/repo/./.env` and `/repo/.env` are two keys, as are the
    # same bytes tagged in two encodings. Each costs one extra prompt and none
    # can merge two files.
    #
    # == Reading reconciles, and that is one call on purpose
    #
    # {#outstanding} drops the releases for digests the file no longer holds.
    # Command-query separation would put that in its own method, and the failure
    # mode of the second call being forgotten is that a secret deleted and later
    # restored is sent without anyone being asked -- a silent regression at a
    # call site no spec of THIS class could see. One call is the containment.
    #
    # Reconciling is sound only over a COMPLETE detection, though, so that is a
    # stated precondition with its own keyword rather than an assumption: see
    # `complete:` on {#outstanding}.
    #
    # `complete: false` therefore OPTS OUT of the containment above: under it a
    # deleted region stays released, so delete-then-restore at that path is
    # re-sent unasked. That is unavoidable -- nothing can reconcile what it did
    # not look at -- but it compounds, and the caller who sets a size cap is the
    # one who decides how far. A file read ONLY ever under a cap never reconciles
    # at all, and its releases live as long as the run.
    #
    # == Nothing detects here
    #
    # The regions arrive already detected. Detection is ~0.22ms/KB and linear, so
    # whatever size cap that cost eventually needs belongs to the arm holding the
    # bytes -- and a capped detection is by construction a SUBSET, so it must
    # come back through `complete: false` or every read past the cap forgets its
    # releases and prompts again, forever.
    #
    # == Fiber-safe, not thread-safe
    #
    # {Tools::ReadFile#parallel_safe?} makes sibling reads concurrent FIBERS, and
    # this is safe for them by the same audit its own note makes of `record_read`:
    # every method here is pure Ruby with no IO and no yield point between a read
    # and its mutate. It is NOT thread-safe, and deliberately unguarded --
    # `held(key) | digests` and {#reconcile}'s delete-then-set are both
    # read-modify-writes, and nothing in this harness runs tools on threads.
    #
    # == Run-scoped, mutable, and owned by the Switchboard
    #
    # Deliberately not a value object and deliberately not frozen -- {Session}'s
    # posture, for {Session}'s reason: these are the run's accumulating decisions.
    # It is not ON the Session, though. It sits beside the run's one
    # {Approval::Queue} and one {Sensitivity::Policy}, where "ONE, so the two
    # cannot disagree" is already the rule, and it dies with the process.
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
