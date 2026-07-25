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

          verified_turn(recommitted(chain, record, index), record, index)
        end

        # The causal edge is part of the content address ({Event#payload}), so
        # a fold that dropped it would re-derive a different digest and raise
        # {Corrupt} over bytes that are perfectly sound -- the reason the
        # writer and this reader had to move together. DEFAULTED, never
        # fetched: every journal written before {SessionRecord.turn} carried
        # the field has no key, and no key IS the empty set, the same tolerance
        # `meta` already has.
        #
        # {Event#normalize_causal} re-sorts and dedups on the way in, so a
        # record whose array was reordered or repeated folds to the SAME
        # verified turn -- two distinct journal byte strings, one record. That
        # is correct, since element order is deliberately outside the content
        # address; it does mean this fold verifies the SET, never those bytes.
        #
        # The parents must already be in the store this chain builds on --
        # {Store#put} enforces the causal edge like any other, which is what
        # keeps the fold from vouching for an event nothing recorded. Its
        # refusal is TRANSLATED here rather than left to escape: {Corrupt} is
        # the one error this format's readers rescue ({CLI::Resume} builds its
        # Refusal out of it), so a bare {Store::MissingObject} would reach the
        # exe as a backtrace instead of a named refusal.
        def recommitted(chain, record, index)
          chain.commit(role: record.fetch("role"), content: record.fetch("content"),
                       meta: record.fetch("meta", {}), causal_parents: cited_parents(record, index))
        rescue Store::MissingObject => e
          raise Corrupt, "turn record #{index} (#{record.fetch("role")}) cites a causal parent this fold " \
                         "never landed: #{e.message}"
        end

        # A journal is bytes, and bytes can be wrong. `content` and `meta`
        # announce their corruption through the digest they then fail to
        # re-derive, and a bad `role` raises a named {Event::InvalidRole} --
        # but this field reaches neither check, because
        # {Event#normalize_causal} maps and sorts it before any digest exists,
        # so a null arrives as a NoMethodError three frames down. Shape-checked
        # here so the whole record type answers corruption in ONE currency.
        def cited_parents(record, index)
          cited = record.fetch("causal_parents", [])
          return cited if cited.is_a?(Array) && cited.all?(String)

          raise Corrupt, "turn record #{index} (#{record.fetch("role")}) records causal_parents as " \
                         "#{cited.inspect}; the field is a set of digest strings, and only an array of them folds"
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
