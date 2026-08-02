# frozen_string_literal: true

module Lain
  module Epic
    module Intake
      # What each of {Delta}'s members must be, as message-and-predicate pairs in
      # the tier's own idiom (ID_RULES, DESCRIPTION_RULES). EVERY member, not
      # only the two the semantic invariants below name: `Data#with` reaches all
      # six, and a nil `written_digest` made #byte_identical? answer TRUE
      # (nil == nil) while a nil `account` answered NoMethodError rather than a
      # refusal.
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

        # The kinds that compare two sides of the SAME issue, and so answer only
        # over the ids both documents hold. Graph#ids is sorted, and `&` keeps
        # its receiver's order, so every list here is a value an author can diff
        # across settles rather than a fresh shuffle.
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

        # The kinds that actually changed, as a Hash -- which IS Enumerable, so a
        # consumer maps, each-es and sizes it freely. The Account itself is a
        # seven-field record rather than a collection, and `include Enumerable`
        # here was a lie that cost real defects: its #to_h shadows Data's and so
        # dropped a block without a word, an #each written over that #to_h
        # recursed until the stack died, and `include?(:added)` answered false on
        # an account whose `added` was not empty, because the elements were
        # pairs. Naming the collection is what makes every one of those honest.
        def changes = to_h.reject { |_kind, ids| ids.empty? }

        def empty? = changes.empty?
      end

      # One settle's report. The byte digests are the record of which bytes were
      # compared, and they are what a journal entry carries; the account is what
      # changed in meaning.
      #
      # `error` holds the parse failure's MESSAGE and `error_kind` its class
      # name, rather than the exception: this is a frozen value a Ractor may
      # carry, and an Exception drags a mutable backtrace behind it. The kind
      # rides beside the message so a consumer can tell a grammar refusal from a
      # graph refusal without matching message text.
      Delta = Data.define(:written_digest, :disk_digest, :account, :lossy, :error, :error_kind) do
        # The only constructor for the malformed branch, and what keeps the error
        # and its kind in step.
        def self.malformed(error, written_digest:, disk_digest:, lossy:)
          new(written_digest:, disk_digest:, account: Account.empty, lossy:,
              error: error.message.freeze, error_kind: error.class.name.freeze)
        end

        # Total by construction, the way Graph and Issue are: the member shapes
        # first, then the two invariants this class's doc claims. Data#with
        # re-enters here, so a delta cannot be edited into a state .diff would
        # never build.
        def initialize(**members)
          refuse_shapes!(members)
          refuse_partial_error!(members[:error], members[:error_kind])
          refuse_uncompared_account!(members[:account], members[:error])
          super
        end

        def byte_identical? = written_digest == disk_digest

        def structural? = !account.empty?

        # Advisory, and only ever a suspicion: less than half the bytes lain
        # wrote came back, which a legitimate mass edit trips too. A consumer
        # renders "possibly truncated" and asks. See {Intake.lossy?} for why the
        # measure is bytes on both branches.
        def lossy? = lossy

        # The question a consumer asks first: below it, an empty account means
        # nothing was comparable rather than nothing changed.
        #
        # "Nothing was comparable" is wider than "the parse failed", and the
        # invariant is the one {#refuse_uncompared_account!} states rather than
        # any particular cause: a delta carrying an error holds no account.
        # {Epic::Review} builds one for a review rebuilt from the journal, where
        # the disk is on record but the bytes lain wrote are gone. `error_kind`
        # is what separates the causes, and it is the only thing that should --
        # a second predicate over one field is one more thing that can disagree
        # with the first.
        def malformed? = !error.nil?

        private

        def refuse_shapes!(members)
          broken = DELTA_MEMBERS.find { |name, (_shape, holds)| !holds.call(members[name]) }
          return if broken.nil?

          name, (shape, _holds) = broken
          raise MalformedDelta, "a delta's #{name} is #{shape} (got #{members[name].inspect})"
        end

        def refuse_partial_error!(error, error_kind)
          return if error.nil? == error_kind.nil?

          raise MalformedDelta, "a delta names its parse error and that error's kind together " \
                                "(got #{error.inspect} and #{error_kind.inspect})"
        end

        # A failed parse produced no account at all, so carrying one would make
        # "empty account" mean two different things and turn #malformed? from a
        # fact into a convention.
        def refuse_uncompared_account!(account, error)
          return if error.nil? || account.empty?

          raise MalformedDelta, "a delta carrying a parse error holds no account -- nothing was compared " \
                                "(got #{account.changes.inspect})"
        end
      end
    end
  end
end
