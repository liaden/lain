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
    # effect, and that is what keeps the {Effect::Approval} unwrapping in ONE
    # place: {Effect::Handler::Sensitivity} sits ahead of the Gate, so it sees
    # wrappers, which carry neither field. This class has already looked through
    # the wrapper to decide, so it alone holds the call they belong to.
    #
    # Frozen but deliberately NOT deeply so: `path` is whatever the model's
    # input held, and coercing it here would duplicate the normalization
    # {Telemetry::ReadRefused} already does on the way into the record.
    class Denial
      def reason = verdict.reason
    end

    # Does this tool call name a sensitive path -- asked by
    # {Effect::Handler::Gate}, so a `read_file` on `.env` reaches a human
    # although `read_file` declares itself tier 1.
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
    # Only the name is judged, before the file is opened. Whether the BYTES look
    # like a credential is a different question with a different answer -- it is
    # post-read, it cannot withhold the read that already happened, and it lives
    # in its own arm. The two are deliberately separate, and this one makes no
    # claim about content.
    #
    # == The one piece of coupling, in one object
    #
    # {PATH_FIELDS} is the whole of what this class knows about tools: which
    # input field names a path, per tool. That coupling is real and cannot be
    # abolished -- something has to know that `bash` names a directory in `cwd`
    # while `read_file` names a file in `path` -- so it is DATA, in one place, a
    # reader can check against the tools' own {Tool::Input} declarations. The
    # alternative, a `path`-shaped field sniffed off any input, gates on strings
    # the tool will never act on and reads as a rule nobody wrote.
    #
    # A tool the table does not name is not gated by this policy, which is why
    # the table is pinned by a spec that fails by NAME when a new path-taking
    # tool ships rather than letting it arrive unjudged in silence. That spec
    # has no allowlist to land in, deliberately: the table and the set of
    # shipped tools taking a path must be the SAME set. An earlier edition
    # allowlisted the three AST readers as "scoped out", which made a green
    # suite state three bypasses as intended -- and `ast_search path=.env
    # pattern="$A = $B"` returns the captured VALUES, byte-for-byte what
    # `read_file` returns.
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
      # tool name => the input field that names a path for that tool.
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
        "code_outline" => "path",
        "file_symbols" => "path",
        "bash" => "cwd",
        "core_exec" => "cwd"
      }.freeze

      # Gates nothing, so a chat that wired no classifier behaves byte-for-byte
      # as it did before this boundary existed and no gate writes `if
      # sensitivity`. A shared frozen instance for
      # {Middleware::RefuseSecretWrites::NullOracle}'s reason: a fresh one per
      # default would make two otherwise identical {Tools::Subagent::Seam}s
      # compare unequal.
      class Null
        def gates?(_effect) = false
        def denial(_effect) = nil

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # @param sensitivity [Sensitivity] the classifier, injected -- its home,
      #   cwd and project rules are all somebody else's to resolve
      def initialize(sensitivity:)
        @sensitivity = sensitivity
        freeze
      end

      # @param effect [Lain::Effect] any effect at all; the question is total
      #   over the vocabulary, so no caller guards on kind first
      # @return [Boolean]
      def gates?(effect)
        return false unless effect.tool_call?

        path = path_in(effect)
        !path.nil? && !@sensitivity.classify(path).ordinary?
      end

      # The DENIAL half of the same question, for {Effect::Handler::Sensitivity},
      # which refuses a denied path outright rather than gating it. It reads the
      # SAME table {#gates?} does -- one extraction, so the two axes cannot drift
      # about which field names a path -- and hands back the whole verdict,
      # because the refusal message and {Telemetry::ReadRefused} both want the
      # REASON: `:protected` and `:configured` are different findings, and
      # reporting a project's own rule as ours makes "why is my file denied?"
      # unanswerable.
      #
      # == Why this unwraps an Approval and {#gates?} does not
      #
      # The asymmetry is real and it is not an oversight, so do not "fix" it by
      # adding an unwrap to {#gates?} -- that would change WHEN the gate fires.
      # {Effect::Handler::Gate#perform} unwraps before it evaluates its own
      # axis, so `gates?` only ever sees the inner call.
      # {Effect::Handler::Sensitivity} sits AHEAD of the gate and sees the
      # wrapper, and without this an {Effect::Approval} around a denied
      # `read_file` would be declined here, unwrapped by Gate, and approved --
      # wrapping would lift a denial nothing is supposed to lift. Looking
      # through it belongs HERE and not in that handler: this class already owns
      # "which effects name paths", so this is the single home for the knowledge
      # rather than a second copy of Gate's unwrapping contract.
      #
      # @param effect [Lain::Effect] any effect at all; the question is total
      #   over the vocabulary, so no caller guards on kind first
      # @return [Denial, nil] nil when nothing here refuses
      def denial(effect)
        call = unwrapped(effect)
        # {#path_in} reads `effect.name`, which a {Effect::ModelCall} has not
        # got. Without this guard the boundary raises NoMethodError on the
        # synchronous dispatch path, and the repair a crash there invites is a
        # `rescue` answering "not denied" -- this class failing OPEN to quiet an
        # exception, which is the worst shape a security control can take.
        return nil unless call.tool_call?

        path = path_in(call)
        verdict = path && @sensitivity.classify(path)
        return nil unless verdict&.denied?

        Denial.new(tool_use_id: call.tool_use_id, tool: call.name, path:, verdict:)
      end

      private

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
      # constrain `input`, and this runs on the SYNCHRONOUS dispatch path
      # BEFORE {Tool::Input} validation, so an Array reaches `Array#[]("path")`
      # -- a TypeError out of {Effect::Handler::Gate#handles?}, where nothing
      # raised before this class existed. The repair that a raise on a security
      # path invites is a `rescue` answering false, and that is this boundary
      # failing OPEN. A shape carrying no readable field is declined instead,
      # which is the same answer with no trap in it.
      #
      # It also stops `String#[]` from answering: on a raw JSON payload that is
      # a SUBSTRING SEARCH, so a fragment of the wire bytes would be read as a
      # path. Harmless today by luck rather than by rule.
      def at(input, field)
        return nil unless input.is_a?(Hash)

        input[field] || input[field.to_sym]
      end
    end
  end
end
