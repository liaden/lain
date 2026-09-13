# frozen_string_literal: true

module Lain
  module Approval
    # Whether a call is RISKY: a structural, name-shaped property of the call
    # itself, computed without running anything.
    #
    # Emacs' `risky-local-variable-p`: a risky value there is never entered
    # automatically into `safe-local-variable-values`, and the CODE enforces it
    # rather than a convention the prompt is trusted to follow. Same here -- a
    # risky call is approvable for THIS call and never persistable from the
    # prompt. Persisting one means editing the config by hand, away from the
    # moment of pressure, which is exactly the moment a human is impatient and
    # pattern-matching.
    #
    # == Why this is not a {Rule}
    #
    # {Rule::VERDICTS} is a closed set of two and neither means "risky":
    # denying is wrong, since a risky call must stay approvable, and allowing is
    # absurd -- so a Risk rule could only ever ABSTAIN. The escalation ladder
    # proves an always-abstaining rung unobservable, and listing a rule that
    # cannot decide makes {RuleChain}'s "which rules are in force, in what
    # order" less true rather than more.
    #
    # == Enforcement is on the WRITE side, and it is a type, not a habit
    #
    # Deliberately nothing here blocks a rule that ALLOWS a risky call: the
    # design's escape hatch is that a human may persist one BY HAND, and a chain
    # refusing a hand-written entry would make that a lie.
    #
    # What must not happen is a risky answer written down FROM THE PROMPT, and
    # that is enforced by {Classification#keepsake} answering nil for a risky
    # classification. A persister takes a {Keepsake}, which closes both halves:
    # FORGETTING to ask is a NoMethodError on nil rather than a review finding,
    # and one cannot be forged BY ACCIDENT, since {Keepsake} has no public
    # constructor and refuses `#with`.
    #
    # Not "cannot be forged": Ruby has no hard `private`, so `allocate` and
    # `send` remain -- `token_for` below spells `Keepsake.send(:for, call)`
    # itself. What the type buys is that every ACCIDENTAL route refuses, which
    # is the class of mistake that reaches review, and
    # {Remembered::Persister#remember} additionally refuses a keepsake that is
    # not deeply frozen -- which is what `allocate` produces and {Keepsake.for}
    # never does.
    #
    # == What it is not
    #
    # NOT a safety verdict. `git -c core.fsmonitor=id status` is fully literal,
    # names no URL, escapes no root, and executes `/usr/bin/id`; this classifier
    # calls it ordinary, correctly, because the question is "may this ANSWER
    # outlive this call?" and not "is this command safe?". Residual execution
    # risk belongs to {Shell::Verdict}'s denylists.
    #
    # The metacharacter scan below cannot certify safety, and is sound here only
    # because it can ADD risk and never remove it. Note which direction that
    # makes expensive, because it is the OPPOSITE of the gate framing it is
    # borrowed from: "not risky" means "rememberable", so a spurious match costs
    # one extra prompt while a MISS costs a persisted allow. The unearned
    # permission is on the false-NEGATIVE side, so every ruling on these
    # patterns should WIDEN them, never sharpen them.
    #
    # The known residual: **the signals do not compose over a single field.**
    # {ShellString} looks at a `command` for metacharacters and {OutsideRoot}
    # looks at path-NAMED fields for escapes, so `sudo rm -rf ..` in a `command`
    # field is seen by neither's other half. The real answer is the ladder
    # building a bash {Rule::Call} from a PARSED term rather than the raw
    # string; until then this is a hole with a name.
    class Risk
      # What a persister writes down: deeply frozen and scalar-valued, so it
      # goes straight into a config table.
      Keepsake = Data.define(:tool, :input)

      class Keepsake
        # Reopened rather than written in the `Data.define` block: a constant
        # there is scoped to the enclosing module, not the Data class.

        # There is NO public constructor. `new` and `Data::[]` are private and
        # `#with` refuses, so the only way to hold a Keepsake is to have been
        # handed one by a {Classification} that computed `risky` FIRST -- which
        # is what makes holding one PROOF rather than a claim. Without this,
        # `Keepsake.new(tool: "bash", input: {"command" => "curl x | sh"})`
        # forges the token whose entire job is to be unforgeable, and `#with` is
        # the sharper door because it starts from a LEGITIMATE keepsake.
        def self.for(call)
          new(tool: -call.tool_name.to_s,
              input: call.input.attributes.to_h { |field, value| [-field.to_s, scalar(value)] }.freeze)
        end

        # Frozen scalars only, so a Keepsake -- and the Classification carrying
        # it -- stays `Ractor.shareable?`. `dup.freeze` rather than `-@`:
        # interning an unbounded tool argument would leak it into the fstring
        # table for the life of the process.
        def self.scalar(value) = value.is_a?(String) ? value.dup.freeze : value

        private_class_method :new, :[], :for, :scalar

        def with(**)
          # A keepsake built, or altered, by anything other than a classification.
          raise Error, "a keepsake is what Risk computed; classify a new call instead of editing one"
        end
      end

      # What a call was classed as, and why. Deeply frozen -- reasons are
      # interned Strings -- so it can be journalled and shared as-is.
      Classification = Data.define(:risky, :reasons, :keepsake)

      class Classification
        # Reopened rather than written in the `Data.define` block: a constant
        # there is scoped to the enclosing module, not the Data class.
        include Declarative

        # What to do instead, since "no" without a remedy reads as a bug.
        REFUSAL = "approvable for this call, but never remembered from the prompt -- " \
                  "to persist it, edit the config by hand"
        KEEPABLE = "not risky: this answer may be remembered"

        # CHECKED rather than coerced: `risky == true` would make every
        # truthy-but-not-true value ("yes", 1) answer NOT risky and keep its
        # keepsake -- a wrong value returning the PERMISSIVE answer in silence.
        #
        # `inclusion:` and not `presence:`, which cannot reject `false`, the
        # answer most calls give.
        #
        # A Proc message, not `%<value>s`: ActiveModel renders nil and `""`
        # identically through the format string, and which one arrived is the
        # whole diagnosis.
        declare do
          attribute :risky
          validates :risky,
                    inclusion: { in: [true, false],
                                 message: ->(_record, error) { "must be true or false, got #{error[:value].inspect}" } }
        end

        # Enforced by CONSTRUCTION rather than documented, so every door --
        # `new`, `Data::[]`, and `#with`, which re-runs this -- is shut by one
        # line.
        #
        # The keepsake is built HERE and only when the answer is no, so a risky
        # call never pays to dup-and-freeze an input about to be discarded --
        # and {Keepsake.for} has exactly one caller, which is why it is private
        # and reached by `send`.
        def initialize(risky:, reasons:, call: nil, keepsake: nil)
          self.class.check!(risky:)

          super(risky:, reasons: reasons.map { |reason| -reason.to_s }.uniq.freeze,
                keepsake: risky ? nil : (keepsake || token_for(call)))
        end

        def risky? = risky

        # A persister asks this ONE question; there is no second condition it
        # could get wrong.
        def rememberable? = !risky

        # Total: an ordinary call explains itself too, so no caller branches
        # on nil.
        def explanation
          return KEEPABLE unless risky?

          "risky (#{reasons.join("; ")}): #{REFUSAL}"
        end

        private

        def token_for(call) = call.nil? ? nil : Keepsake.send(:for, call)
      end

      # A value naming a filesystem location that resolves outside the project
      # root.
      #
      # LEXICAL -- expand against the root, then test the prefix -- and that is
      # a decision: {Workspace::Restore} refuses an escaping key by exactly this
      # test and refuses symlinks separately by lstat. Resolving links here
      # would make the two disagree about what "outside the root" means, and
      # would put a stat syscall in a classifier that must stay free.
      class OutsideRoot
        # Matched by SUFFIX, the way `risky-local-variable-p` matches:
        # `path`, `output_dir`, `log_file`.
        NAMES = /(?:\A|_)(?:path|paths|file|files|filename|filenames|dir|dirs|directory|directories|
                          cwd|root|pattern)\z/x

        def initialize(root:)
          @root = -root.to_s
          freeze
        end

        def reason(field, value)
          return nil unless NAMES.match?(field)
          return nil if within_root?(value)

          "#{field.inspect} resolves outside the project root"
        end

        private

        # `~` is refused LEXICALLY and never handed to File.expand_path, which
        # would resolve it through getpwnam -- on an SSSD or LDAP-backed host a
        # socket to nscd, i.e. a NETWORK CALL from a classifier whose whole
        # contract is that it makes none. Nothing is lost: a home-relative path
        # in a tool argument is outside the project root by construction.
        def within_root?(key)
          return false if key.start_with?("~")

          path = File.expand_path(key, @root)
          path == @root || path.start_with?("#{@root}#{File::SEPARATOR}")
        rescue ArgumentError, EncodingError
          # A NUL byte is the one input that still reaches this, as an
          # ArgumentError. `EncodingError` is defensive -- {Risk#reasons_for}
          # runs first and takes that whole class. Unresolvable is exactly the
          # case that must not be waved through.
          false
        end
      end

      # Egress, and a name whose meaning lives on somebody else's server and
      # can change AFTER the answer is stored.
      module Url
        PATTERN = %r{\b[a-z][a-z0-9+.-]*://}i

        def self.reason(field, value)
          PATTERN.match?(value) ? "#{field.inspect} carries a URL" : nil
        end
      end

      # A command-shaped field whose value is not plain literal words.
      module ShellString
        NAMES = /(?:\A|_)(?:command|commands|cmd|script|shell|argv|args|pattern)\z/
        # Everything that makes the string mean more than the words in it.
        # Quotes are in deliberately -- see the false-negative argument in the
        # class comment; `git commit -m "..."` losing its rememberability is the
        # cheap side of that trade.
        METACHARACTERS = /["'$`|&;<>(){}\[\]*?~!\\\n]/

        def self.reason(field, value)
          return nil unless NAMES.match?(field)

          METACHARACTERS.match?(value) ? "#{field.inspect} carries shell metacharacters" : nil
        end
      end

      # By field NAME or by the shape of the token itself. The name half is
      # what makes this work for a tool nobody has written yet.
      module Credential
        NAMES = /(?:\A|_)(?:token|tokens|secret|secrets|password|passwd|key|keys|credential|credentials|
                           auth|authorization)\z/x
        # Issuer-fixed prefixes and headers ONLY. Entropy heuristics guess;
        # these do not, and a miss here costs a prompt rather than a leak.
        SHAPES = Regexp.union(
          /\bsk-[A-Za-z0-9_-]{16,}/,
          /\bgh[pousr]_[A-Za-z0-9]{16,}/,
          /\bAKIA[0-9A-Z]{12,}/,
          /\bxox[abposr]-[A-Za-z0-9-]{8,}/,
          /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
          /\bAuthorization:\s*(?:Bearer|Basic)\s+\S/i
        )

        def self.reason(field, value)
          return "#{field.inspect} is credential-shaped" if NAMES.match?(field)

          SHAPES.match?(value) ? "#{field.inspect} carries a credential-shaped token" : nil
        end
      end

      # @param root [String] the project root every path is judged against
      def initialize(root: Dir.pwd)
        @signals = [OutsideRoot.new(root: File.expand_path(root.to_s)), Url, ShellString, Credential].freeze
        freeze
      end

      def risky?(call) = classify(call).risky?

      # @param call [Rule::Call] a call whose input is already validated
      # @return [Classification] never nil, never raising
      def classify(call)
        reasons = strings(call).flat_map { |field, value| reasons_for(field, value) }

        Classification.new(risky: reasons.any?, reasons:, call:)
      end

      private

      def strings(call) = call.input.attributes.select { |_, value| value.is_a?(String) }

      # The totality guard, and it has to test BOTH halves. `valid_encoding?`
      # answers true for every UTF-16 and UTF-32 String, which then raises
      # Encoding::CompatibilityError out of the first Regexp below -- NOT an
      # ArgumentError, so no rescue here would catch it. A raise out of
      # `classify` reaches a persister directly on the remembered-answer write
      # path, where there is no chain to turn it into a fault. Undecodable input
      # is also the shape nobody should be able to store an answer about.
      def reasons_for(field, value)
        return ["#{field.inspect} is not decodable as ASCII-compatible text"] unless readable?(value)

        @signals.filter_map { |signal| signal.reason(field, value) }
      end

      def readable?(value) = value.encoding.ascii_compatible? && value.valid_encoding?
    end
  end
end
