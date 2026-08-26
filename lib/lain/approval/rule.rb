# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Approval
    # One approval rule: a PARTIAL predicate over a parsed tool call.
    #
    # Emacs' keymap lookup chain applied to approval. A rule with nothing to
    # say answers nothing at all and {RuleChain} asks the next one -- most
    # policy engines force every rule to be TOTAL, which makes "no opinion"
    # indistinguishable from "allow" and buries the interesting rule under a
    # pile of `true`s.
    #
    # Abstention is `nil` rather than a Null decision, the one place this file
    # departs from the house Null-Object preference: a decision object must
    # carry a verdict, and every value that field could hold would be a claim
    # the rule did not make.
    #
    # == What a rule is handed
    #
    # A {Call}: the tool, plus its input already through the tool's own
    # {Tool::Input} validation. Never a raw Hash, and the guarantee is the
    # TYPE's rather than one constructor's good manners -- {Call#initialize}
    # refuses anything that is not a {Tool::Input}, so `new`, `Data::[]` and
    # `#with` are all shut by the same line.
    #
    # == The unmechanized half, and the hazard it leaves
    #
    # A tool whose declared field IS a command String hands a rule that String,
    # and nothing here stops a rule from prefix-matching it. The DOCTRINE is
    # that a shell command reaches policy as a parsed term (`Shell::Parse` /
    # `Shell::Verdict`) or not at all -- but the escalation ladder does not
    # enforce it: its `rules` rung still calls `Call.for(tool:, input:
    # effect.input)` with the model's raw input. Discharging that needs a
    # decision this Call cannot express today, since no {Tool::Input} declares a
    # field shaped like `[["git", "-c", "...", "status"]]` and most commands
    # ABSTAIN at the verdict -- so a term-carrying Call would be absent for
    # exactly the calls a rule most wants to read.
    #
    # The hazard is specific: the ladder consults
    # {Approval::Escalation::Triage} FIRST, which abstains on `git ...` because
    # git is a program runner, and then hands the `rules` rung the raw string
    # anyway. A hand-written prefix rule -- `command.start_with?("git ")` --
    # would therefore allow `git -c core.fsmonitor=id status`, which executes
    # `id`. `Remembered` is not that rule, matching an exact call shape rather
    # than a prefix, so nothing shipped is exploitable today. The fix is carried
    # in `planning/specs/chunk-modes-approval-undo.md`: give {Call} a
    # term-carrying door and build a command tool's Call from the parsed term.
    #
    # == Identity travels with the decision
    #
    # "denied" is not an experiment record; "denied by THIS rule, on THIS tool,
    # at THIS tier" is. So {Decision} carries the deciding rule's name, and
    # {#name} derives from the class, so a rename breaks loudly rather than
    # silently relabelling records.
    class Rule
      class NotImplemented < Error; end
      class UnknownVerdict < Error; end

      # Three-valued policy is verdict PLUS abstention, and abstention is the
      # ABSENCE of a Decision, so only two live here.
      VERDICTS = %i[allow deny].freeze

      Decision = Data.define(:verdict, :rule, :tool, :gated, :reason)

      # What a rule decided, and everything a journal needs to say who decided
      # it. Deeply frozen: strings are interned, `gated` is coerced to a strict
      # Boolean, so `Ractor.shareable?` holds and the record is safe to share.
      class Decision
        # Reopened rather than written in the `Data.define` block: a constant
        # there is scoped to the enclosing module, not the Data class.
        include Declarative

        # Refused at CONSTRUCTION rather than where a reader branches on it: a
        # record that reaches the journal naming a verdict nothing handles is a
        # defect no later `else` can undo.
        #
        # A Proc message, not `%<value>s`: ActiveModel renders nil and `""`
        # identically through the format string, and a verdict is exactly the
        # slot where "which nothing arrived" is the diagnosis.
        declare raising: UnknownVerdict do
          attribute :verdict
          validates :verdict,
                    inclusion: { in: VERDICTS,
                                 message: lambda { |_record, error|
                                   "must be one of #{VERDICTS.inspect}, got #{error[:value].inspect}"
                                 } }
        end

        def initialize(verdict:, rule:, tool:, gated:, reason:)
          self.class.check!(verdict:)

          super(verdict:, rule: -rule.to_s, tool: -tool.to_s, gated: gated == true, reason: -reason.to_s)
        end

        def allow? = verdict == :allow
        def deny? = verdict == :deny
      end

      Call = Data.define(:tool, :input)

      # The subject of every rule: one intended tool call, with its input
      # already validated by the tool's own declaration.
      class Call
        # Reopened for {Decision}'s reason.

        # A tool whose input is a raw JSON-schema Hash rather than a
        # {Tool::Input}: nothing for a rule to read fields off, so no
        # deterministic decision is possible and the call must escalate.
        class Undeclared < Error; end

        # A Call built around something that is not a validated {Tool::Input}.
        class NotValidated < Error; end

        # @param tool [Lain::Tool] the capability being invoked
        # @param input [Hash] the model's parsed input for it
        # @return [Call] with `input` coerced and validated
        # @raise [Undeclared] when the tool declares no {Tool::Input}
        # @raise [Tool::InvalidInput] when the input does not validate
        def self.for(tool:, input:)
          model = tool.input_model
          raise Undeclared, undeclared_message(tool) unless model

          # The same two lines {Tool#validate_with_model} runs, which is
          # private and only reachable by actually performing the call. A rule
          # must see the coerced object BEFORE anything is performed. Both go
          # through `Input.build`, the single declaration neither can drift from.
          checked = model.build(input)
          raise Tool::InvalidInput, invalid_message(tool, checked) unless checked.valid?

          new(tool:, input: checked)
        end

        # Asked, so a caller routes an undescribed tool to escalation instead
        # of rescuing.
        def self.describable?(tool) = !tool.input_model.nil?

        # The one line that makes "a rule sees the validated input object" a
        # property of the TYPE. `private_class_method :new` alone shut one of
        # three doors: `Data::[]` is a second public constructor, and `#with`
        # re-runs `initialize` with whatever it is handed -- so both took a raw
        # Hash, or a bare command String, straight to a rule.
        def initialize(tool:, input:)
          raise NotValidated, not_validated_message(input) unless input.is_a?(Tool::Input)

          super
        end

        # Kept for the MESSAGE: a caller reaching for `.new` is told the door
        # has a name rather than that a keyword was wrong.
        private_class_method :new

        def self.undeclared_message(tool)
          "#{tool.name.inspect} declares no Tool::Input, so an approval rule has no fields to read"
        end
        private_class_method :undeclared_message

        def self.invalid_message(tool, checked)
          "invalid input for #{tool.name}: #{checked.errors.full_messages.join("; ")}"
        end
        private_class_method :invalid_message

        def tool_name = tool.name

        # Whether the model controls this tool's command string, which is the
        # axis the gate already turns on.
        def gated? = tool.requires_approval?

        private

        def not_validated_message(input)
          "a Call carries a validated Tool::Input, got #{input.class} -- build it with Call.for"
        end
      end

      # Derived from the class basename, so a `BashOnly` rule is `"bash_only"`.
      # An anonymous rule cannot answer it and says so: a decision nobody can
      # attribute is not an experiment record.
      ANONYMOUS = "an anonymous rule must define #name -- a decision names the rule that made it"
      private_constant :ANONYMOUS

      def name
        basename = self.class.name.to_s.split("::").last.to_s
        raise NotImplemented, ANONYMOUS if basename.empty?

        basename.underscore
      end

      # @param _call [Call] the call to judge
      # @return [Decision, nil] nil meaning "no opinion", so the next rule decides
      def decide(_call)
        raise NotImplemented, "#{self.class} must define #decide"
      end

      protected

      def allow(call, because:) = decide_that(:allow, call, because)
      def deny(call, because:) = decide_that(:deny, call, because)

      private

      def decide_that(verdict, call, reason)
        Decision.new(verdict:, rule: name, tool: call.tool_name, gated: call.gated?, reason:)
      end
    end
  end
end
