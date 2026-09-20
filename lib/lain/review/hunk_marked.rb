# frozen_string_literal: true

module Lain
  module Review
    # One hunk's reviewed mark, at the only granularity marks are recorded.
    #
    # `hunk_key` carries its own scheme prefix ({Review::Hunk} owns both the
    # scheme and the version in it), so this record stores the key and does not
    # restate its shape: a prefix pattern here would be a second copy of a scheme
    # designed to be changed.
    HunkMarked = Data.define(:hunk_key, :state) do
      include Telemetry::Journalable
      include Declarative

      declare do
        attribute :hunk_key
        attribute :state
        validates :hunk_key, presence: { message: Wire.refusal("must name the hunk that was marked") }
        validates :state, inclusion: { in: MARK_STATES,
                                       message: Wire.refusal("must be one of #{MARK_STATES.join("/")}") }
      end

      def initialize(hunk_key:, state:)
        values = { hunk_key: Wire.token(hunk_key), state: Wire.token(state) }
        self.class.check!(**values)

        super(**values)
      end
    end

    class HunkMarked
      # See {ChangesetOpened::JOURNAL_TYPE}.
      JOURNAL_TYPE = "hunk_marked"
    end
  end
end
