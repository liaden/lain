# frozen_string_literal: true

module Lain
  module Oracle
    # An answer the typed schema rejected. Loud rather than defaulting: an oracle
    # whose reply does not fit its own schema is a coordination failure, not a
    # value to paper over -- the same premise ask_human's guards rest on.
    class InvalidAnswer < Error; end

    # A content-addressed oracle: the question template, the {Tool::Input} schema
    # its reply is validated against, and which tier answers it. The digest covers
    # all three, so two definitions asking the same question, validating the same
    # way, and routed to the same tier ARE the same oracle -- and a change to any
    # one of the three is a different oracle at a different address.
    #
    # The Definition also owns what a valid answer IS (it owns the schema), so
    # both tiers hand it a raw answer Hash and receive the same validated,
    # Promise-wrapped result -- which is why a caller cannot tell the tiers apart
    # from the answer's shape.
    Definition = Data.define(:template, :schema, :tier) do
      def initialize(template:, schema:, tier:)
        super(template: -template.to_s, schema:, tier: tier.to_sym)
      end

      # The question, with `inputs` injected as slot values and rendered PURELY:
      # a `Time.now` or any impure reference is a loud {Prompt::ImpureSlot}, never
      # a silently nondeterministic prompt -- the same purity a slot fill answers
      # to, since an oracle's question sits above the cache line just as a slot
      # does. An input the template names but the caller did not supply is a loud
      # KeyError rather than a silent blank.
      def render(inputs = {})
        by_name = inputs.transform_keys(&:to_s)
        Prompt::LockedBinding.new(resolve: ->(name) { by_name.fetch(name) })
                             .render_template(template, "oracle_question")
      end

      # Validate a raw answer through the schema and hand back a Promise. Every
      # way an answer can be malformed -- an unexpected extra key ({Tool::Input}
      # rejects it during build), a missing required field, or a value outside the
      # schema -- raises the ONE {InvalidAnswer} family, so a replay or
      # failure-counting rescue cannot silently miss a shape. No default is
      # produced.
      #
      # The returned Promise is ALWAYS pre-resolved before this method returns, so
      # awaiting it never parks a fiber. That is a deliberate response to a real
      # gap in {Lain::Promise} (it has no rejection channel, so a rejected answer
      # could not be carried through an await without deadlocking a parked
      # caller). The Promise is the shared return type both tiers speak, NOT an
      # async seam: N oracle calls overlap only if the CALLER spawns a task per
      # call -- `oracle.ask(...).await` in a loop serializes.
      def answer(attributes)
        typed = build(attributes)
        raise InvalidAnswer, "oracle answer rejected: #{typed.errors.full_messages.join("; ")}" unless typed.valid?

        Promise.new.tap { |promise| promise.resolve(typed) }
      end

      def digest
        Canonical.digest("template" => template, "schema" => schema.to_json_schema, "tier" => tier.to_s)
      end

      private

      # {Tool::Input.build} raises its own {Tool::InvalidInput} on an unexpected
      # key -- folded into the {InvalidAnswer} family so "this answer is invalid"
      # is one exception however it is malformed.
      def build(attributes)
        schema.build(attributes)
      rescue Tool::InvalidInput => e
        raise InvalidAnswer, e.message
      end
    end
  end
end
