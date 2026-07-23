# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # The file-order chain fold, {Loader}'s collaborator: re-commit every
      # turn record over the accumulated chain and follow every `rewound`
      # record's checkout (T15), in the ONE order that makes them verifiable
      # -- file order. An of_type(turn)-only fold discards the ordering of
      # turns against rewound records, and a rewound session's post-rewind
      # turns verify only relative to the checkout that precedes them.
      #
      # Verification and membership are ONE step by design: a digest joins
      # the member set exactly when its record re-commits to its content
      # address, so {#member?} can never answer true for bytes the fold did
      # not prove. The turns above a rewind stay in the Store and in that
      # set: the pre-rewind subtree remains reachable and membership holds,
      # which is what keeps a child forked above the rewind loadable
      # ({ResumeChain}).
      class ChainFold
        TYPES = [TURN_TYPE, SessionRecord::REWOUND_TYPE].freeze

        # @param records [Array<Hash>] the file's parsed records, in file
        #   order; types outside {TYPES} are other folds' and skipped
        # @param base [Timeline] the fold's starting chain -- empty, or a
        #   resume chain's verified prior head
        def initialize(records:, base:)
          @records = records.select { |record| TYPES.include?(record["type"].to_s) }
          @base = base
        end

        # Memoized like {Loader#timeline}: the rebuild is pure, and
        # {#member?} needs the fold to have run.
        def timeline
          @timeline ||= fold
        end

        # True for any digest VERIFIED while folding: the base's own
        # ancestors plus every turn record folded here, at its fold position.
        def member?(digest)
          timeline
          @members.include?(digest)
        end

        private

        def fold
          @members = Set.new(@base.ancestor_digests)
          @records.each_with_index.inject(@base) { |acc, (record, i)| folded(acc, record, i) }
        end

        def folded(chain, record, index)
          return rewound_checkout(chain, record, index) if record["type"].to_s == SessionRecord::REWOUND_TYPE

          verified_turn(chain.commit(role: record.fetch("role"), content: record.fetch("content"),
                                     meta: record.fetch("meta", {})),
                        record, index)
        end

        def verified_turn(chain, record, index)
          recorded = record.fetch("digest")
          unless chain.head_digest == recorded
            raise Corrupt, "turn record #{index} (#{record.fetch("role")}) recorded as #{recorded} " \
                           "re-commits to #{chain.head_digest}; its content no longer matches its content address"
          end

          @members.add(chain.head_digest)
          chain
        end

        # T15: a rewound record moves the fold position without weakening
        # verification -- `from` must BE the fold's current head, and `to`
        # may name only a digest this fold already verified (or nil, the
        # empty session), so the checkout never vouches for unproven bytes.
        def rewound_checkout(chain, record, index)
          from = record.fetch("from")
          unless chain.head_digest == from
            raise Corrupt, "rewound record #{index} claims to rewind from #{from.inspect} but the chain " \
                           "stands at #{chain.head_digest.inspect}; the file's fold order has been disturbed"
          end

          chain.checkout(verified_target(record, index))
        end

        # Deliberate asymmetry with {SessionRecord::Scribe#rewound}, recorded
        # by the T15 panel: this READ side accepts `to` as ANY digest the
        # fold ever verified -- including one ABOVE the current position (a
        # redo onto an abandoned branch) -- while the Scribe refuses to WRITE
        # that move, its skip-set having pruned the target. Verification
        # stays sound either way (the target was proven); the Scribe owns
        # write-strictness, this fold owns read-tolerance.
        def verified_target(record, index)
          to = record.fetch("to")
          return to if to.nil? || @members.include?(to)

          raise Corrupt, "rewound record #{index} names target #{to.inspect}, which this fold never " \
                         "verified; a rewind can only check out a turn the chain already proved"
        end
      end
    end
  end
end
