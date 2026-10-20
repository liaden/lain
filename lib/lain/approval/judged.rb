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
    # A judge approve is a model's answer, so it stands only where the facts
    # lain computed ({Judge::Facts#bar}) leave nothing a planted or swapped
    # file could run; past that bar the call goes to the asking rung.
    #
    # Whatever this rung hands down, it first journals one `escalation` record
    # of its own saying why, so a reader can tell a call the judge deferred
    # from one it never saw or one it faulted on.
    class Judged
      NAME = "auto"
      APPROVED = "the judge approved this call"
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
      DEFERRED = "deferred"
      BAR = "bar"
      OVERRULED = "the judge approved this, but what lain resolved the command to bars an automatic approval"
      FAULT = "fault"
      FAULT_NOTE = "the judge could not be asked (it timed out or failed)"
      UNJUDGEABLE = "unjudgeable"
      BASH = "bash"
      CALL = "%<tool>s(%<input>s)"
      NOTHING_NAMED = ::Lain::Shell::Named.new(paths: [].freeze, opaque: false)

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
        # @return [Array<String>, nil] absolute; nil when there are too many
        def self.of(path)
          pattern = path.pattern
          found = if pattern.nil? then []
                  elsif pattern.include?(RECURSIVE) then below(pattern)
                  else matches(path.resolved, pattern)
                  end
          found && [path.resolved, *found]
        rescue SystemCallError
          nil
        end

        # Globbed from the fixed directory rather than from `/`, so a directory
        # named `w[1]` is a name and not a pattern.
        def self.matches(directory, pattern)
          return unless pattern.start_with?(directory)

          relative = pattern.delete_prefix(directory).delete_prefix("/")
          bounded(Dir.glob(relative, base: directory).map { File.join(directory, _1) }, MATCHES)
        end

        # Dot entries included, because a recursive reader opens them; and
        # only what fits the bound is walked, because `find /` is a pattern too.
        def self.below(pattern)
          root, rest = pattern.split(RECURSIVE, 2)
          root = "/" if root.empty?
          entries = bounded(walk(root).first(ENTRIES + 1), ENTRIES)
          return entries if entries.nil? || rest.empty?

          inside = "**#{rest}"
          entries.select { File.fnmatch?(inside, _1.delete_prefix(root).delete_prefix("/"), WALKED) }
        end

        def self.bounded(found, limit) = found.size > limit ? nil : found

        # Through links too, because `grep -R`, `cp -L` and `tar h` follow them;
        # a directory already walked by its real path is not walked again, so a
        # link back up the tree ends.
        def self.walk(root) = Enumerator.new { |entries| descend(root, entries, Set.new) }

        def self.descend(directory, entries, walked)
          return unless File.directory?(directory) && walked.add?(File.realpath(directory))

          Dir.each_child(directory) do |name|
            entry = File.join(directory, name)
            entries << entry
            descend(entry, entries, walked)
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
        OVERRULED = "approval is auto and the judge approved this call, but what lain resolved it to bars an " \
                    "automatic approval (%<bar>s), and this session was started with --non-interactive, so it " \
                    "has no human to ask and is refused"
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
          return overruled(context.overruled_by) if context.respond_to?(:overruled_by)

          Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
        end

        private

        # Each reason inspected, because a path in one is the model's and could hold a line break.
        def overruled(bar)
          Escalation::Ruling.deny(rung: NAME, because: format(OVERRULED, bar: bar.map(&:inspect).join("; ")))
        end
      end

      # The ladder reads contexts by respond_to?, so this wrapper stays invisible to it.
      class Deferred < SimpleDelegator
        def judge_deferred? = true
      end

      # A call the judge approved and the bar stopped: not deferred by the
      # judge, so a human is told what lain found rather than that the judge doubted.
      class Overruled < SimpleDelegator
        # @return [Array<String>] why the bar stopped the call
        attr_reader :overruled_by

        def initialize(context, bar)
          super([OVERRULED, *bar].inject(context) { |noted, note| Escalation::Noted.new(noted, note) })
          @overruled_by = bar
        end
      end

      # @param judge [#call] answers `:approve`, `:deny`, `:defer` or `:fault` ({Judge})
      # @param policy [Sensitivity::Policy] what decides whether a call's path may be judged
      # @param asking [#call] the rung a call goes to when the judge does not
      #   settle it: {Escalation::Surfaces}, or {Unattended}
      # @param journal [#<<]
      # @param display [#<<] told a {Telemetry::JudgeRuled} for each call the judge approves or denies
      # @param facts [#call] `(command, cwd, tool_use_id:) -> Judge::Facts` for a bash call; none by default
      # @param request [#call] `context -> Judge::Request or nil`, what the call was made for; none by default
      def initialize(judge:, policy:, asking:, journal:, display: ::Lain::Channel::Null.instance,
                     facts: Judge::Facts::Off, request: Judge::Unrequested)
        @judge = judge
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
      # @return [Escalation::Ruling]
      def call(effect, context)
        unlooked = unlooked(effect, context)
        return unjudged(effect, context, format(UNLOOKED, why: unlooked)) if unlooked

        cause = nil
        place = place_for(effect, context)
        verdict = @judge.call(tool: effect.name, input: effect.input, place:) { |why| cause = why }
        ruled(verdict, effect, context, cause, bar: place.facts.bar)
      end

      private

      def ruled(verdict, effect, context, cause, bar:)
        case verdict
        when :approve then bar.empty? ? approved(effect) : overruled(effect, context, bar)
        when :deny then denied(effect)
        when :defer then handed_down(effect, Deferred.new(context), abstain(DEFERRED))
        else faulted(effect, context, cause)
        end
      end

      def overruled(effect, context, bar) = handed_down(effect, Overruled.new(context, bar), abstain(BAR), bar:)

      # Evidence about a call must never cost the call, so a notice that fails is lost.
      def approved(effect)
        show(effect, "approved")
        Escalation::Ruling.allow(rung: NAME, because: APPROVED)
      end

      def denied(effect)
        show(effect, "denied")
        told = @asking.respond_to?(:denied_told) ? @asking.denied_told : DENIED_TOLD
        Escalation::Ruling.deny(rung: NAME, because: DENIED, said: told)
      end

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

      # Marked faulted so the ladder suppresses an automatic allow from below,
      # as it would had the judge been a rung of its own.
      def faulted(effect, context, cause)
        handed_down(effect, Escalation::Noted.new(context, FAULT_NOTE),
                    Escalation::Ruling.fault(rung: NAME, because: FAULT), error: cause)
          .with(fault: true)
      end

      def abstain(reason) = Escalation::Ruling.abstain(rung: NAME, because: reason)

      # @return [String, nil] why the judge may not be asked; nil when it may
      def unlooked(effect, context)
        return BARRED if Escalation.barred?(context)

        named = named_in(effect, context)
        return OPAQUE if named.opaque?

        reached = named.paths.map { Reach.of(_1) }
        return TOO_MANY if reached.any?(&:nil?)

        unweighable(effect, reached.flatten, context)
      end

      def unweighable(effect, reached, context)
        path = [*named_by_field(effect), *reached].find { !verdict_on(_1, context).oracle_approvable? }
        path && format(UNWEIGHABLE, path:)
      end

      # A path in the requester's own checkout is where it works, not outside it.
      def place_for(effect, context)
        root = own_tree(context) || @policy.root || ::Lain::Sensitivity::Policy.base_of(context)
        cwd = ::Lain::Session.cwd_of(context)
        Judge::Place.new(root:, cwd:, requester: Queue.requester_for(context),
                         outside: outside(effect, context, cwd, [root, ::Lain::Sensitivity::Policy.base_of(context)]),
                         facts: facts_for(effect, context), request: @request.call(context),
                         human_checkout: (@policy.root unless root == @policy.root))
      end

      # A leased child or a plan-scope spike works in its own checkout, so the
      # judge is told that checkout as the project root.
      def own_tree(context) = ::Lain::Sensitivity::Policy.checkout_of(context)

      # The human's checkout is read-only to a session in its own tree, as its
      # confined policy keeps the project root, so only a write there is outside.
      def outside(effect, context, cwd, held)
        readable = [*held, *@policy.root]
        named_paths(effect, context, cwd).reject { |path, written| within?(written ? held : readable, path) }
                                         .map(&:first).uniq
      end

      def facts_for(effect, context)
        command = command_in(effect.input)
        cwd = command_cwd(effect, context)
        return Judge::Facts::NONE unless effect.name == BASH && command.is_a?(String) && cwd

        @facts.call(command, cwd, tool_use_id: effect.tool_use_id)
      end

      # @return [Array<Array(String, Boolean)>] each path, and whether the call writes it
      def named_paths(effect, context, cwd)
        field = named_by_field(effect)
        base = field && Queue.resolved(field, cwd)
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
        roots.any? { path == _1 || path.start_with?(File.join(_1, "")) } || @policy.in_related_tree?(path)
      end

      def named_by_field(effect) = ::Lain::Sensitivity::Policy.path_in(effect)

      # A command's cwd says nothing about the files it reads.
      def named_in(effect, context)
        return NOTHING_NAMED unless effect.name == BASH

        command = command_in(effect.input)
        cwd = command_cwd(effect, context)
        return ::Lain::Shell::Named::UNREADABLE unless command.is_a?(String) && cwd

        ::Lain::Shell::Named.of(command, cwd:, home: @policy.home)
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

      def handed_down(effect, context, why, error: nil, bar: nil)
        record(why, effect, context, error, bar)
        @asking.call(effect, context)
      end

      def record(ruling, effect, context, error, bar)
        ::Lain::Telemetry::Escalation.write(@journal, ruling, effect, context, error:, bar:)
      end
    end
  end
end
