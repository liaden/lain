# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module Approval
    # One approval rule: a PARTIAL predicate over a parsed tool call.
    #
    # This is Emacs' keymap lookup chain applied to approval. A rule that has
    # nothing to say about a call answers nothing at all, and {RuleChain} asks
    # the next one -- most policy engines force every rule to be a total
    # function, which makes "no opinion" indistinguishable from "allow" and
    # buries the interesting rule under a pile of `true`s.
    #
    # Abstention is `nil` rather than a Null decision, and that is the one place
    # this file departs from the house Null-Object preference on purpose: a
    # decision object must carry a verdict, and every value that field could
    # hold would be a claim the rule did not make. The ABSENCE of a decision is
    # the honest encoding, and the caller's response to it is to escalate.
    #
    # == What a rule is handed
    #
    # A {Call}: the tool itself, plus its input already through the tool's own
    # {Tool::Input} validation. Never a raw Hash, and the guarantee is the
    # TYPE's rather than one constructor's good manners: {Call#initialize}
    # refuses anything that is not a {Tool::Input}, so every door into the value
    # -- `new`, `Data::[]`, and `#with`, which re-runs `initialize` -- is shut
    # by the same line.
    #
    # What is NOT mechanized here: a tool whose declared field IS a command
    # String (`Tools::Bash#command`) hands a rule that String, and nothing in
    # this file stops a rule from prefix-matching it. That is the comforting lie
    # `lib/lain/tool/input.rb:15-40` names, one layer up. The doctrine is that a
    # shell command reaches policy as a parsed term (`Shell::Parse` /
    # `Shell::Verdict`, T15/T16) or not at all.
    #
    # T21 named itself the place to mechanize that and DID NOT. It built the
    # ladder ({Approval::Escalation}) and its `rules` rung still calls
    # `Call.for(tool:, input: effect.input)` with the model's raw input, because
    # discharging it needs a decision this Call cannot express today: a term is
    # `[["git", "-c", "...", "status"]]`, no {Tool::Input} declares a field
    # shaped like one, and most commands ABSTAIN at the verdict, so a
    # term-carrying Call would be absent for exactly the calls a rule most wants
    # to read. Widening {Call} to carry both is a reviewed change, not a detail
    # of the ladder's wiring.
    #
    # So this stays doctrine, and the hazard is now specific enough to state:
    # the ladder consults {Approval::Escalation::Triage} FIRST, which abstains on
    # `git ...` (git is a program runner), and then hands the `rules` rung the
    # raw string anyway. A hand-written prefix rule -- `command.start_with?("git
    # ")` -- would therefore allow `git -c core.fsmonitor=id status`, which
    # executes `id`. `Remembered` is not that rule (it matches an exact call
    # shape, not a prefix), so nothing shipped is exploitable today.
    #
    # It is carried as **MA-1** (`planning/specs/chunk-modes-approval-undo.md`):
    # give {Call} a term-carrying door and build a command tool's Call from the
    # parsed term. Grep the ID rather than looking for a role to blame -- "the
    # next person to write a rule" is not a trigger anything fires on.
    #
    # == Identity travels with the decision
    #
    # "denied" is not an experiment record; "denied by THIS rule, on THIS tool,
    # at THIS tier" is. So {Decision} carries the deciding rule's name, and
    # {#name} is derived from the class the way {Telemetry::Journalable} derives
    # its discriminator -- one less thing to forget, and a rename breaks loudly
    # rather than silently relabelling records.
    class Rule
      class NotImplemented < Error; end
      class UnknownVerdict < Error; end

      # The closed set. Three-valued policy is verdict PLUS abstention, and
      # abstention is the absence of a Decision, so only two live here.
      VERDICTS = %i[allow deny].freeze

      Decision = Data.define(:verdict, :rule, :tool, :gated, :reason)

      # What a rule decided, and everything a journal needs to say who decided
      # it. Deeply frozen: strings are interned, `gated` is coerced to a strict
      # Boolean, so `Ractor.shareable?` holds and the record is safe to share.
      class Decision
        # Reopened rather than written in the `Data.define` block: a constant or
        # nested class declared inside that block is lexically scoped to the
        # enclosing module, not to the Data class (see {Request::SYSTEM_PREFIX}).

        # Refuses an unknown verdict at CONSTRUCTION rather than at the point a
        # reader branches on it: a record that reaches the journal naming a
        # verdict nothing handles is a defect no later `else` can undo.
        def initialize(verdict:, rule:, tool:, gated:, reason:)
          unless VERDICTS.include?(verdict)
            raise UnknownVerdict, "unknown verdict #{verdict.inspect}; expected one of #{VERDICTS.inspect}"
          end

          super(verdict:, rule: -rule.to_s, tool: -tool.to_s, gated: gated == true, reason: -reason.to_s)
        end

        def allow? = verdict == :allow
        def deny? = verdict == :deny
      end

      Call = Data.define(:tool, :input)

      # The subject of every rule: one intended tool call, with its input
      # already validated by the tool's own declaration.
      class Call
        # Reopened for {Decision}'s reason: a nested class declared inside the
        # `Data.define` block would belong to the enclosing module instead.

        # A tool whose input is a raw JSON-schema Hash rather than a
        # {Tool::Input}. There is nothing for a rule to read fields off, so no
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

          # The same two lines {Tool#validate_with_model} runs, because that one
          # is private and only reachable by actually performing the call. A
          # rule must see the coerced object BEFORE anything is performed, so
          # the check happens here; both go through `Input.build`, which is the
          # single declaration neither can drift from.
          checked = model.build(input)
          raise Tool::InvalidInput, invalid_message(tool, checked) unless checked.valid?

          new(tool:, input: checked)
        end

        # Whether a call can be built for this tool at all -- asked, so a caller
        # routes an undescribed tool to escalation instead of rescuing.
        def self.describable?(tool) = !tool.input_model.nil?

        # The one line that makes "a rule sees the validated input object" a
        # property of the TYPE. `private_class_method :new` alone shut one of
        # three doors: `Data::[]` is a second public constructor, and `#with`
        # re-runs `initialize` with whatever it is handed -- so both took a raw
        # Hash, or a bare command String, straight to a rule. Guarding
        # `initialize` closes all three at once, which is what {Decision} does
        # with {VERDICTS} twelve lines up.
        def initialize(tool:, input:)
          raise NotValidated, not_validated_message(input) unless input.is_a?(Tool::Input)

          super
        end

        # Kept for the message: a caller reaching for `.new` is told the door
        # has a name (`.for`) rather than that a keyword was wrong.
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

        # The tier a decision is made at: whether the model controls this
        # tool's command string ({Tool#requires_approval?}), which is the axis
        # the gate already turns on.
        def gated? = tool.requires_approval?

        private

        def not_validated_message(input)
          "a Call carries a validated Tool::Input, got #{input.class} -- build it with Call.for"
        end
      end

      # The rule's identity in every record it produces. Derived from the class
      # basename, so a `BashOnly` rule is `"bash_only"`. An anonymous rule
      # cannot answer it and says so: a decision nobody can attribute is not an
      # experiment record.
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
