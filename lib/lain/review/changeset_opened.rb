# frozen_string_literal: true

module Lain
  module Review
    # The head of a review: which source produced the changeset, what it spans,
    # and the address every later record joins back to.
    #
    # `source` is validated for presence and NOT against a registry of source
    # names. The registry belongs to {Review::Source}, and one of its entries is
    # deletable by design -- a second copy of the set here would have to be
    # edited to remove a capability, which is the drift a shared vocabulary
    # exists to prevent.
    #
    # `base_ref` is the resolved merge base rather than the branch the human
    # named: the two differ the moment the base advances, and every old-side
    # anchor is computed against the merge base.
    #
    # `target` is what the human NAMED -- a surveyed tree, a branch, a pull
    # request -- and the one member a later chat can compare with what it is
    # asked to open: the digest moves whenever a file does, and a survey of
    # `big/` whose files changed is still the survey of `big/`. Optional, and
    # absent from the line when nil, so a record written before rounds named
    # their target reads back as naming none rather than refusing.
    ChangesetOpened = Data.define(:source, :base_ref, :head_ref, :digest, :target) do
      include Telemetry::Journalable
      include Declarative

      declare do
        attribute :source
        attribute :base_ref
        attribute :head_ref
        attribute :digest
        attribute :target
        validates :source, presence: { message: Wire.refusal("must name what produced the changeset") }
        validates :base_ref, presence: { message: Wire.refusal("must name the resolved merge base") }
        validates :head_ref, presence: { message: Wire.refusal("must name the head under review") }
        validates :digest, presence: { message: Wire.refusal("must address the changeset") }
        validates :target, presence: { message: Wire.refusal("must name what the round was opened on") },
                           allow_nil: true
      end

      def initialize(source:, base_ref:, head_ref:, digest:, target: nil)
        values = { source: Wire.token(source), base_ref: Wire.token(base_ref),
                   head_ref: Wire.token(head_ref), digest: Wire.token(digest), target: Wire.token(target) }
        self.class.check!(**values)

        super(**values)
      end

      def to_journal = target.nil? ? super.except("target") : super
    end

    class ChangesetOpened
      # Reopened rather than declared inside the `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing MODULE, not the Data
      # class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).
      #
      # The discriminator {Telemetry::Journalable} derives from this class's own
      # name, pinned so a rename breaks loudly at the constant instead of quietly
      # re-labelling records nobody can join anymore.
      JOURNAL_TYPE = "changeset_opened"
    end
  end
end
