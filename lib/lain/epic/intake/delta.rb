# frozen_string_literal: true

module Lain
  module Epic
    module Intake
      # What each of {Delta}'s members must be, as message-and-predicate pairs in
      # the tier's own idiom. EVERY member, not only the two the semantic
      # invariants below name: `Data#with` reaches all six, and a nil
      # `written_digest` made #byte_identical? answer TRUE (nil == nil) while a
      # nil `account` answered NoMethodError rather than a refusal.
      DELTA_MEMBERS = {
        written_digest: ["a digest String", ->(value) { value.is_a?(String) }],
        disk_digest: ["a digest String", ->(value) { value.is_a?(String) }],
        account: ["an Intake::Account", ->(value) { value.is_a?(Account) }],
        lossy: ["true or false", ->(value) { [true, false].include?(value) }],
        error: ["a String or nil", ->(value) { value.nil? || value.is_a?(String) }],
        error_kind: ["a String or nil", ->(value) { value.nil? || value.is_a?(String) }]
      }.freeze

      # The structural edit, one sorted id list per kind.
      Account = Data.define(*KINDS) do
        def self.between(before, after)
          new(added: (after.ids - before.ids).freeze, removed: (before.ids - after.ids).freeze,
              **edits(before, after))
        end

        # The kinds that compare two sides of the SAME issue. Graph#ids is
        # sorted and `&` keeps its receiver's order, so every list here is a
        # value an author can diff across settles rather than a fresh shuffle.
        def self.edits(before, after)
          common = before.ids & after.ids
          CHANGED.transform_values do |changed|
            common.select { |id| changed.call(before.fetch(id), after.fetch(id)) }.freeze
          end
        end
        private_class_method :edits

        # No comparison was made, which is not the same claim as "the two sides
        # agreed" -- {Delta#malformed?} is what distinguishes them.
        def self.empty = new(**KINDS.to_h { |kind| [kind, NO_IDS] })

        # The kinds that actually changed, as a Hash -- which IS Enumerable. The
        # Account itself is a seven-field record rather than a collection, and
        # `include Enumerable` here was a lie that cost real defects: its #to_h
        # shadowed Data's and dropped a block without a word, an #each written
        # over that #to_h recursed until the stack died, and `include?(:added)`
        # answered false on an account whose `added` was not empty, because the
        # elements were pairs.
        def changes = to_h.reject { |_kind, ids| ids.empty? }

        def empty? = changes.empty?
      end

      # One settle's report: the byte digests record which bytes were compared
      # and are what a journal entry carries; the account is what changed in
      # meaning.
      #
      # `error` holds the parse failure's MESSAGE and `error_kind` its class
      # name, rather than the exception: this is a frozen value a Ractor may
      # carry, and an Exception drags a mutable backtrace behind it. The kind
      # rides beside the message so a consumer can tell a grammar refusal from a
      # graph refusal without matching message text.
      Delta = Data.define(:written_digest, :disk_digest, :account, :lossy, :error, :error_kind) do
        # The only constructor for the malformed branch: it keeps error and kind
        # in step.
        def self.malformed(error, written_digest:, disk_digest:, lossy:)
          new(written_digest:, disk_digest:, account: Account.empty, lossy:,
              error: error.message.freeze, error_kind: error.class.name.freeze)
        end

        include Declarative

        # Total by construction, the way Graph and Issue are: the member shapes
        # and the two invariants this class's doc claims, in one declaration.
        # Data#with re-enters the constructor, so a delta cannot be edited into a
        # state .diff would never build. {DELTA_MEMBERS} is read here rather than
        # restated, so the table stays the one place a member's shape is written.
        #
        # `check!` and not `settle!`: `account` is an {Account}, which settling
        # refuses -- it may not copy a value it cannot rebuild.
        #
        # Both semantic rules re-test the shape they depend on, which the ordered
        # cascade this replaces got for free by raising on the first failure. A
        # declaration reports EVERY broken rule at once, so a rule that would send
        # `#empty?` to a nil account has to say so itself.
        declare raising: MalformedDelta do
          DELTA_MEMBERS.each_key { |name| attribute name }

          DELTA_MEMBERS.each do |name, (shape, holds)|
            validate do
              errors.add(name, "is #{shape} (got #{public_send(name).inspect})") unless holds.call(public_send(name))
            end
          end

          # {Delta}'s own pairing rule: a message with no kind cannot be told
          # from a grammar refusal, and a kind with no message says nothing.
          validate do
            unless error.nil? == error_kind.nil?
              errors.add(:error, "and its kind are named together (got #{error.inspect} and " \
                                 "#{error_kind.inspect})")
            end
          end

          # A failed parse produced no account at all, so carrying one would make
          # "empty account" mean two different things and turn #malformed? from a
          # fact into a convention. Worded as the RULE and not as a denial of
          # what was found: the join reads `"<attribute> <message>" (<value>)`,
          # so "is not carried by a delta that names a parse error" would assert,
          # of a delta plainly carrying one, that it is not.
          validate do
            if error && account.is_a?(Account) && !account.empty?
              errors.add(:account, "must be empty on a delta that names a parse error -- nothing was " \
                                   "compared (got #{account.changes.inspect})")
            end
          end
        end

        def initialize(**members)
          self.class.check!(**members)
          super
        end

        def byte_identical? = written_digest == disk_digest

        def structural? = !account.empty?

        # Advisory, and only ever a suspicion: less than half the bytes lain wrote
        # came back, which a legitimate mass edit trips too. See {Intake.lossy?}
        # for why the measure is bytes on both branches.
        def lossy? = lossy

        # The question a consumer asks first: below it, an empty account means
        # nothing was comparable rather than nothing changed. "Nothing was
        # comparable" is wider than "the parse failed" -- {Epic::Review} builds
        # one for a review rebuilt from the journal, where the disk is on record
        # but the bytes lain wrote are gone. `error_kind` separates the causes,
        # and is the only thing that should: a second predicate over one field is
        # one more thing that can disagree with the first.
        def malformed? = !error.nil?
      end
    end
  end
end
