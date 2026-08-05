# frozen_string_literal: true

module Lain
  module Review
    module Projection
      # Annotations and critique findings, projected into nvim's diagnostic
      # layer -- which buys gutter signs, virtual text, `]d`/`[d`, `setqflist`,
      # severity filtering and every picker's diagnostics source for the price
      # of a severity map. `:Telescope diagnostics` becomes a comment browser
      # at no cost, and none of it is code this repo has to own.
      #
      # == Why an entry carries no line
      #
      # A DISPLAY layer, never an anchor, and that is a measurement rather than
      # a preference. On nvim 0.12.4, inserting two lines above a diagnostic:
      #
      #     BEFORE  diag.get lnum=2   anchor extmark row=2   rendered rows=[2]
      #     AFTER+2 diag.get lnum=2   anchor extmark row=4   rendered rows=[4]
      #
      # `vim.diagnostic.get` reports the same lnum forever, while the sign and
      # virtual text the diagnostic layer drew MOVE -- they are extmarks, and
      # nvim slides them like any other. So the screen keeps looking right
      # while the record goes stale, and everything that reads the record
      # (`]d`, `setqflist`, a picker, anything Ruby asks back) answers the old
      # line. A visibly wrong answer would be kinder.
      #
      # Extmarks therefore stay the anchor, and an entry names the MARK, not a
      # line: only the editor knows where a mark is now, so only the editor may
      # say. That is why the duck this takes is `#mark`/`#text`/`#kind` and
      # deliberately not {Review::AnnotationPlaced}, whose `line` is the one
      # field that must not cross.
      #
      # == Deletable
      #
      # This capability is removable by deleting this file, its unit-index line
      # in `lib/lain/review.rb`, `runtime/49_diagnostics.lua` and this spec.
      # Nothing outside those names {SEVERITIES}, {RANKS} or either namespace,
      # and the lua half is discovered by a glob rather than a require. What
      # removal leaves behind: annotations still place and still drift; no
      # gutter signs, no `]d`, no quickfix, no telescope.
      class Diagnostics
        # A kind no vocabulary this projection knows spells.
        class UnknownKind < Error; end

        # The severity map, keyed by {Review::ANNOTATION_KINDS} because that is
        # the vocabulary a record in this repo actually stores. Values are
        # nvim's OWN spellings, taken verbatim from `vim.diagnostic.severity`,
        # so the lua half indexes that table directly and a typo here fails
        # loudly there instead of resolving to a nil severity.
        #
        # The key set is DERIVED from the vocabulary rather than restated
        # alongside it, which is what makes a fourth annotation kind -- or a
        # dropped one, or a renamed one -- a loud `KeyError` naming it while
        # this class body runs, instead of a kind nothing can rank that only
        # surfaces the day somebody uses it.
        TIERS = { "note" => "HINT", "question" => "WARN", "blocker" => "ERROR" }.freeze
        private_constant :TIERS

        SEVERITIES = ANNOTATION_KINDS.to_h { |kind| [kind, TIERS.fetch(kind)] }.freeze

        # The critique skill's ranks (`skill/critique/skill.md` ranks every
        # finding BLOCKER / SHOULD-FIX / NIT), on the same three tiers.
        #
        # DERIVED from {SEVERITIES} rather than restated beside it, for
        # {Review::VOCABULARY}'s reason: two independent declarations of one
        # correspondence are free to disagree, and the disagreement would be
        # invisible -- both sides would still render diagnostics, just at
        # different severities depending on which door a note came in by. The
        # correspondence itself is a judgement and is stated here once: a
        # BLOCKER is what `blocker` is, a NIT is what `note` is, and SHOULD-FIX
        # takes the tier between them, which `question` also takes.
        RANKS = { "BLOCKER" => SEVERITIES.fetch("blocker"), "SHOULD-FIX" => SEVERITIES.fetch("question"),
                  "NIT" => SEVERITIES.fetch("note") }.freeze

        # Where the human's own notes render. A finding renders in its own
        # namespace (T22 passes one), so a suggestion is visibly a suggestion
        # and clearing one never touches the other.
        DEFAULT_NAMESPACE = "lain_review_diagnostics"

        # What nvim prints beside a message. Says which door a note came in by,
        # which is the whole reason a finding is distinguishable on screen.
        DEFAULT_SOURCE = "review"

        attr_reader :namespace, :source

        # @param namespace [String] the diagnostic namespace to render into
        # @param source [String] the attribution nvim shows beside each message
        def initialize(namespace: DEFAULT_NAMESPACE, source: DEFAULT_SOURCE)
          @namespace = -namespace.to_str
          @source = -source.to_str
          freeze
        end

        # @param annotations [Enumerable<#mark, #text, #kind>] each answering
        #   the extmark holding its position, the words, and its kind
        # @return [Array<Hash>] deeply frozen, keyed as a lua table is so
        #   nothing has to translate on the far side
        # @raise [UnknownKind] naming the kind and the ones that exist
        def entries(annotations)
          annotations.map { |annotation| entry(annotation) }.freeze
        end

        # The lua entry point's argument list, in its order.
        #
        # @param buffer [Integer] the nvim buffer the anchors live in
        # @param annotations [Enumerable<#mark, #text, #kind>]
        # @return [Array]
        def arguments(buffer, annotations) = [buffer, namespace, entries(annotations)]

        # @return [String] the nvim severity name for one annotation kind
        # @raise [UnknownKind]
        def self.severity!(kind)
          SEVERITIES.fetch(kind.to_s) do
            raise UnknownKind, "#{kind.inspect} is not a kind this projection can rank; " \
                               "annotation kinds: #{SEVERITIES.keys.join("/")}; " \
                               "critique ranks: #{RANKS.keys.join("/")}"
          end
        end

        private

        def entry(annotation)
          { "mark" => annotation.mark, "message" => -annotation.text.to_str,
            "severity" => self.class.severity!(annotation.kind), "source" => source }.freeze
        end
      end
    end
  end
end
