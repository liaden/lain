# frozen_string_literal: true

module Lain
  module Approval
    # Whether a call is RISKY: a structural, name-shaped property of the call
    # itself, computed without running anything.
    #
    # This is Emacs' `risky-local-variable-p`. A risky value there "is never
    # entered automatically into `safe-local-variable-values`", and the `!` key
    # -- apply everything -- marks only the NON-risky ones for the future. The
    # code enforces it; it is not a convention the prompt is trusted to follow.
    # Same here: a risky call is approvable for THIS call and is never
    # persistable from the prompt. Persisting one means editing the config by
    # hand, deliberately, away from the moment of pressure -- which is exactly
    # the moment a human is impatient and pattern-matching.
    #
    # == Why this is not a {Rule}
    #
    # It was one, and the panel was right to take it out. {Rule::VERDICTS} is a
    # closed set of two and neither means "risky": denying is wrong (a risky
    # call must stay approvable) and allowing is absurd, so a Risk rule could
    # only ever abstain. An always-abstaining rung is exactly what the
    # escalation ladder PROVES is unobservable ("an abstaining rung does not
    # change the outcome"), and an object whose membership in a collaboration is
    # provably unobservable does not belong in that collaboration. Listing a
    # rule that cannot decide also makes {RuleChain}'s "which rules are in
    # force, in what order" less true rather than more.
    #
    # It still takes a {Rule::Call} as its subject, and gets that type's
    # guarantee -- input already through the tool's own {Tool::Input} validation
    # -- from `Call#initialize`, not from any hierarchy.
    #
    # == Enforcement is on the WRITE side, and it is a type, not a habit
    #
    # Deliberately nothing here blocks a rule that ALLOWS a risky call. The
    # design's own escape hatch is that a human may persist a risky answer by
    # hand; a chain that refused to honour a hand-written entry would make "edit
    # the config yourself" a lie.
    #
    # So the one thing that must not happen is a risky answer being written down
    # FROM THE PROMPT -- and that is enforced by {Classification#keepsake},
    # which answers nil for a risky classification. A persister takes a
    # {Keepsake}, which closes both halves: FORGETTING to ask is a NoMethodError
    # on nil rather than a review finding, and one cannot be forged BY ACCIDENT
    # because {Keepsake} has no public constructor and refuses `#with`.
    #
    # Not "cannot be forged": Ruby has no hard `private`, so `allocate` and
    # `send` remain -- `token_for` below spells `Keepsake.send(:for, call)`
    # itself -- and {Rule::Call} lives with the same residue one card back.
    # What the type buys is that every ACCIDENTAL route refuses, which is the
    # class of mistake that actually reaches review;
    # {Remembered::Persister#remember} additionally refuses a keepsake that is
    # not deeply frozen, which is what `allocate` produces and {Keepsake.for}
    # never does. Emacs' claim is that the code enforces it; a documented
    # convention would not.
    #
    # == What it is not
    #
    # It is not a safety verdict. `git -c core.fsmonitor=id status` is fully
    # literal, names no URL, escapes no root, and executes `/usr/bin/id`; this
    # classifier calls it ordinary, correctly, because the question it answers
    # is "may this ANSWER outlive this call?" rather than "is this command
    # safe?". Residual execution risk belongs to {Shell::Verdict}'s name
    # denylist and the program denylist beside it.
    #
    # The metacharacter scan below is the one pattern-match in the design, and
    # `tool/input.rb:15-40` is right that such a scan cannot certify safety. It
    # is sound here only because it can add risk and can never remove it -- but
    # note which direction that makes expensive, because it is the OPPOSITE of
    # the gate framing it is borrowed from. "Not risky" means "rememberable", so
    # a spurious match costs one extra prompt and a MISS costs a persisted
    # allow: the unearned permission is on the false-NEGATIVE side. Every
    # ruling on these patterns should therefore widen them, never sharpen them.
    #
    # The known residual, named the way the `core.fsmonitor` one is: **the
    # signals do not compose over a single field.** {ShellString} looks at a
    # `command` for metacharacters and {OutsideRoot} looks at path-NAMED fields
    # for escapes, so `sudo rm -rf ..` in a `command` field is seen by neither's
    # other half. The real answer is the ladder building a bash {Rule::Call}
    # from a parsed term (T15/T16/T21) rather than from the raw string; until
    # then this is a hole with a name.
    class Risk
      # A keepsake built, or altered, by anything other than a classification.
      class Forged < Error; end

      # What a persister writes down: the tool's name and the exact input
      # shape, already deeply frozen and scalar-valued (a {Tool::Input} field is
      # a JSON scalar by declaration), so it goes straight into a config table.
      Keepsake = Data.define(:tool, :input)

      # Reopened rather than written in the `Data.define` block, per
      # {Request::SYSTEM_PREFIX}.
      class Keepsake
        # There is NO public constructor. `new` and `Data::[]` are private and
        # `#with` refuses, so the only way to hold a Keepsake is to have been
        # handed one by a {Classification} that computed `risky` first -- which
        # is what makes holding one PROOF rather than a claim. Without this,
        # `Keepsake.new(tool: "bash", input: {"command" => "curl x | sh"})`
        # forges the token whose entire job is to be unforgeable, and `#with` is
        # the sharper door because it starts from a LEGITIMATE keepsake.
        # {Rule::Call} earned exactly this treatment one card ago.
        def self.for(call)
          new(tool: -call.tool_name.to_s,
              input: call.input.attributes.to_h { |field, value| [-field.to_s, scalar(value)] }.freeze)
        end

        # Frozen scalars only, so a Keepsake -- and the Classification carrying
        # it -- stays `Ractor.shareable?`. `String#dup.freeze` rather than `-@`:
        # interning an unbounded tool argument would leak it into the fstring
        # table for the life of the process.
        def self.scalar(value) = value.is_a?(String) ? value.dup.freeze : value

        private_class_method :new, :[], :for, :scalar

        def with(**)
          raise Forged, "a keepsake is what Risk computed; classify a new call instead of editing one"
        end
      end

      # What a call was classed as, and why. Deeply frozen -- reasons are
      # interned Strings -- so it can be journalled and shared as-is.
      Classification = Data.define(:risky, :reasons, :keepsake)

      # Reopened rather than written in the `Data.define` block: a constant or
      # nested class declared inside that block is lexically scoped to the
      # enclosing module, not to the Data class (see {Request::SYSTEM_PREFIX}).
      class Classification
        REFUSAL = "approvable for this call, but never remembered from the prompt -- " \
                  "to persist it, edit the config by hand"
        KEEPABLE = "not risky: this answer may be remembered"
        NOT_BOOLEAN = "risky must be true or false"

        # Two invariants, both enforced by CONSTRUCTION rather than documented,
        # so every door -- `new`, `Data::[]`, and `#with`, which re-runs this --
        # is shut by the same two lines.
        #
        # `risky` is checked rather than coerced. `risky == true` would make
        # every truthy-but-not-true value ("yes", 1) answer NOT risky and keep
        # its keepsake -- a wrong value returning the permissive answer in
        # silence, which is the reason CLAUDE.md rejects `StringInquirer`.
        # {Rule::Decision} coerces `gated`, which merely describes, and raises
        # on `verdict`, which decides; `risky` decides.
        #
        # The keepsake is built HERE, from the call, and only when the answer is
        # no -- so a risky call never pays to dup-and-freeze an input that is
        # about to be discarded, and {Keepsake.for} has exactly one caller,
        # which is why it is private and reached by `send`.
        def initialize(risky:, reasons:, call: nil, keepsake: nil)
          raise ArgumentError, "#{NOT_BOOLEAN}, got #{risky.inspect}" unless [true, false].include?(risky)

          super(risky:, reasons: reasons.map { |reason| -reason.to_s }.uniq.freeze,
                keepsake: risky ? nil : (keepsake || token_for(call)))
        end

        def risky? = risky

        # The whole reason this value exists: a persister asks this ONE
        # question, and there is no second condition it could get wrong.
        def rememberable? = !risky

        # What to show a human who asked to remember an answer we will not
        # keep. Total: an ordinary call explains itself too, so no caller
        # branches on nil.
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
      # Lexical -- expand against the root, then test the prefix -- and that is
      # a decision, not an omission: {Workspace::Restore} refuses an escaping
      # key by exactly this test (`restore.rb:167-169`) and refuses symlinks
      # separately and unconditionally by lstat. Resolving links here would make
      # the two disagree about what "outside the root" means, and it would put a
      # stat syscall in a classifier that must stay free.
      #
      # A class where its three siblings are modules because it is the only one
      # that holds anything.
      class OutsideRoot
        # Matched by SUFFIX, which is how `risky-local-variable-p` matches
        # (`-file-name$`, `-directory$`): `path`, `output_dir`, `log_file`.
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
        # would resolve it through getpwnam -- on an SSSD or LDAP-backed host
        # that is a socket to nscd, i.e. a network call, from a classifier whose
        # whole contract is that it makes none. Nothing is lost: a home-relative
        # path in a tool argument is outside the project root by construction,
        # and {Workspace::Restore} never sees a `~` key, so the two still cannot
        # disagree.
        def within_root?(key)
          return false if key.start_with?("~")

          path = File.expand_path(key, @root)
          path == @root || path.start_with?("#{@root}#{File::SEPARATOR}")
        rescue ArgumentError, EncodingError
          # A NUL byte is the one input that still reaches this, and it arrives
          # as an ArgumentError. `EncodingError` is defensive: the guard in
          # {Risk#reasons_for} runs first and takes that whole class, so no
          # value reaching here has been observed to raise it. Unresolvable is
          # exactly the case that must not be waved through.
          false
        end
      end

      # A URL anywhere in any value: egress, and a name whose meaning lives on
      # somebody else's server and can change after the answer is stored.
      module Url
        PATTERN = %r{\b[a-z][a-z0-9+.-]*://}i

        def self.reason(field, value)
          PATTERN.match?(value) ? "#{field.inspect} carries a URL" : nil
        end
      end

      # A command-shaped field whose value is not plain literal words.
      module ShellString
        NAMES = /(?:\A|_)(?:command|commands|cmd|script|shell|argv|args|pattern)\z/
        # Substitution, chaining, redirection, grouping, globbing, quoting and
        # history: everything that makes the string mean more than the words in
        # it. Quotes are in deliberately -- see the false-negative argument in
        # the class comment; `git commit -m "..."` losing its rememberability is
        # the cheap side of that trade.
        METACHARACTERS = /["'$`|&;<>(){}\[\]*?~!\\\n]/

        def self.reason(field, value)
          return nil unless NAMES.match?(field)

          METACHARACTERS.match?(value) ? "#{field.inspect} carries shell metacharacters" : nil
        end
      end

      # A credential, by field name or by the shape of the token itself. The
      # name half is what makes this work for a tool nobody has written yet.
      module Credential
        NAMES = /(?:\A|_)(?:token|tokens|secret|secrets|password|passwd|key|keys|credential|credentials|
                           auth|authorization)\z/x
        # Issuer-fixed prefixes and headers only. Entropy heuristics guess;
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
      # Encoding::CompatibilityError out of the first Regexp below -- and that
      # is NOT an ArgumentError, so no rescue here would catch it. A raise out
      # of `classify` reaches a persister directly on the T20 write path, where
      # there is no chain to turn it into a fault. Undecodable input is also
      # precisely the shape nobody should be able to store an answer about, so
      # it is risky in its own right.
      def reasons_for(field, value)
        return ["#{field.inspect} is not decodable as ASCII-compatible text"] unless readable?(value)

        @signals.filter_map { |signal| signal.reason(field, value) }
      end

      def readable?(value) = value.encoding.ascii_compatible? && value.valid_encoding?
    end
  end
end
