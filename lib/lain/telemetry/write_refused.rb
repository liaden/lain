# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The reason is the pattern that matched or the judgment that declined,
      # never the matched bytes. `tool_use_id` is declared without a rule for
      # the reason {MemoryRoot}'s `root` is: `settle!` must hand it back.
      class WriteRefused < Declarative::Carrier
        attribute :tool_use_id
        attribute :pattern
        validates :pattern, presence: { message: "must name what matched or what declined, got nil" }
      end
    end

    # A `memory_write` withheld by {Middleware::RefuseSecretWrites} before it
    # ever reached the recorder. `pattern` NAMES the reason -- e.g. "aws access
    # key id" -- and MUST NEVER be the matched bytes themselves: a refusal
    # record that quoted the secret would write it to the very Journal the
    # refusal exists to protect.
    #
    # The field carries TWO kinds of reason and a reader must not conflate
    # them. A named credential pattern means "this looks like a credential"; a
    # *decline* means an oracle judged the write not worth making, with no
    # pattern matching at all. Declines live in a reserved namespace -- test for
    # one with {Middleware::RefuseSecretWrites.decline?} rather than by
    # membership in `PATTERNS`, which drifts as shapes are added. Counting every
    # WriteRefused as a security finding over-counts by every decline.
    WriteRefused = Data.define(:tool_use_id, :pattern) do
      include Journalable

      # `tool_use_id` is the correlation key onto the call that was refused, and
      # it carries no validator -- so, like {MemoryRoot}'s `root`, its keyword is
      # what keeps a refusal from journaling as uncorrelatable.
      def initialize(tool_use_id:, pattern:) = super(**Carriers::WriteRefused.settle!(tool_use_id:, pattern:))
    end
  end
end
