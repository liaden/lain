# frozen_string_literal: true

module Lain
  class Sensitivity
    Denial = Data.define(:tool_use_id, :tool, :path, :verdict, :advice)

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
      # @param tool_use_id [String]
      # @param tool [String]
      # @param path [String]
      # @param verdict [Verdict]
      # @param advice [String, nil] where the model should look instead, when
      #   the refusing layer knows
      def initialize(tool_use_id:, tool:, path:, verdict:, advice: nil) = super

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

      # The tools above that only read what their path names, and so the ones
      # a confined child may run anywhere in its scope and nowhere else unasked.
      READ_TOOLS = %w[read_file glob grep list_files ast_search file_symbols].freeze

      # A file a sandbox hides from a call, and the verdict reason that hid it.
      Mask = Data.define(:path, :reason)
      LOCATIONS = %i[outside_project out_of_scope].freeze

      OUTSIDE_PROJECT = Verdict.new(level: :gated, reason: :outside_project)
      ACCOUNT_DATABASE = Verdict.new(level: :denied, reason: :account_database)

      # Gates nothing, so a chat that wired no classifier behaves byte-for-byte
      # as it did before this boundary existed and no gate writes `if
      # sensitivity`. A shared frozen instance for
      # {Middleware::RefuseSecretWrites::NullOracle}'s reason: a fresh one per
      # default would make two otherwise identical {Tools::Subagent::Seam}s
      # compare unequal.
      class Null
        def gates?(_effect, **) = false
        def denial(_effect, **) = nil

        def classify(_path, **) = ORDINARY.verdict
        def judge(_path, **) = ORDINARY.verdict

        # Still confined: a never-parking child over a run with no chat
        # refuses what it would otherwise have read outside its tree.
        #
        # @param roots [Array<String>] absolute
        # @return [Confined]
        def confined(roots:) = Confined.new(policy: self, roots:, anchors: {})

        # @return [nil] no home was configured
        def home = nil

        # @return [nil] no root was configured
        def root = nil

        # Nothing is related, so a flagged region still asks.
        def related?(_path) = false

        def in_related_tree?(_path) = false

        # {Filter::Null}, which already means "withholds nothing" -- so the
        # Null's third answer needs no third object. A policy that gates
        # nothing listing everything is the same posture said once more.
        def filter = Filter::Null.instance

        def mask_paths(_files, **) = []

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # A policy as a spawned child is judged by: the policy's own answers, and
      # a read tool aimed outside every root gated too, so a researcher's look
      # around the operator's home reaches a human whatever the names it finds.
      #
      # Only {#gates?}, {#judge} and {#confined} differ from the policy's own
      # answers. The listing filter stays the policy's own, so a read a human
      # approved outside lists what it found, and {Filter} is still built in
      # one place.
      #
      # What is judged is the path a call names and, for `glob`, the directory
      # its walk starts from ({Tools::Glob.walk_root}), each where {Landing}
      # says it lands. What a walk meets below that is not: `grep` follows a
      # file link it walks into, so a link in the project pointing out is read
      # through unasked.
      #
      # A child's read of the account database is refused rather than gated:
      # a researcher looking for its own home there is told where that is
      # instead, rather than parking a human on a question it can answer
      # itself. The main agent's read of the same files still asks.
      class Confined
        ACCOUNT_FILES = %w[/etc/passwd /etc/group /etc/passwd- /etc/group-].freeze

        attr_reader :policy

        # @param policy [Policy] what every other answer is
        # @param roots [Array<String>] absolute; a path under one is in scope
        # @param anchors [Hash] the policy's home and root as configured, so a
        #   landing is also spelled under them
        def initialize(policy:, roots:, anchors:)
          @policy = policy
          @anchors = anchors
          @roots = roots.flat_map { spellings(_1) }.uniq.freeze
          freeze
        end

        # @param roots [Array<String>] absolute; added to the ones held
        # @return [Confined]
        def confined(roots:) = Confined.new(policy: @policy, roots: [*@roots, *roots], anchors: @anchors)

        # @return [String, nil] the policy's home as configured
        def home = @anchors[:home]

        # @return [String, nil] the policy's project root as configured
        def root = @anchors[:root]

        # @param effect [Lain::Effect]
        # @param cwd [String] absolute
        # @return [Denial, nil] the policy's own, else one for a read that
        #   names or walks from the account database
        def denial(effect, cwd:) = @policy.denial(effect, cwd:) || account_denial(Policy.unwrapped(effect), cwd)
        def classify(path, within: nil) = @policy.classify(path, within:)
        def related?(path) = @policy.related?(path)
        def filter = @policy.filter
        def mask_paths(...) = @policy.mask_paths(...)

        # @param effect [Lain::Effect]
        # @param cwd [String] absolute; the call's own base
        # @param within [String] absolute; see {Policy.base_of}
        # @return [Boolean]
        def gates?(effect, cwd:, within: cwd)
          @policy.gates?(effect, cwd:, within:) || walked(effect, cwd).any? { !held?(_1) }
        end

        # @param path [String] as the call wrote it
        # @param cwd [String] absolute
        # @param within [String] absolute
        # @return [Verdict] the policy's own verdict for a denied path or one
        #   inside a root, and {OUTSIDE_PROJECT} for any other
        def judge(path, cwd:, within: cwd)
          verdict = @policy.judge(path, cwd:, within:)
          verdict.denied? || held?(File.expand_path(path, cwd)) ? verdict : OUTSIDE_PROJECT
        end

        private

        def walked(effect, cwd)
          return [] unless effect.tool_call? && READ_TOOLS.include?(effect.name)

          base = File.expand_path(Policy.path_in(effect) || ".", cwd)
          effect.name == "glob" ? [base, glob_root(effect.input, base)].compact : [base]
        end

        def account_denial(call, cwd)
          hit = walked(call, cwd).find { account_file?(_1) }
          hit && Denial.new(tool_use_id: call.tool_use_id, tool: call.name, path: Policy.path_in(call) || hit,
                            verdict: ACCOUNT_DATABASE, advice: home_advice)
        end

        def home_advice = home && "the agent's home directory is #{home}".freeze

        def account_file?(named)
          ACCOUNT_FILES.include?(named) || landings(named).intersect?(ACCOUNT_FILES)
        end

        def landings(named)
          Landing.of(named, cwd: File::SEPARATOR, **@anchors)
        rescue Landing::Dangling, SystemCallError, ArgumentError, EncodingError
          []
        end

        def glob_root(input, base)
          pattern = input.is_a?(Hash) && (input["pattern"] || input[:pattern])
          pattern.is_a?(String) ? ::Lain::Tools::Glob.walk_root(pattern, base) : nil
        end

        # Every spelling is of where the path lands, so a link that leaves is
        # judged at its target; a related directory is matched as configured.
        def held?(named)
          landings(named).any? { under_root?(_1) || @policy.in_related_tree?(_1) }
        end

        def under_root?(path) = @roots.any? { |root| path == root || path.start_with?(File.join(root, "")) }

        def spellings(root)
          expanded = File.expand_path(root)
          [expanded, File.realpath(expanded)]
        rescue SystemCallError
          [expanded]
        end
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

      # @return [String, nil] the home as configured, nil when none was
      def home = @anchors[:home]

      # @return [String, nil] the project root as configured, nil when none was
      def root = @anchors[:root]

      # What {#filter} classifies a listing row by. A readable row reaching the
      # filter is already absolute ({Middleware::WithholdSecretPaths#reading}
      # joins it to its base); an unreadable one is handed over unjoined and is
      # {MALFORMED} by name, so the root stands in for a cwd nothing reads.
      class Rows
        def initialize(policy)
          @policy = policy
          freeze
        end

        def classify(row, within: nil) = @policy.judge(row, cwd: within || File::SEPARATOR)
      end

      # A message rather than a reader handing the classifier out, so a
      # {Lain::Survey::Walk} classifies through the run's own boundary.
      #
      # @param path [String] as a caller spells it; the classifier resolves it
      # @param within [String, nil] a directory outside the project whose own
      #   directory names count as secret names, as a survey root's do
      # @return [Sensitivity::Verdict]
      def classify(path, within: nil) = @sensitivity.classify(path, within:)

      # Asked by {Middleware::RedactSecretReads}, so the mask reads the same
      # `sensitivity` table the gate does.
      #
      # @param path [String] absolute
      # @return [Boolean] whether it lies under a `related` directory
      def related?(path) = @sensitivity.related?(path)

      # @param path [String] absolute
      # @return [Boolean] whether it is a `related` directory or lies under one
      def in_related_tree?(path) = @sensitivity.in_related_tree?(path)

      # The stricter of the path as written and every spelling of where it
      # lands. The literal is asked first, so a denied name costs no syscall.
      #
      # @param path [String] as the call wrote it
      # @param cwd [String] absolute; what the tool resolves a relative path against
      # @param within [String] absolute; where directory names start counting
      #   outside the root, see {.base_of}
      # @return [Sensitivity::Verdict]
      def judge(path, cwd:, within: cwd)
        written = [@sensitivity.classify(path, within:), *from_cwd(path, cwd, within)]
        denied = written.find(&:denied?)
        return denied if denied

        strictest([*written, *landed(path, cwd, within)])
      end

      # A leased worker or a `/mode plan` spike runs in a checkout that may
      # mirror a subdirectory, so the checkout is the base and not the cwd
      # below it: the names between them count as they do below the root.
      #
      # @param context [Session, #worker_env, nil] as a middleware env carries it
      # @return [String] the checkout, or the cwd for a session without one
      def self.base_of(context) = checkout_of(context) || ::Lain::Session.cwd_of(context)

      # @param context [Session, #worker_env, nil] as a middleware env carries it
      # @return [String, nil] the checkout a leased worker or a spike runs in; nil for a session without one
      def self.checkout_of(context) = context.respond_to?(:worker_env) ? context.worker_env.checkout : nil

      # The same boundary for a spawned child, which also asks before it reads
      # outside the project, its related directories and `roots`.
      #
      # @param roots [Array<String>] absolute; the child's own trees
      # @return [Confined]
      def confined(roots:) = Confined.new(policy: self, roots: [*@anchors[:root], *roots], anchors: @anchors)

      # The path a call names, read off {PATH_FIELDS}, and nil for a call that
      # names none.
      #
      # @param effect [Lain::Effect::ToolCall]
      # @return [String, nil]
      def self.path_in(effect)
        field = PATH_FIELDS[effect.name]
        field && path(at(effect.input, field))
      end

      # Recursive rather than a single unwrap: {Effect::Approval} takes any
      # effect, including another Approval, and one level of unwrapping would
      # make a double wrap the bypass a single wrap no longer is.
      #
      # @param effect [Lain::Effect]
      # @return [Lain::Effect] the innermost effect under every Approval
      def self.unwrapped(effect) = effect.approval? ? unwrapped(effect.effect) : effect

      # @param effect [Lain::Effect] any effect at all; the question is total
      #   over the vocabulary, so no caller guards on kind first
      # @param cwd [String] absolute; the call's own base, see {Session.cwd_of}
      # @param within [String] absolute; see {.base_of}
      # @return [Boolean]
      def gates?(effect, cwd:, within: cwd)
        return false unless effect.tool_call?

        path = self.class.path_in(effect)
        !path.nil? && !judge(path, cwd:, within:).ordinary?
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
        call = self.class.unwrapped(effect)
        # {.path_in} reads `effect.name`, which a {Effect::ModelCall} has not
        # got. Without this guard the boundary raises NoMethodError on the
        # synchronous dispatch path, and the repair a crash there invites is a
        # `rescue` answering "not denied" -- this class failing OPEN to quiet an
        # exception, which is the worst shape a security control can take.
        return nil unless call.tool_call?

        path = self.class.path_in(call)
        verdict = path && judge(path, cwd:)
        return nil unless verdict&.denied?

        Denial.new(tool_use_id: call.tool_use_id, tool: call.name, path:, verdict:)
      end

      # The files a sandbox must hide. Each name is judged as the listing
      # filter judges it, and masked where it lands. So a link whose name
      # alone is sensitive (`readme.key -> README.md`) masks its landing,
      # although the filter keeps the landing's own row.
      #
      # @param files [Enumerable<String>] as listed, relative to `cwd` or absolute
      # @param cwd [String] absolute
      # @param within [String] absolute; see {.base_of}
      # @return [Array<Mask>] one per landing, in listing order
      def mask_paths(files, cwd:, within: cwd)
        files.filter_map { |file| mask(file, cwd, within) }.uniq(&:path)
      end

      # A location verdict says where a call reached, not what a file holds,
      # so a sandbox has nothing to hide there.
      #
      # @param verdict [Verdict]
      # @return [Boolean] whether a sandbox hides a file judged so
      def self.masks?(verdict) = !verdict.ordinary? && !LOCATIONS.include?(verdict.reason)

      private

      # On the resolved path, because bwrap aborts on a symlink mask target,
      # and only where the file exists, since bwrap creates a missing mask
      # target on the host. Never in a git dir, whose files git needs to run
      # at all; a linked worktree's lies outside the project.
      def mask(file, cwd, within)
        verdict = judge(file, cwd:, within:)
        return nil unless self.class.masks?(verdict)

        landing = File.realpath(file, cwd)
        git_dir?(landing) ? nil : Mask.new(path: landing.freeze, reason: verdict.reason)
      rescue SystemCallError, ArgumentError, EncodingError
        nil
      end

      def git_dir?(landing) = landing.split(File::SEPARATOR).include?(".git")

      # The classifier resolves a relative path against its own cwd, not the
      # call's, and a landing under a directory nobody may enter cannot be
      # resolved at all. So the call's spelling is also judged lexically.
      def from_cwd(path, cwd, within)
        return [] if path.start_with?(File::SEPARATOR, TILDE)

        [@sensitivity.classify(File.expand_path(path, cwd), within:)]
      rescue ArgumentError, EncodingError
        []
      end

      # Resolved as {WorkerEnv#resolve} resolves it, so the landing judged is the
      # file the tool then opens. A spelling equal to the name already judged is
      # skipped: every listing row is absolute, and most land on themselves.
      def landed(path, cwd, within)
        named = File.expand_path(path, cwd)
        judged = path.start_with?(File::SEPARATOR) ? named : nil
        Landing.of(named, cwd:, **@anchors).reject { _1 == judged }.map { @sensitivity.classify(_1, within:) }
      rescue Landing::Dangling
        [MALFORMED, *eventually(named, cwd, within)]
      rescue SystemCallError, ArgumentError, EncodingError
        [MALFORMED]
      end

      def eventually(named, cwd, within)
        Landing.eventual(named, cwd:, **@anchors).map { @sensitivity.classify(_1, within:) }
      rescue Landing::Dangling, SystemCallError, ArgumentError, EncodingError
        []
      end

      def strictest(verdicts) = verdicts.find(&:denied?) || verdicts.find { !_1.ordinary? } || verdicts.first

      # Mirrors {Sensitivity#text}, and for a reason narrower than symmetry:
      # {Tool::Input} COERCES rather than refuses, so the value this class
      # declines to judge and the value the tool then acts on are different
      # objects. `to_path` is the one coercion that turns a non-String into a
      # path somebody can open -- an Array becomes its own `inspect`, which
      # names no file -- so a Pathname declined here was read anyway, with no
      # approval asked. {Sensitivity#classify} always took both.
      def self.path(value)
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
      def self.at(input, field)
        return nil unless input.is_a?(Hash)

        input[field] || input[field.to_sym]
      end
      private_class_method :path, :at
    end
  end
end
