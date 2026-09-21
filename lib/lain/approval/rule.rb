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
    # TYPE's rather than one constructor's good manners -- {Call.for} is the
    # only way to hold one. `new` and `Data::[]` are private and `#with`
    # refuses outright, so {Call#initialize}'s check on `input` is a floor
    # nothing can get under rather than the only thing standing there.
    #
    # == The term door, and what still walks around it
    #
    # The DOCTRINE is that a shell command reaches policy as a parsed term
    # (`Shell::Parse` / `Shell::Verdict`) or not at all. {Call#term} is the door
    # that makes the parsed form reachable, and {Call#term?} is how a rule tells
    # "no term" from "a term of no stages" without inspecting emptiness. The
    # term is DERIVED from the Call's own input by asking the live tool -- the
    # same object the executor would dispatch, holding the same
    # {Shell::Verdict} it will pick its own arm from -- so a rule and the run
    # read ONE verdict rather than two whose agreement nothing enforces.
    #
    # Being derived is what makes the term unforgeable, and it is also what
    # decides the SHAPE of the door. The term is a function of BOTH members, so
    # closing the `term:` keyword would have closed nothing: `#with(tool:)`
    # keeps a valid input and swaps the verdict under it, which reaches a rule
    # with a term its own input never produced. {Call} therefore follows
    # {Risk::Keepsake} -- `new` and `Data::[]` private, `#with` refusing
    # WHATEVER it is handed. A blanket refusal is the point: it enumerates no
    # keywords, so it cannot be outflanked by the member nobody thought of, and
    # the one that broke an earlier draft of this file was `tool`.
    #
    # The door is open and nothing in `lib/` walks through it yet: this file
    # widens the interface, and the policy that reads a term is a separate
    # change. So the hazard the doctrine names is narrowed, not closed. The
    # ladder consults {Approval::Escalation::Triage} FIRST, which abstains on
    # `git ...` because git is a program runner, and then hands the `rules` rung
    # the same call -- whose raw string is still right there beside the term. A
    # hand-written prefix rule -- `command.start_with?("git ")` -- would
    # therefore still allow `git -c core.fsmonitor=id status`, which executes
    # `id`. {Remembered} is the only {Rule} in `lib/`, and it matches an exact
    # call shape rather than a prefix, so nothing shipped is exploitable today.
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

        # A Call built, or altered, through any door but {.for}.
        class Forged < Error; end

        # What a tool with no parse to offer answers, in the one message
        # {#term} asks a {Shell::Verdict::Decision} for, so nothing above
        # branches on nil to find out whether a term exists.
        #
        # TWO kinds of tool land here and the name must not hide the second.
        # {Tools::ReadFile} and its kin run no command at all. A command tool
        # holding no {Shell::Verdict} DOES run one -- it can even share
        # {Tools::Bash::Input} by identity -- but it hands its backend the
        # model's String either way, so it has no term to offer either. ONE Null
        # for both, because what a rule may do with them is identical: no term
        # arrived, and a rule keyed on one must not fire. A second object would
        # differ only in its name.
        #
        # `NO_TERM` is named inside the method rather than copied into a second
        # empty Array: naming the shipped one keeps absence a single object --
        # which {#term?} then has something to test against.
        class Termless
          def term = Shell::Verdict::NO_TERM
        end
        private_constant :Termless

        TERMLESS = Termless.new.freeze
        private_constant :TERMLESS

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
          # A Call built around something that is not a validated {Tool::Input}.
          raise Error, not_validated_message(input) unless input.is_a?(Tool::Input)

          super
        end

        # Kept for the MESSAGE: a caller reaching for `.new` is told the door
        # has a name rather than that a keyword was wrong. `Data::[]` is the
        # second public constructor and goes with it.
        private_class_method :new, :[]

        # The third door, and the one that starts from a LEGITIMATE Call --
        # which is what makes it the sharpest. It refuses WHATEVER it is
        # handed rather than naming the members that would forge a term,
        # because {#term} is derived from both of them and a refusal that
        # enumerates keywords is only as good as the list.
        FORGED = "a Call's term is derived from the tool and input it was built with -- " \
                 "build another with Call.for rather than editing this one"

        def with(**)
          raise Forged, FORGED
        end

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

        # The parsed command this call would run, DERIVED and never accepted:
        # the Call asks the tool it is holding what it makes of the input it is
        # holding, so a term always corresponds to that pair. A third `Data`
        # member would not have held that, and MEASURED against a stand-in
        # rather than reasoned about: `#with(term:)` re-runs {#initialize},
        # whose one check is about `input`, so the forged term is neither
        # refused nor kept -- it is silently REPLACED, and an expectation that
        # a forgery raises cannot be written. A reader has no such door, and
        # `Call.members` is unchanged, which is what leaves
        # {Remembered::Entry.for_call}'s key byte-identical.
        #
        # @return [Array<Array<String>>] one argv per stage, or
        #   {Shell::Verdict::NO_TERM}
        def term = parsed.term

        # Absence, asked rather than inferred -- and derived from the TERM, not
        # from the arm. `parsed.allow?` read through the name `term?` would be
        # a different question wearing this one's name, and "is this call
        # allowed" is a sentence to misparse in a file rules decide from.
        #
        # Identity against the Null rather than `#empty?`. MEASURED: every
        # absence -- an abstention, a denial, and a tool with no parse to offer
        # -- answers the one shipped {Shell::Verdict::NO_TERM} object, while an
        # allow answers a fresh Array. `#empty?` would agree today, and not by
        # luck: `Doubts#nothing_to_run?` puts a cause on empty stages, on an
        # empty argv and on an empty word, and an allow is exactly the result
        # whose causes are empty -- so a zero-stage allow is unreachable by
        # construction, not merely unobserved. This does not rest on that. It
        # asks whether a term ARRIVED, which stays the right question if that
        # construction ever changes.
        def term? = !term.equal?(Shell::Verdict::NO_TERM)

        private

        # One parse per ask, because a {Data} instance is frozen and has
        # nowhere to memoize. {Shell::Verdict} is frozen and pure, so repeated
        # asks answer the same.
        def parsed = tool.respond_to?(:decision_for) ? tool.decision_for(input) : TERMLESS

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
