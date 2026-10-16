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
    # Whatever this rung hands down, it first journals one `escalation` record
    # of its own saying why, so a reader can tell a call the judge deferred
    # from one it never saw or one it faulted on.
    class Judged
      NAME = "auto"
      APPROVED = "the judge approved this call"
      DENIED = "the judge refused this call"
      DEFERRED = "deferred"
      FAULT = "fault"
      UNJUDGEABLE = "unjudgeable"
      BASH = "bash"
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
        TOLD = "this command's automatically approved output held a credential, so only a human may approve " \
               "it, and this session was started with --non-interactive, so no human can -- retrying will " \
               "fail the same way"

        def initialize = freeze

        def name = NAME

        def call(_effect, context)
          return Escalation::Ruling.deny(rung: NAME, because: BARRED, final: true, told: TOLD) \
            if Escalation.barred?(context)

          Escalation::Ruling.deny(rung: NAME, because: BECAUSE)
        end
      end

      # @param judge [#call] answers `:approve`, `:deny`, `:defer` or `:fault` ({Judge})
      # @param policy [Sensitivity::Policy] what decides whether a call's path may be judged
      # @param asking [#call] the rung a call goes to when the judge does not
      #   settle it: {Escalation::Surfaces}, or {Unattended}
      # @param journal [#record]
      def initialize(judge:, policy:, asking:, journal:)
        @judge = judge
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
        return handed_down(effect, context, abstain(UNJUDGEABLE)) unless judgeable?(effect, context)

        cause = nil
        verdict = @judge.call(requester: Queue.requester_for(context), tool: effect.name, input: effect.input) do |why|
          cause = why
        end
        ruled(verdict, effect, context, cause)
      end

      private

      def ruled(verdict, effect, context, cause)
        case verdict
        when :approve then Escalation::Ruling.allow(rung: NAME, because: APPROVED)
        when :deny then Escalation::Ruling.deny(rung: NAME, because: DENIED)
        when :defer then handed_down(effect, context, abstain(DEFERRED))
        else faulted(effect, context, cause)
        end
      end

      # Marked faulted so the ladder suppresses an automatic allow from below,
      # as it would had the judge been a rung of its own.
      def faulted(effect, context, cause)
        handed_down(effect, context, Escalation::Ruling.fault(rung: NAME, because: FAULT), error: cause)
          .with(fault: true)
      end

      def abstain(reason) = Escalation::Ruling.abstain(rung: NAME, because: reason)

      def judgeable?(effect, context)
        return false if Escalation.barred?(context)

        named = named_in(effect, context)
        reached = named.paths.map { Reach.of(_1) }
        !named.opaque? && reached.none?(&:nil?) && [*named_by_field(effect), *reached.flatten].all? do |path|
          verdict_on(path, context).oracle_approvable?
        end
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

      def handed_down(effect, context, why, error: nil)
        record(why, effect, error)
        @asking.call(effect, context)
      end

      # Evidence about a call must never cost the call.
      def record(ruling, effect, error)
        @journal.record({ "type" => Escalation::TYPE, "tool" => effect.name, "tool_use_id" => effect.tool_use_id,
                          "error" => error }.compact.merge(ruling.record))
      rescue StandardError
        nil
      end
    end
  end
end
