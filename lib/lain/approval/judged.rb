# frozen_string_literal: true

module Lain
  module Approval
    # The judge-first rung of `auto` approval: a model {Judge} decides the
    # calls it can, and the rest go to the asking rung below it.
    #
    # Tier 0 comes first and asks no model. A call barred from automatic
    # approval, or one whose path the classifier gated for what it is (a
    # credential, a name, an operator's rule, a protected or malformed path),
    # never reaches the judge, because a model approve could not apply to it.
    # A `bash` call is held to every path its command names ({Shell::Named}),
    # and one whose paths cannot be named never reaches the judge either.
    #
    # Whether the judge may weigh a call is decided once, before it is paid
    # for ({Judgement}): past the facts lain computed ({Judge::Facts#bar}), a
    # planted or swapped file could run, so such a call goes to the asking
    # rung unasked.
    #
    # Whatever this rung hands down, it first journals one `escalation` record
    # of its own saying why, so a reader can tell a call the judge deferred
    # from one it never saw or one it faulted on.
    #
    # Its {DenialBreaker} decides what a judge's deny does: applied, handed to
    # the asking rung (`escalate_only`), or counted until the judge is no
    # longer asked about that requester's calls (`breaker`).
    class Judged
      NAME = "auto"
      APPROVED = "the judge approved this call"
      REMEMBERED = "the judge approved this exact call earlier this session"
      DENIED = "the judge refused this call"
      # Not final: the judge is a model, and a human who switches approval can still say yes.
      DENIED_TOLD = "the judge refused this call; that is a model's answer, not a human's, and a human can still " \
                    "approve it by switching approval to ask, so tell the user what you needed it for rather than " \
                    "re-sending it"
      UNLOOKED = "the judge did not look: %<why>s"
      OPAQUE = "its paths cannot be named"
      BARRED = "this command is barred from automatic approval"
      TOO_MANY = "it reaches more files than the judge weighs"
      UNWEIGHABLE = "%<path>s is not a path it may weigh"
      GIT_STORE = "it reads the repository's object store, which the judge cannot weigh"
      BELOW_TOP = "it is a git write run below its checkout's top level, so the judge cannot see which tree it writes"
      DEFERRED = "deferred"
      DEFERRAL_NOTE = "the judge deferred this"
      ESCALATED = "the judge refused this call, and a judge's refusal goes to a human"
      WOULD_DENY_NOTE = "the judge would have refused this"
      BROKEN = "the judge refused too many of this requester's calls to be asked again"
      BROKEN_NOTE = "the judge is no longer asked about this requester: it refused too many of its calls"
      BAR = "bar"
      RESOLVED_BAR = "what lain resolved the command to bars an automatic approval, so the judge was not asked"
      FAULT = "fault"
      FAULT_NOTE = "the judge could not be asked (it timed out or failed)"
      UNJUDGEABLE = "unjudgeable"
      BASH = "bash"
      CALL = "%<tool>s(%<input>s)"
      NOTHING_NAMED = ::Lain::Shell::Named.new(paths: [].freeze, opaque: false)
      UNWEIGHED = { opaque: OPAQUE, barred: BARRED, below_top: BELOW_TOP, git_store: GIT_STORE,
                    too_many: TOO_MANY }.freeze

      # The files a named path stands for when the judge would be asked: the
      # path, every match of its glob, and every entry below a recursive
      # reader's root. A judge that has not weighed every file a call reads is
      # not judging the call, so past a bound the answer is nil, never a sample.
      module Reach
        MATCHES = 64
        # A checkout's `.git` alone passes this. Walking and judging a tree just
        # under it measured about 300ms, which is what a call pays before the
        # judge is even asked; further costs more than the park it would save.
        ENTRIES = 2000
        RECURSIVE = "/**"
        WALKED = File::FNM_PATHNAME | File::FNM_DOTMATCH

        # @param path [Shell::Named::Path]
        # @param facts [FileFacts::Live, FileFacts::Recorded] what a match or an entry is read off
        # @return [Array<String>, nil] absolute; nil when there are too many
        def self.of(path, facts: FileFacts::LIVE)
          pattern = path.pattern
          found = if pattern.nil? then []
                  elsif pattern.include?(RECURSIVE) then below(pattern, facts)
                  else matches(path.resolved, pattern, facts)
                  end
          found && [path.resolved, *found]
        rescue SystemCallError
          nil
        end

        # Globbed from the fixed directory rather than from `/`, so a directory
        # named `w[1]` is a name and not a pattern.
        def self.matches(directory, pattern, facts)
          return unless pattern.start_with?(directory)

          relative = pattern.delete_prefix(directory).delete_prefix("/")
          bounded(facts.glob(relative, base: directory).map { File.join(directory, _1) }, MATCHES)
        end

        # Dot entries included, because a recursive reader opens them; and
        # only what fits the bound is walked, because `find /` is a pattern too.
        def self.below(pattern, facts)
          root, rest = pattern.split(RECURSIVE, 2)
          root = "/" if root.empty?
          entries = bounded(walk(root, facts).first(ENTRIES + 1), ENTRIES)
          return entries if entries.nil? || rest.empty?

          inside = "**#{rest}"
          entries.select { File.fnmatch?(inside, _1.delete_prefix(root).delete_prefix("/"), WALKED) }
        end

        def self.bounded(found, limit) = found.size > limit ? nil : found

        # Through links too, because `grep -R`, `cp -L` and `tar h` follow them;
        # a directory already walked by its real path is not walked again, so a
        # link back up the tree ends.
        def self.walk(root, facts) = Enumerator.new { |entries| descend(root, entries, Set.new, facts) }

        def self.descend(directory, entries, walked, facts)
          return unless facts.directory?(directory) && walked.add?(facts.realpath(directory))

          facts.each_child(directory) do |name|
            entry = File.join(directory, name)
            entries << entry
            descend(entry, entries, walked, facts)
          end
        end
        private_class_method :matches, :below, :bounded, :walk, :descend
      end

      # The asking rung of a session nobody is attached to. A barred call is
      # refused finally, on {Escalation::Remainder}'s terms: no approval at this
      # level lifts it, so the model is told retrying will not help.
      class Unattended
        BECAUSE = "approval is auto and this session was started with --non-interactive, so a call the judge " \
                  "did not approve, or was not allowed to judge, has no human to ask and is refused"
        BARRED = "approval is auto, and this command is barred from automatic approval"
        RESOLVED_BAR = "approval is auto, and what lain resolved this call to bars an automatic approval " \
                       "(%<bar>s), and this session was started with --non-interactive, so it has no human to ask " \
                       "and is refused"
        TOLD = "this command's automatically approved output held a credential, so only a human may approve " \
               "it, and this session was started with --non-interactive, so no human can -- retrying will " \
               "fail the same way"

        def initialize = freeze

        def name = NAME

        # What the model is told of a judge deny, read by the rung above: the
        # session's own refusal already says nobody can approve it.
        def denied_told = DENIED

        def call(_effect, context)
          return Escalation::Ruling.deny(rung: NAME, because: BARRED, final: true, told: TOLD, liftable: true) \
            if Escalation.barred?(context)
          return resolved_bar(context.barred_by) if context.respond_to?(:barred_by)

          Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
        end

        private

        # Each reason inspected, because a path in one is the model's and could hold a line break.
        def resolved_bar(bar)
          Escalation::Ruling.deny(rung: NAME, because: format(RESOLVED_BAR, bar: bar.map(&:inspect).join("; ")))
        end
      end

      # The ladder reads contexts by respond_to?, so this wrapper stays invisible to it.
      class Deferred < SimpleDelegator
        def parked_because
          inner = __getobj__
          [*(inner.parked_because if inner.respond_to?(:parked_because)), Parked::Queue::Reason.own(DEFERRAL_NOTE)]
        end
      end

      # A call the bar stopped before the judge was asked, so a human is told
      # what lain found rather than that the judge doubted.
      class ResolvedBar < SimpleDelegator
        # @return [Array<String>] why the bar stopped the call
        attr_reader :barred_by

        def initialize(context, bar)
          super([RESOLVED_BAR, *bar].inject(context) { |noted, note| Escalation::Noted.new(noted, note) })
          @barred_by = bar
        end
      end

      # The facts the judge is told, followed by the call's {Disclosure} in the
      # words its parked row shows, so the judge and the human weigh one account.
      class Disclosed < SimpleDelegator
        HEADER = "disclosure (computed by lain, not by the model):"

        # @param facts [Judge::Facts]
        # @param notes [Array<Parked::Queue::Reason>]
        def initialize(facts, notes)
          super(facts)
          @notes = notes
        end

        # @return [String]
        def to_s = "#{__getobj__}\n#{HEADER}\n#{@notes.join("\n")}\n"
      end

      # A ruling that also names, by digest, what the judge read, so the ladder's
      # record of it carries the same fields as the records this rung writes itself.
      class Read < Escalation::Ruling
        def initialize(digests: {}, **rest)
          @digests = digests.freeze
          super(**rest)
        end

        def record = super.merge(@digests.compact.transform_keys(&:to_s)).freeze

        # The ladder rewrites rulings with `with`, which would build a plain Ruling and drop the digests.
        def with(**changes) = changes.empty? ? self : self.class.new(digests: @digests, **to_h, **changes)
      end

      # @param judge [#call] answers `:approve`, `:deny`, `:defer` or `:fault` ({Judge})
      # @param policy [Sensitivity::Policy] what decides whether a call's path may be judged
      # @param asking [#call] the rung a call goes to when the judge does not
      #   settle it: {Escalation::Surfaces}, or {Unattended}
      # @param journal [#<<]
      # @param display [#<<] told a {Telemetry::JudgeRuled} for each call the judge approves or denies
      # @param facts [#call] `(command, cwd, tool_use_id:, parsed:) -> Judge::Facts` for a bash call; none by default
      # @param request [#call] `context -> Judge::Request or nil`, what the call was made for; none by default
      # @param denials [DenialBreaker, DenialBreaker::Unbroken] what a judge's deny does; applied by default
      # @param masks [Judgement::Masking, Judgement::Unmasked] the sandbox a call the judge approves runs under
      # @param memo [JudgeMemo, JudgeMemo::Off] the approvals an exact repeat is settled by; none by default
      def initialize(judge:, policy:, asking:, journal:, display: ::Lain::Channel::Null.instance,
                     facts: Judge::Facts::Off, request: Judge::Unrequested, denials: DenialBreaker::Off,
                     masks: Judgement::Unmasked, memo: JudgeMemo.off)
        @judge = judge
        @memo = memo
        @masks = masks
        @denials = denials
        @facts = facts
        @request = request
        @display = display
        @policy = policy
        @asking = asking
        @journal = journal
        freeze
      end

      def name = NAME

      # @param effect [Effect::ToolCall]
      # @param context [Object, nil] as {Middleware::Gate} threads it through
      # @return [Escalation::Ruling, Ladder::Outcome] an outcome when the judge
      #   faulted, carrying that fault beside the asking rung's ruling
      def call(effect, context)
        case judgement_of(effect, context)
        in Judgement::Unweighable(reason: :barred, details: [_, *] => bar) then resolved_bar(effect, context, bar)
        in Judgement::Unweighable => unweighed then unjudged(effect, context, format(UNLOOKED, why: why(unweighed)))
        in Judgement::Weighable(facts:) then weigh(effect, context, facts)
        end
      end

      private

      def judgement_of(effect, context)
        Judgement.of(effect, bounds: held_to(context), named: named_in(effect, context),
                             facts: -> { facts_for(effect, context) }, masks: @masks,
                             verdict: ->(path) { verdict_on(path, context) }, barred: Escalation.barred?(context),
                             env: ::Lain::Session.worker_env_of(context).env)
      end

      def why(unweighed)
        UNWEIGHED.fetch(unweighed.reason) { format(UNWEIGHABLE, path: unweighed.details.first) }
      end

      def weigh(effect, context, facts)
        return noted(effect, context, BROKEN, BROKEN_NOTE) if @denials.tripped?(requester_of(context))

        place = place_for(effect, context, facts)
        key = JudgeMemo.key(tool: effect.name, input: effect.input, place:)
        return remembered(effect, context) if @memo.approved?(key)

        verdict, cause, read = asked(effect, place)
        @memo.approve(key) if verdict == :approve
        ruled(verdict, effect, context, cause, read:)
      end

      # @return [Array(Symbol, String, Hash)] the verdict, why it faulted, and the digests of what was read
      def asked(effect, place)
        cause = nil
        prompt = prompt_of(effect, place)
        verdict = @judge.call(tool: effect.name, input: effect.input, place:, **{ prompt: }.compact) do |why|
          cause = why
        end
        [verdict, cause, digests_of(prompt, place)]
      end

      def remembered(effect, context)
        counted(:approve, context)
        show(effect, "remembered")
        Escalation::Ruling.allow(rung: NAME, because: REMEMBERED)
      end

      def ruled(verdict, effect, context, cause, read:)
        counted(verdict, context)
        case verdict
        when :approve then approved(effect, read)
        when :deny then @denials.maps_deny? ? escalated(effect, context, read) : denied(effect, read)
        when :defer then handed_down(effect, Deferred.new(context), abstain(DEFERRED), read:)
        else faulted(effect, context, cause, read)
        end
      end

      def counted(verdict, context)
        @denials.approved(requester_of(context)) if verdict == :approve
        @denials.denied(requester_of(context)) if verdict == :deny
      end

      def requester_of(context) = Parked::Queue.identity_for(context).name

      def escalated(effect, context, read)
        show(effect, "denied")
        noted(effect, context, ESCALATED, WOULD_DENY_NOTE, read)
      end

      # Lain's own words on the parked row, as a deferral's are.
      def noted(effect, context, reason, note, read = {})
        handed_down(effect, Escalation::Noted.new(context, Parked::Queue::Reason.own(note)), abstain(reason), read:)
      end

      def resolved_bar(effect, context, bar)
        handed_down(effect, ResolvedBar.new(context, bar), abstain(BAR), bar:)
      end

      # Nil digests for what the call was not told, never the digest of an empty string; none at all
      # for a judge that cannot show its prompt.
      def digests_of(prompt, place)
        return {} unless prompt

        { prompt_digest: ::Lain::Canonical.digest(prompt),
          facts_digest: digest_of(place.facts.to_s), request_digest: digest_of(place.request.to_s) }
      end

      # Built once, so the digest is of the text the judge is sent.
      def prompt_of(effect, place)
        @judge.prompt(tool: effect.name, input: effect.input, place:) if @judge.respond_to?(:prompt)
      end

      def digest_of(text) = (::Lain::Canonical.digest(text) unless text.empty?)

      def approved(effect, read)
        show(effect, "approved")
        Read.allow(rung: NAME, because: APPROVED, digests: read)
      end

      def denied(effect, read)
        show(effect, "denied")
        told = @asking.respond_to?(:denied_told) ? @asking.denied_told : DENIED_TOLD
        Read.deny(rung: NAME, because: DENIED, said: told, digests: read)
      end

      # Evidence about a call must never cost the call, so a notice that fails is lost.
      def show(effect, verdict)
        @display << Telemetry::JudgeRuled.new(call: format(CALL, tool: effect.name, input: effect.input.inspect),
                                              verdict:)
      rescue StandardError
        nil
      end

      def unjudged(effect, context, note)
        handed_down(effect, Escalation::Noted.new(context, note),
                    Escalation::Ruling.abstain(rung: NAME, because: UNJUDGEABLE, note:))
      end

      # The fault travels beside the asking rung's answer, so the ladder's edge
      # suppresses an automatic allow from below, as it would had the judge
      # been a rung of its own, and a human's allow still stands.
      def faulted(effect, context, cause, read)
        fault = Escalation::Ruling.fault(rung: NAME, because: FAULT)
        asked = handed_down(effect, Escalation::Noted.new(context, FAULT_NOTE), fault, error: cause, read:)
        Ladder::Outcome.new(decision: asked, by: asked.rung, faults: [fault], why_not: nil)
      end

      def abstain(reason) = Escalation::Ruling.abstain(rung: NAME, because: reason)

      # A path in the requester's own checkout is where it works, not outside it.
      def place_for(effect, context, facts)
        root = own_tree(context) || @policy.root || ::Lain::Sensitivity::Policy.base_of(context)
        cwd = ::Lain::Session.cwd_of(context)
        Judge::Place.new(root:, cwd:, requester: requester_of(context),
                         outside: outside(effect, context, cwd),
                         facts: disclosed(facts, context), request: @request.call(context),
                         human_checkout: (@policy.root unless root == @policy.root),
                         read_roots: read_roots(context), classified: classified(effect, context, cwd))
      end

      def disclosed(facts, context)
        notes = Disclosure.in(context).notes
        notes.empty? ? facts : Disclosed.new(facts, notes)
      end

      def read_roots(context) = held_to(context).bounds.readable

      def classified(effect, context, cwd)
        named_paths(effect, context, cwd).map(&:first).uniq.to_h { [_1, verdict_on(_1, context)] }
      end

      # A leased child or a plan-scope spike works in its own checkout, so the
      # judge is told that checkout as the project root.
      def own_tree(context) = ::Lain::Sensitivity::Policy.checkout_of(context)

      # Judged by the requester's own bounds, where each path lands, as the
      # gate judges it: the human's checkout and the session's read roots are
      # read-only to a session in its own tree, so only a write there is outside.
      def outside(effect, context, cwd)
        held = held_to(context)
        named_paths(effect, context, cwd).select { |path, writes| outside_of?(held, path, writes, cwd) }
                                         .map(&:first).uniq
      end

      def held_to(context) = ::Lain::Sensitivity::Policy.confined_at(@policy, context)

      def outside_of?(held, path, writes, cwd) = writes ? held.writes_outside?(path, cwd:) : held.outside?(path, cwd:)

      def facts_for(effect, context)
        command = command_in(effect.input)
        cwd = command_cwd(effect, context)
        return Judge::Facts::NONE unless effect.name == BASH && command.is_a?(String) && cwd

        @facts.call(command, cwd, tool_use_id: effect.tool_use_id,
                                  parsed: ::Lain::Middleware::ParsedCommand.carried(command, context))
      end

      # @return [Array<Array(String, Boolean)>] each path, and whether the call writes it
      def named_paths(effect, context, cwd)
        field = named_by_field(effect)
        base = field && ::Lain::Shell::Named.resolved(field, cwd)
        runs_in = command_cwd(effect, context)
        named = named_in(effect, context).paths.reject { guessed_here?(_1, runs_in) }
        [[base, writes_field?(effect)], [glob_root(effect, base || cwd), false],
         *named.map { [_1.resolved, _1.written] }].reject { _1.first.nil? }
      end

      # A path-taking tool not known to only read counts as writing, so a new one fails closed; bash's field is its cwd.
      def writes_field?(effect) = effect.name != BASH && !::Lain::Sensitivity::Policy::READ_TOOLS.include?(effect.name)

      # A cut of an unknown program's flag that lands under the cwd, like `ame`
      # from `-name`, is almost never a file; an absolute one may well be.
      def guessed_here?(path, runs_in) = path.guess && within?([runs_in], path.resolved)

      def glob_root(effect, base)
        pattern = effect.input.is_a?(Hash) && (effect.input["pattern"] || effect.input[:pattern])
        pattern.is_a?(String) && effect.name == "glob" ? ::Lain::Tools::Glob.walk_root(pattern, base) : nil
      end

      def within?(roots, path)
        roots.any? { ::Lain::Landing.under?(path, _1) } || @policy.in_related_tree?(path)
      end

      def named_by_field(effect) = ::Lain::Sensitivity::Policy.path_in(effect)

      # A command's cwd says nothing about the files it reads.
      def named_in(effect, context)
        return NOTHING_NAMED unless effect.name == BASH

        ::Lain::Middleware::ParsedCommand.named_in(effect, context, home: @policy.home)
      end

      def command_in(input) = input.is_a?(Hash) ? input["command"] || input[:command] : nil

      def command_cwd(effect, context)
        File.expand_path(named_by_field(effect) || ".", ::Lain::Session.cwd_of(context))
      rescue ArgumentError
        nil
      end

      def verdict_on(path, context)
        @policy.judge(path, cwd: ::Lain::Session.cwd_of(context), within: ::Lain::Sensitivity::Policy.base_of(context))
      end

      def handed_down(effect, context, why, error: nil, bar: nil, read: {})
        record(why, effect, context, { error:, bar: }.merge(read))
        @asking.call(effect, context)
      end

      def record(ruling, effect, context, extra)
        ::Lain::Telemetry::Escalation.write(@journal, ruling, effect, context, **extra)
      end
    end
  end
end
