# frozen_string_literal: true

module Lain
  module Compaction
    class DerivationAudit
      # What an audit answers about ONE journalled edge: both the four verdicts
      # and the single duck all four share.
      #
      # It is a namespace and a mixin at once, deliberately. The mixin half is
      # CLAUDE.md's Null Object rule applied to a sum type: every verdict
      # answers every question, defaulting to "no" and "nothing", so a caller
      # folding a mixed set never asks what class it is holding. `Agreement` has
      # no `rederived` to disagree with and `Vacuous` has no diagnosis, but both
      # answer those messages, and the one place that knows the difference is
      # the verdict itself.
      #
      # A `Data` member takes precedence over a default defined here, which is
      # what lets a verdict declare a field and inherit the rest.
      #
      # All four are deeply frozen and `Ractor.shareable?`: the digests they
      # carry are interned on the way out of {DerivationAudit::Edge}, and a
      # reason is frozen as it is built.
      module Finding
        def agreed? = false
        def drifted? = false
        def vacuous? = false

        # Whether this finding is evidence about bytes at all. False only for
        # {Vacuous}, which is what makes a journal of empty-source edges
        # {DerivationAudit#nothing_to_check?} rather than an agreement.
        def checkable? = true

        def diagnosis = nil
        def recorded = nil
        def rederived = nil
        def derived_head = nil
        def reason = nil

        def derivation_bug? = diagnosis == :derivation_bug
        def incomplete_replay? = diagnosis == :incomplete_replay
        def unclaimed_purity? = diagnosis == :unclaimed_purity
        def window_disagrees? = diagnosis == :window_disagrees
        def window_or_replay? = diagnosis == :window_or_replay

        # The re-derivation reproduced the head the edge names.
        Agreement = Data.define(:strategy, :source_head, :recorded, :rederived) do
          include Finding

          def agreed? = true

          # The head the record and the rebuild both name -- equal here, and
          # this is what a reader wants to call it.
          def derived_head = recorded

          def notice
            "#{strategy} re-derives #{source_head.inspect} to #{derived_head.inspect}, the head its journalled " \
              "edge names"
          end
        end

        # It reproduced a different one. Both digests are named, because which
        # of them is wrong is exactly what a reader has to go and find out.
        Drift = Data.define(:strategy, :source_head, :recorded, :rederived, :diagnosis) do
          include Finding

          def drifted? = true

          def notice
            "#{strategy} re-derives #{source_head.inspect} to #{rederived.inspect}, but its journalled edge " \
              "names #{recorded.inspect}: #{DIAGNOSES.fetch(diagnosis)}"
          end
        end

        # Nothing could be rebuilt, so nothing is vouched for either way. NOT a
        # drift: an unanswerable question is not a negative answer.
        Unverifiable = Data.define(:strategy, :source_head, :reason) do
          include Finding

          # The one verdict whose `strategy` and `source_head` can both be
          # absent -- a record too malformed to name either still gets reported,
          # and a notice reading "names nil" beside a named fallback would look
          # like a missing interpolation rather than like the fault it is.
          def notice
            "#{strategy || "(a record naming no strategy)"} #{names_source}, which this audit " \
              "cannot check: #{reason}"
          end

          private

          def names_source = source_head.nil? ? "names no source head" : "names #{source_head.inspect}"
        end

        # An edge over an empty source: it derived nothing from nothing. Well
        # formed, honest, and evidence about no bytes at all -- which is why it
        # is not an agreement, `nil == nil` being the one comparison that proves
        # nothing.
        Vacuous = Data.define(:strategy, :source_head) do
          include Finding

          def vacuous? = true
          def checkable? = false

          def notice = "#{strategy} derived the empty chain from the empty source, which vouches for no bytes"
        end
      end
    end
  end
end
