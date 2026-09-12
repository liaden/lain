# frozen_string_literal: true

module Lain
  module Middleware
    # Holds a written test to the project's test layout in the tool phase,
    # before the file exists: a `write_file` against its whole content, and an
    # `edit_file` against the path rules alone, since the content an edit
    # leaves is not in hand until it has run.
    #
    # {TestLayout::Guard} is pure and answers for every rule; the policy is
    # here. A test describing a class nothing defines yet is let through with a
    # note, because a test is legitimately written before its class, and the
    # check a change lands through refuses one whose class never came. Every
    # other refusal refuses the write and writes nothing.
    #
    # `bash` writing a test through a redirect is not held here, as `cat` is
    # not held by {RedactSecretReads}: the land-time check reads the files in
    # the diff, whatever wrote them.
    class GuardTestLayout < Base
      # tool name => the input field holding the file's whole content, or nil
      # where the content is not in hand. Exact membership, for
      # {RefuseSecretWrites::GUARDED_TOOLS}' reason.
      GUARDED_TOOLS = { "write_file" => "content", "edit_file" => nil }.freeze

      # The one refusing rule admitted at write time.
      DEFERRED = :no_source

      # The key a guarded tool names its file under, as
      # {Sensitivity::Policy::PATH_FIELDS} says for both.
      PATH_INPUT = "path"

      # The session's layout, a guard per root it is held at, and whether the
      # run has said yet that it declares none. One per run and shared by the
      # parent's stack and every child's, so the absence is said once however
      # many guards exist.
      class Run
        # How many checkouts' guards a run keeps, beyond the project's own.
        # Each indexes a whole tree, and a run leases many checkouts over its
        # life; a guard let go is rebuilt on its next write, so the bound
        # costs at most a re-index.
        CHECKOUTS = 16

        attr_reader :layout, :root

        # For a board built with no project behind it: no layout, held at the
        # filesystem root, so every check is unguarded.
        def self.undeclared = new(layout: TestLayout::None, root: File::SEPARATOR)

        # @param layout [TestLayout] the project's, read once for the session
        # @param root [String] the project root the layout is relative to
        def initialize(layout:, root:)
          @layout = layout
          @root = root
          @guards = {}
          @absence_noted = false
        end

        def guard = guard_for(root)

        # One guard per root, since each guard's constant index is that tree's
        # cache, and at most {CHECKOUTS} of them beside the project's. The
        # oldest checkout is let go first; nothing yields between the lookup
        # and the store, so two fibers cannot interleave here.
        def guard_for(checkout)
          @guards.fetch(checkout) { remember(checkout, TestLayout::Guard.new(layout:, root: checkout)) }
        end

        # The roots a child's writes are held at: the project's, and the
        # checkout its lease cut when it has one. The layout is repo-relative,
        # so a checkout maps onto the project path for path, and is checked
        # against its own sources. An unleased child is held where its parent
        # is, whatever directory it stands in.
        def roots_for(worker_env) = [root, *worker_env.checkout]

        # The flag is set before the write, and nothing yields between the
        # read and the set, so two fibers cannot both record it.
        def note_absence(journal)
          return if @absence_noted

          @absence_noted = true
          journal << Telemetry::TestLayoutAbsent.new(root: guard.root)
        end

        private

        def remember(checkout, guard)
          kept = @guards.keys - [root]
          @guards.delete(kept.first) if checkout != root && kept.size >= CHECKOUTS
          @guards[checkout] = guard
        end
      end

      attr_reader :run, :roots

      # @param run [Run] the session's one, shared with every other guard in it
      # @param roots [Array<String>] where this agent's writes may land: the
      #   project root, and a child's own checkout when it has one
      # @param journal [#<<] where a refusal, a deferral and the absence land
      def initialize(run:, roots: [run.root], journal: Channel::Null.instance)
        @run = run
        @roots = roots.dup.freeze
        # Both spellings, as {TestLayout::Guard} takes both: a tool may hand
        # over the path it was given or the one the filesystem resolved.
        @spelled = @roots.to_h { |root| [root, [File.expand_path(root), File.realpath(root)].uniq.freeze] }.freeze
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        return downstream(env, &app) unless GUARDED_TOOLS.key?(effect.name)

        verdict = verdict_for(effect, env.fetch(:context) || Session::Null.instance)
        return refuse(env, effect, verdict) if refusing?(verdict)

        admitted(downstream(env, &app), effect, verdict)
      rescue Unjudged => e
        unjudged(env, effect, e.cause)
      end

      private

      # A failure of the JUDGING, and only of it: {#verdict_for} raises it in
      # place of whatever broke. A tool the guard admitted fails as itself,
      # raise included, never relabelled a layout failure -- and it cannot
      # raise this, which is what keeps the rescue in {#call} that narrow.
      class Unjudged < Lain::Error; end
      private_constant :Unjudged

      # The class only, for {RedactSecretReads#guarded}'s reason: a message can
      # quote the input, and here the input is the file's whole content.
      def unjudged(env, effect, error)
        env.merge(result: Tool::Result.error("#{effect.name} could not be checked against the test layout " \
                                             "(#{error.class}); nothing was written."))
      end

      # A write the gate denied, or the tool failed, went nowhere, so it leaves
      # no record that a test was let through.
      def admitted(carried, effect, verdict)
        record(effect, verdict) unless carried.fetch(:result).error?
        carried
      end

      # Resolved against the WRITING session's directory, as the tool itself
      # resolves it, so the guard judges the file the write would touch -- at
      # whichever held root the file lies in.
      def verdict_for(effect, session)
        path = Session.normalize_path(field(effect.input, PATH_INPUT), cwd: session.worker_env.cwd)
        guard = guard_at(path)
        content = GUARDED_TOOLS.fetch(effect.name)
        content ? guard.check(path, field(effect.input, content).to_s) : guard.check_path(path)
      rescue StandardError
        raise Unjudged
      end

      # The deepest held root the path lies in. None holds it, and the
      # project's guard reads it as outside the tree, which it is.
      def guard_at(path)
        @run.guard_for(@roots.select { |root| holds?(root, path) }.max_by(&:length) || @run.root)
      end

      def holds?(root, path) = @spelled.fetch(root).any? { |dir| path.start_with?(File.join(dir, "")) }

      def refusing?(verdict) = verdict.refused? && verdict.rule != DEFERRED

      def record(effect, verdict)
        return @run.note_absence(@journal) if verdict.rule == :no_layout
        return unless verdict.refused?

        @journal << Telemetry::TestLayoutDeferred.new(tool_use_id: effect.tool_use_id, tool: effect.name,
                                                      path: verdict.path, reason: verdict.reason)
      end

      # The downstream never runs, so the tool never writes: the refusal is
      # the whole result, and an error one, so the model cannot read it as done.
      def refuse(env, effect, verdict)
        @journal << Telemetry::TestLayoutRefused.new(tool_use_id: effect.tool_use_id, tool: effect.name,
                                                     path: verdict.path, rule: verdict.rule,
                                                     expected: verdict.expected, reason: verdict.reason)
        env.merge(result: Tool::Result.error("#{effect.name} refused by the test layout: #{verdict.reason}." \
                                             "#{instead(verdict)} Nothing was written."))
      end

      # The path is named once: the guard's own reason usually says already
      # where the test belongs.
      def instead(verdict)
        return "" if verdict.expected.nil? || verdict.reason.include?(verdict.expected)

        " Write it at #{verdict.expected} instead."
      end

      # Both spellings, {Sensitivity::Policy#at}'s rule: a parsed payload has
      # String keys and an in-process caller writes Symbols.
      def field(input, name) = input[name] || input[name.to_sym]
    end
  end
end
