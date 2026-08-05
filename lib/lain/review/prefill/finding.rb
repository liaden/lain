# frozen_string_literal: true

module Lain
  module Review
    class Prefill
      # One reviewable finding, exactly as the sidecar carries it, plus the
      # extmark the editor answered with once somebody placed it.
      #
      # `mark` is absent off the sidecar and is not part of the address: only the
      # editor knows where a line is now, and a finding must keep its id across
      # being placed, or a promotion made before the render would be lost by it.
      # Every other field is judged by the object that owns its domain --
      # {Anchor}, for a path, a side and a line -- so the sidecar cannot admit a
      # position the rest of this surface would refuse.
      Finding = Data.define(:path, :side, :line, :rank, :text, :mark) do
        def initialize(path:, line:, rank:, text:, side: Prefill::Sidecar::DEFAULT_SIDE, mark: nil)
          # Side membership is decided by {Anchor} and the spelling normalized
          # back to the journal's String form ({Review::SIDES}); `Symbol#to_s`
          # answers a MUTABLE String, so the intern is not decoration.
          super(path: -Anchor.nonblank_string!(path, field: "path"),
                side: -Anchor.side!(side).to_s, line: Anchor.line!(line),
                rank: Prefill.rank!(rank), text: Prefill.words!(text), mark: Prefill.mark!(mark))
        end

        # @return [String] the annotation kind this rank promotes as
        def kind = Prefill::KINDS.fetch(rank)

        # @return [String] the content address, scheme-prefixed
        def id = Keying.digest(Prefill::DIGEST_SCHEME, [path, side, line, rank, text])

        # @param mark [Integer] the extmark id the editor answered with
        # @return [Finding] the same finding, placed
        # @raise [Unplaced]
        def at(mark) = with(mark: Prefill.extmark!(mark))

        def placed? = !mark.nil?

        def to_s = "#{path}:#{line} (#{rank})"
      end

      # A finding the human made his own, and the finding it came from.
      #
      # `text` is his words; `origin` is the critique's, unedited, so what was
      # suggested survives what was submitted. It answers no `mark`: a promotion
      # is no longer a suggestion, so it takes the human's own anchor through
      # {Session#annotate} rather than inheriting the one it rendered at.
      #
      # The position and the rank are the finding's and are DELEGATED rather than
      # copied: two records of one position are two records free to disagree, and
      # the whole reason this object exists is to keep the critique's claim and
      # the human's words distinguishable after the edit.
      Promoted = Data.define(:origin, :text) do
        def path = origin.path
        def side = origin.side
        def line = origin.line
        def rank = origin.rank

        # @return [String] the annotation kind, from the finding's rank
        def kind = origin.kind
      end
    end
  end
end
