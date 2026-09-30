# frozen_string_literal: true

module Lain
  class Sensitivity
    Denial = Data.define(:tool_use_id, :tool, :path, :verdict)

    # What {Policy#denial} answers with: which call, which tool, the path as
    # that call wrote it, and the {Verdict} that refused it.
    #
    # It lives at THIS level rather than under the handler that consults it,
    # because the arrow has to point away from the consumers: {Telemetry} and a
    # later masking arm read a verdict too, and none of them should have to name
    # a handler's constant to do it.
    #
    # The verdict travels whole rather than collapsed to a Boolean, because the
    # model's message and the journaled record both want the REASON --
    # `:protected` and `:configured` are different findings, and reporting a
    # project's own rule as ours makes "why is my file denied?" unanswerable.
    #
    # `tool_use_id` and `tool` ride along rather than being read back off the
    # effect, which is what keeps the {Effect::Approval} unwrapping in ONE
    # place: {Middleware::Sensitivity} sits ahead of the Gate, so it sees
    # wrappers, which carry neither field.
    #
    # Frozen but deliberately NOT deeply so: `path` is whatever the model's
    # input held, and coercing it here would duplicate the normalization
    # {Telemetry::ReadRefused} already does on the way into the record.
    class Denial
      def reason = verdict.reason
    end

    # The run's path boundary, at every moment somebody needs one: does this
    # tool call name a sensitive path ({#gates?}), is it refused outright
    # ({#denial}), which rows may a listing keep ({#filter}), and what is this
    # one path ({#classify}) -- four phrasings of one question over one table.
    # The first three judge a path where it lands as well as by its name
    # ({#judge}); {#classify} is the name alone, for a caller that judges a
    # link's target itself ({Survey::Walk}).
    #
    # {#gates?} is the one {Middleware::Gate} asks, so a `read_file` on
    # `.env` reaches a human although `read_file` declares itself tier 1. The
    # whole three-place boundary, and the measured detector behind it, is in
    # ARCHITECTURE.md's "The secret boundary".
    #
    # The gate already turns on {Tool#requires_approval?}, which is the TIER
    # axis: whether the model controls the command string. This is the second
    # axis, and it is a property of the ARGUMENT rather than of the tool, so it
    # cannot live on the tool -- `read_file` is tier 1 for `README.md` and worth
    # asking about for `.env`, and nothing a tool can declare about itself
    # separates those two calls.
    #
    # == It is the PATH boundary, and it is pre-read
    #
    # The path is judged before the file is opened, twice: as the call wrote it,
    # and where it lands ({Landing}), and the stricter verdict wins. A link's
    # name says nothing about what it opens, so `notes.txt -> ~/.ssh/id_rsa`
    # judged by name alone would be read as ordinary. {Sensitivity} itself
    # stays lexical; the filesystem is asked here and, for the links it walks,
    # by {Survey::Walk}.
    #
    # A dangling link is judged where its target would be created, because a
    # write through it creates that file, and is at least {MALFORMED}. A landing
    # that cannot be resolved at all -- a loop, a directory it may not enter --
    # answers {MALFORMED} rather than raising, because the repair a raise here
    # invites is a rescue that fails open.
    #
    # Whether the BYTES look like a credential is post-read, cannot withhold the
    # read that already happened, and lives in its own arm. This one makes no
    # claim about content.
    #
    # == Not ordinary, rather than gated
    #
    # {Verdict#gated?} is false for a DENIED path, so a policy asking that
    # question would wave `~/.ssh/id_rsa` through -- ungating the most sensitive
    # class of path there is. Anything the classifier does not call ordinary
    # reaches the approval policy here. A denial is refused outright further
    # out; gating it as well costs at most one prompt for a file already
    # refused, and is the direction this boundary has to err in.
    class Policy
      # tool name => the input field that names a path for that tool, and the
      # whole of what this class knows about tools. Pinned by a spec that fails
      # BY NAME when a new path-taking tool ships, with no allowlist to land in;
      # see ARCHITECTURE.md's "The secret boundary" for why a `path`-shaped
      # field sniffed off any input was rejected.
      PATH_FIELDS = {
        "read_file" => "path",
        "glob" => "path",
        "grep" => "path",
        "list_files" => "path",
        "edit_file" => "path",
        "write_file" => "path",
        # The AST readers. Each opens the file its `path` names and returns
        # what it found there, so each is a `read_file` with a query attached.
        "ast_search" => "path",
        "file_symbols" => "path",
        "bash" => "cwd"
      }.freeze

      # Gates nothing, so a chat that wired no classifier behaves byte-for-byte
      # as it did before this boundary existed and no gate writes `if
      # sensitivity`. A shared frozen instance for
      # {Middleware::RefuseSecretWrites::NullOracle}'s reason: a fresh one per
      # default would make two otherwise identical {Tools::Subagent::Seam}s
      # compare unequal.
      class Null
        def gates?(_effect, **) = false
        def denial(_effect, **) = nil

        def classify(_path) = ORDINARY.verdict

        # {Filter::Null}, which already means "withholds nothing" -- so the
        # Null's third answer needs no third object. A policy that gates
        # nothing listing everything is the same posture said once more.
        def filter = Filter::Null.instance

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # The listing half of the same boundary: what {Middleware::WithholdSecretPaths}
      # sifts a `grep`/`glob`/`list_files` result through.
      #
      # It is one of THIS object's answers rather than something a caller builds
      # beside it, and that is the whole point. A gate that refuses a path while
      # the listing that found it enumerates the same path is the one
      # disagreement this boundary cannot have, so `Filter.new` happens in
      # exactly one place in `lib/` -- here -- and every caller takes the filter
      # that came with the gate. The discipline is what holds: {Filter} is a
      # public constructor over anything answering `#classify`.
      attr_reader :filter

      # @param sensitivity [Sensitivity] the classifier, injected -- its home,
      #   cwd and project rules are all somebody else's to resolve
      # @param home [String, nil] the classifier's home as configured, so a
      #   landing under its real path is judged under this spelling too
      # @param root [String, nil] the project root as configured, likewise
      def initialize(sensitivity:, home: nil, root: nil)
        @sensitivity = sensitivity
        @anchors = { home:, root: }.freeze
        # Built HERE, not memoized in the reader: this object freezes itself, so
        # a lazy `@filter ||=` raises FrozenError the first time anybody asks --
        # and the first asker is the tool phase, mid-run.
        @filter = Filter.new(sensitivity: Rows.new(self))
        freeze
      end

      # What {#filter} classifies a listing row by. A readable row reaching the
      # filter is already absolute ({Middleware::WithholdSecretPaths#reading}
      # joins it to its base); an unreadable one is handed over unjoined and is
      # {MALFORMED} by name, so the root stands in for a cwd nothing reads.
      class Rows
        def initialize(policy)
          @policy = policy
          freeze
        end

        def classify(row) = @policy.judge(row, cwd: File::SEPARATOR)
      end

      # A message rather than a reader handing the classifier out, so a
      # {Lain::Survey::Walk} classifies through the run's own boundary.
      #
      # @param path [String] as a caller spells it; the classifier resolves it
      # @return [Sensitivity::Verdict]
      def classify(path) = @sensitivity.classify(path)

      # The stricter of the path as written and every spelling of where it
      # lands. The literal is asked first, so a denied name costs no syscall.
      #
      # @param path [String] as the call wrote it
      # @param cwd [String] absolute; what the tool resolves a relative path against
      # @return [Sensitivity::Verdict]
      def judge(path, cwd:)
        literal = @sensitivity.classify(path)
        return literal if literal.denied?

        strictest([literal, *landed(path, cwd)])
      end

      # @param effect [Lain::Effect] any effect at all; the question is total
      #   over the vocabulary, so no caller guards on kind first
      # @param cwd [String] absolute; the call's own base, see {Session.cwd_of}
      # @return [Boolean]
      def gates?(effect, cwd:)
        return false unless effect.tool_call?

        path = path_in(effect)
        !path.nil? && !judge(path, cwd:).ordinary?
      end

      # The DENIAL half of the same question, for {Middleware::Sensitivity},
      # which refuses a denied path outright rather than gating it. It reads the
      # SAME table {#gates?} does -- one extraction, so the two axes cannot drift
      # about which field names a path -- and hands back the whole verdict,
      # because the refusal message and {Telemetry::ReadRefused} both want the
      # REASON.
      #
      # == Why this unwraps an Approval and {#gates?} does not
      #
      # The asymmetry is real and is not an oversight, so do not "fix" it by
      # adding an unwrap to {#gates?} -- that would change WHEN the gate fires.
      # {Middleware::Gate#call} unwraps before it evaluates its own axis,
      # so `gates?` only ever sees the inner call.
      # {Middleware::Sensitivity} sits AHEAD of the gate and sees the
      # wrapper, and without this an {Effect::Approval} around a denied
      # `read_file` would pass there, be unwrapped by the gate, and approved --
      # wrapping would lift a denial nothing is supposed to lift. It belongs
      # HERE, not in that layer, because this class already owns "which
      # effects name paths".
      #
      # @param effect [Lain::Effect] any effect at all; the question is total
      #   over the vocabulary, so no caller guards on kind first
      # @param cwd [String] absolute; the call's own base, see {Session.cwd_of}
      # @return [Denial, nil] nil when nothing here refuses
      def denial(effect, cwd:)
        call = unwrapped(effect)
        # {#path_in} reads `effect.name`, which a {Effect::ModelCall} has not
        # got. Without this guard the boundary raises NoMethodError on the
        # synchronous dispatch path, and the repair a crash there invites is a
        # `rescue` answering "not denied" -- this class failing OPEN to quiet an
        # exception, which is the worst shape a security control can take.
        return nil unless call.tool_call?

        path = path_in(call)
        verdict = path && judge(path, cwd:)
        return nil unless verdict&.denied?

        Denial.new(tool_use_id: call.tool_use_id, tool: call.name, path:, verdict:)
      end

      private

      # Resolved as {WorkerEnv#resolve} resolves it, so the landing judged is the
      # file the tool then opens. A spelling equal to the name already judged is
      # skipped: every listing row is absolute, and most land on themselves.
      def landed(path, cwd)
        named = File.expand_path(path, cwd)
        judged = path.start_with?(File::SEPARATOR) ? named : nil
        Landing.of(named, cwd:, **@anchors).reject { _1 == judged }.map { @sensitivity.classify(_1) }
      rescue Landing::Dangling
        [MALFORMED, *eventually(named, cwd)]
      rescue SystemCallError, ArgumentError, EncodingError
        [MALFORMED]
      end

      def eventually(named, cwd)
        Landing.eventual(named, cwd:, **@anchors).map { @sensitivity.classify(_1) }
      rescue Landing::Dangling, SystemCallError, ArgumentError, EncodingError
        []
      end

      def strictest(verdicts) = verdicts.find(&:denied?) || verdicts.find { !_1.ordinary? } || verdicts.first

      # Recursive rather than a single unwrap: {Effect::Approval} takes any
      # effect, including another Approval, and one level of unwrapping would
      # make a double wrap the bypass a single wrap no longer is.
      def unwrapped(effect) = effect.approval? ? unwrapped(effect.effect) : effect

      def path_in(effect)
        field = PATH_FIELDS[effect.name]
        field && path(at(effect.input, field))
      end

      # Mirrors {Sensitivity#text}, and for a reason narrower than symmetry:
      # {Tool::Input} COERCES rather than refuses, so the value this class
      # declines to judge and the value the tool then acts on are different
      # objects. `to_path` is the one coercion that turns a non-String into a
      # path somebody can open -- an Array becomes its own `inspect`, which
      # names no file -- so a Pathname declined here was read anyway, with no
      # approval asked. {Sensitivity#classify} always took both.
      def path(value)
        return value if value.is_a?(String)

        converted = value.respond_to?(:to_path) ? value.to_path : nil
        converted.is_a?(String) ? converted : nil
      end

      # Both spellings, because a parsed provider payload arrives with String
      # keys while an in-process caller writes Symbols, and reading only one of
      # them fails OPEN on the other. {Tool::Input.build} refuses an input
      # carrying both, so there is no ambiguity to resolve here.
      #
      # The Hash check is not defensive habit. {Effect::ToolCall} does not
      # constrain `input`, and this runs on the SYNCHRONOUS dispatch path BEFORE
      # {Tool::Input} validation, so an Array reaches `Array#[]("path")` -- a
      # TypeError out of {Middleware::Gate#call}, where nothing raised
      # before this class existed. The repair a raise on a security path invites
      # is a `rescue` answering false, and that is this boundary failing OPEN. A
      # shape carrying no readable field is declined instead. It also stops
      # `String#[]` from answering: on a raw JSON payload that is a SUBSTRING
      # SEARCH, so a fragment of the wire bytes would be read as a path.
      def at(input, field)
        return nil unless input.is_a?(Hash)

        input[field] || input[field.to_sym]
      end
    end
  end
end
