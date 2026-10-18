# frozen_string_literal: true

module Lain
  module Telemetry
    # Which image a docker run's programs were resolved against, once per
    # image ID per run: the tag, the ID it named, and whether its listing was
    # read. When it was not, every stage stays unresolved and `reason` says why.
    ExecImage = Data.define(:image, :id, :listed, :reason) do
      include Journalable

      # @param image [String] the tag the operator named
      # @param id [String, nil] the ID the tag named, nil when the inspect gave none
      # @param listed [Boolean] whether programs were resolved from the image's listing
      # @param reason [String, nil] why they were not
      def initialize(image:, id:, listed:, reason:)
        super(image: -image.to_s, id: (-id if id), listed:, reason: (-reason if reason))
      end
    end
  end
end
