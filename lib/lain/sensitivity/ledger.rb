# frozen_string_literal: true

module Lain
  class Sensitivity
    # Which sensitive regions this RUN has released, and the one question that
    # follows: given the regions this file holds NOW, which has nobody agreed to
    # send yet? The (path, digest) keying argument, the absolute-path rule and
    # the reconcile-on-read containment are all in docs/devs/architecture.md's "The secret
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
    # == Fiber- and thread-safe
    #
    # {Tools::ReadFile#parallel_safe?} makes sibling reads concurrent FIBERS, and
    # parallel child stacks share this ledger, so every reader and writer runs
    # under one Monitor: `held(key) | digests` and {#reconcile}'s delete-then-set
    # are read-modify-writes.
    #
    # == Run-scoped, mutable, and owned by the Switchboard
    #
    # Deliberately not a value object and not frozen -- {Session}'s posture, for
    # {Session}'s reason: these are the run's accumulating decisions. It is not
    # ON the Session, though. It sits beside the run's one {Approval::Parked::Queue} and
    # one {Sensitivity::Policy}, where "ONE, so the two cannot disagree" is
    # already the rule, and it dies with the process.
    #
    # There is no persistence path and no Null. Remembering "yes, send
    # `.env.local`" across runs is precisely the answer
    # a remembered-answer store declines to keep, and a Null
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
        @human = {}
        @declined = {}
        @lapsed = {}
        @files = Set.new
        @monitor = Monitor.new
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
        locked do
          reconcile(key, list.map(&:digest)) if complete

          list.reject { |region| held(key).include?(region.digest) }.freeze
        end
      end

      # Adds, never replaces, and never reconciles: what the human agreed to send
      # is not a statement about what else the file holds.
      #
      # Who settled it is kept because only a human's release may lift an egress
      # refusal; an automatic one still serves the read. The default is the one
      # that lifts nothing.
      #
      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param regions [Enumerable<#digest>] the regions they released
      # @param authority [Symbol] one of {Approval::Parked::Queue::AUTHORITIES}
      # @return [self]
      # @raise [ArgumentError] on a relative path or an unknown authority
      def release(path, regions, authority: :automatic)
        raise ArgumentError, "unknown authority #{authority.inspect}" \
          unless Approval::Parked::Queue::AUTHORITIES.include?(authority)

        digests = regions.to_a.map(&:digest)
        key = key!(path)
        locked do
          add(@released, key, digests)
          add(@human, key, digests) if authority == :human
        end
        self
      end

      # @return [Boolean]
      def released?(path, digest) = locked { held(key!(path)).include?(digest) }

      # A whole-file release, kept apart from the regions so it lifts no mask and no egress refusal, and kept per
      # requester, since a person released the files to the agent that asked. Only a person's counts, and a list
      # holding a file with no digest is not remembered at all, since what that file held was never seen.
      #
      # @param files [Array<Array(String, String, nil)>] each file, ABSOLUTE, with the digest of what it held
      # @param authority [Symbol] one of {Approval::Parked::Queue::AUTHORITIES}
      # @param requester [String] who the files were released to, as the parked call named it
      # @return [self]
      # @raise [ArgumentError] on a relative path or an unknown authority
      def release_files(files, authority:, requester:)
        raise ArgumentError, "unknown authority #{authority.inspect}" \
          unless Approval::Parked::Queue::AUTHORITIES.include?(authority)

        held = keyed(files, requester)
        locked { @files.merge(held) } if authority == :human && held.none? { |*, digest| digest.nil? }
        self
      end

      # The caller passes the call's whole disclosure, so an empty list, which is a call that read nothing
      # whole, is never released.
      #
      # @param files [Array<Array(String, String, nil)>] each file the call reads, ABSOLUTE, with its digest
      # @param requester [String] who is asking
      # @return [Boolean] whether a person released every one of these files holding these exact bytes to them
      # @raise [ArgumentError] on a relative path
      def released_files?(files, requester:)
        held = keyed(files, requester)
        held.any? && locked { held.all? { @files.include?(_1) } }
      end

      # Sorted for {Session#reads}' reason: a consumer must not vary with the
      # order releases arrived.
      #
      # @return [Array<String>] frozen
      def released(path) = locked { held(key!(path)).sort.freeze }

      # A human's releases only. The block, when given, picks the paths that count,
      # because the egress guard sees a value and not the file it came from.
      #
      # @yieldparam path [String] absolute
      # @yieldreturn [Boolean] whether that path's releases count
      # @return [Set<String>] frozen copy
      def released_digests
        locked do
          counted = block_given? ? @human.select { |path, _| yield path } : @human
          counted.each_value.reduce(Set.new, :|).freeze
        end
      end

      # @return [Boolean] whether this run has released anything at all
      def empty? = locked { @released.empty? }

      # A decline is a ruling, not a release: the regions stay outstanding, and
      # the read that was declined is masked again without asking.
      #
      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param regions [Enumerable<#digest>] the regions that were declined
      # @return [self]
      def decline(path, regions)
        remember(@declined, path, regions)
      end

      # A decline nobody answered; a human may still release it.
      #
      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param regions [Enumerable<#digest>] the regions whose window lapsed
      # @return [self]
      def lapse(path, regions)
        remember(@lapsed, path, regions)
      end

      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param region [#digest]
      # @return [Boolean]
      def declined?(path, region) = locked { held(key!(path), @declined).include?(region.digest) }

      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @param region [#digest]
      # @return [Boolean]
      def lapsed?(path, region) = locked { held(key!(path), @lapsed).include?(region.digest) }

      # @param path [String, Pathname] the file, ABSOLUTE; see {#key!}
      # @return [Integer] how many distinct regions had a decline or lapse
      def forget(path)
        key = key!(path)
        locked do
          cleared = (held(key, @declined) | held(key, @lapsed)).size
          @declined.delete(key)
          @lapsed.delete(key)
          cleared
        end
      end

      private

      def locked(&block) = @monitor.synchronize(&block)

      def remember(table, path, regions)
        digests = regions.to_a.map(&:digest)
        key = key!(path)
        locked { add(table, key, digests) }
        self
      end

      def held(key, table = @released) = table.fetch(key) { Set.new }

      # The key is the path as written, never where it lands: a symlink swapped in for a released file replays
      # when its target holds the same bytes, since the digest is of the bytes opened through the link.
      def keyed(files, requester) = files.to_a.map { |path, digest| [-requester.to_s, key!(path), digest].freeze }

      def add(table, key, digests)
        table[key] = held(key, table) | digests unless digests.empty?
      end

      # Deleted rather than left empty, so a path whose every release was
      # reconciled away is indistinguishable from one never read.
      def reconcile(key, digests)
        [@released, @human].each do |table|
          kept = held(key, table) & digests
          table.delete(key)
          table[key] = kept unless kept.empty?
        end
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
