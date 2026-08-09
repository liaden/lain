# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "mixlib/shellout"
require "stringio"

module Lain
  module CLI
    # `lain review <pull-request|branch>`: resolve a source, open a round on it,
    # and hand back what the surface drew.
    #
    # Returns Strings; only the frontend prints ({CLI::EpicQueue}'s precedent
    # and CLAUDE.md's Output discipline). Every refusal below is a
    # {Lain::Error}, so `Boundary#render` in the exe turns each into a
    # `Thor::Error` -- message to stderr, nonzero exit, no backtrace.
    #
    # == A target is never a command name HERE, and is at the exe
    #
    # Nothing below treats a target as anything but a ref: `present("help")`
    # reviews a branch called `help`, and there is a spec. Thor is the half that
    # reserves `help` and `tree` as command names, so `lain review help` prints
    # the help screen and `lain review open help` is the way through -- named in
    # the exe's own `desc`, because that is where a human meets it and this
    # class cannot fix it from here.
    #
    # == `Lain::Review` is spelled out, everywhere
    #
    # A bare `Review` inside `Lain::CLI` resolves to THIS class, so
    # `Review::Bounds` would be a NameError rather than the guard. Worse, every
    # such name is read from a METHOD body and never from the class body:
    # `lain.rb` loads `lain/cli` BEFORE `lain/review` and `lain/forge`, so a
    # constant here naming either would be a load-time NameError. That is why
    # {#default_scope} and {Target#default_base} are methods rather than the
    # constants they would otherwise obviously be -- {Source::LocalBranch#git}'s
    # reason, one directory over.
    #
    # == Where the size guard is called, and what moving it cost
    #
    # Not here (T31c). `bounds:` is still this command's to inject, but the
    # ceiling is enforced by {Review::Session#present} -- the one place every
    # surface is reached through -- so a re-callable `present`, an editor
    # sidebar toggling scope and `/review` inside a chat are all bounded by that
    # single caller instead of by whichever command remembered to ask. This
    # command's own doc wrote that follow-up while the guard was still here.
    #
    # The move cost one property, named rather than left to be discovered: the
    # ceiling now runs AFTER `Session.open` has journaled the round, so a
    # refused review leaves a `changeset_opened` on record where it used to
    # leave nothing. What a human is protected from is unchanged -- the surface
    # is never told, so nothing is drawn, and the refusal reaches stderr in the
    # same words with the same nonzero exit. The alternative was to keep a check
    # here as well, and two places enforcing one ceiling is exactly what this
    # was.
    #
    # == The editor surface, and why this command does not build one
    #
    # `surface:` is injected, and the default is {Review::Surface::Text} over a
    # buffer this object owns and returns. A caller holding a live editor hands
    # {Review::Surface::Neovim} in instead, and its answer -- a refusal
    # sentence, or nothing -- comes back in place of a rendering.
    #
    # This command will not GUESS at one from `$NVIM`. A one-shot process can
    # attach to the nvim that spawned it, but the lua half guards every entry
    # point on `_G.__lain`, which only `lain up` injects -- so drawing into a
    # plain nvim would report a success that drew nothing, which is the exact
    # shape of failure this whole chunk is written against. Attachment here
    # means "a caller handed a surface in".
    #
    # The gesture leg back from the editor is deliberately absent for the same
    # reason. It needs an adapter answering `open(line, generation:)`,
    # `mark(line, state, generation:)` and `ask(anchor_id, question)` -- a
    # SEPARATE object from {Review::Surface::Neovim}, because the port already
    # owns `mark` there for the opposite direction -- and the only thing that
    # binds one ({CLI::HumanReplies#bind_changeset_review}) lives in the chat
    # process, not in a one-shot command. Shipping an adapter nothing can bind
    # would be the same inert object as a guard nobody calls.
    class Review
      # A bare number that is also a branch name. Refused rather than resolved
      # by a precedence rule nobody chose: both readings are ordinary, they
      # review different things, and the two unambiguous spellings are cheap.
      class Ambiguous < Error; end

      # `--base` against a pull request. Held apart from {Ambiguous} because the
      # remedy is nothing alike: this one is a flag that does not apply, not a
      # target that reads two ways.
      class BaseNotOverridable < Error; end

      HEADLINE = "reviewing %<label>s at %<scope>s scope: %<base>s..%<head>s"

      # {Source::DiffOrigin}'s report, rendered, and ONLY when it fell back.
      # That value exists so a fallback is never silent, and a screen with a
      # human in front of it is where the requirement actually lands -- while a
      # note on every ordinary review is the same noise the requirement was
      # written against.
      FELL_BACK = "note: GitHub did not serve the combined diff (%<reason>s), so it was read from the " \
                  "object database instead -- %<message>s"

      # @param repo_root [String] the repository every git call reads
      # @param paths [Paths] resolves `sessions_dir`, where the round is
      #   journaled
      # @param bounds [Review::Bounds] the sizes past which a view is refused
      # @param surface [#present, nil] where the changeset is drawn; nil builds
      #   the text surface over a buffer this object owns
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as {Forge::Gh} and both sources do
      def initialize(repo_root: Dir.pwd, paths: Paths.new, bounds: Lain::Review::Bounds.new,
                     surface: nil, shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @paths = paths
        @bounds = bounds
        @surface = surface
        @targets = Target.new(repo_root:, shell_out_factory:)
      end

      # @param target [String] a pull request (a number, `#number` or a URL), or
      #   a local branch
      # @param scope [String, Symbol, nil] the name of a registered
      #   {Review::Partition::Strategy}; {Review::Partition::DEFAULT_SCOPE} when
      #   the flag is absent
      # @param base [String, nil] the ref a BRANCH is reviewed against
      # @return [String] the headline, whatever the source had to report, and
      #   the rendering beneath them
      # @raise [Lain::Error] every refusal here and below: an unresolvable ref,
      #   an ambiguous target, an undeclared scope, a view past a ceiling
      def present(target, scope: nil, base: nil)
        scope = Lain::Review::Session.scope!(scope || default_scope)
        resolved = @targets.resolve(target.to_s, base:)
        changeset = Lain::Review::Changeset.new(source: resolved.source)
        opened(resolved, changeset, scope)
      end

      private

      # The flag's absence, not a second declaration of the vocabulary: the
      # word comes off {Review::Partition::DEFAULT_SCOPE}, which is read out of
      # the registry, and it still goes through {Review::Session.scope!} on the
      # same line every explicit scope does.
      def default_scope = Lain::Review::Partition::DEFAULT_SCOPE

      def opened(resolved, changeset, scope)
        buffer = StringIO.new
        surface = checked_surface(buffer)
        # BEFORE the round, and this order is what makes the note true rather
        # than lucky: {Source::GithubPr#diff_origin} forces the DIFF, and only a
        # source asked for its diff FIRST can report a fallback -- `Session.open`
        # reads `base_ref`, which for a pull request fetches, and a fetched
        # source then serves the diff from the object database and reports
        # `already_local` for a combined diff GitHub actually refused. That
        # ordering used to come free from the size guard reading `files` here;
        # T31c moved the guard, so it is stated rather than inherited.
        report = fell_back(resolved.source)
        journal = Journal.open(paths: @paths)
        begin
          session = Lain::Review::Session.open(changeset:, journal:, source: resolved.name, surface:, bounds: @bounds)
          drawn(resolved, session, scope, buffer, report)
        ensure
          journal.close
        end
      end

      # The default surface renders into a buffer this object owns, so the two
      # are built together. Checked BEFORE the journal is opened: a surface that
      # cannot answer the port would otherwise leave a round on record that
      # nothing ever drew.
      def checked_surface(buffer)
        (@surface || Lain::Review::Surface::Text.new(sink: buffer)).tap do |surface|
          Lain::Review::Surface.check!(surface)
        end
      end

      def drawn(resolved, session, scope, buffer, report)
        answer = session.present(scope:)
        [format(HEADLINE, label: resolved.label, scope:,
                          base: session.changeset.base_ref, head: session.changeset.head_ref),
         report,
         body(buffer, answer)].compact.join("\n")
      end

      # A String answer is the port's REFUSAL (`spec/support/shared_examples/
      # review_surface.rb`, law #5) and is the only thing there is to show for a
      # surface that draws somewhere else; anything else means the surface took
      # it, and what it drew is in the buffer this object owns -- which is empty
      # for a surface that draws into an editor.
      def body(buffer, answer)
        return answer if answer.is_a?(String)

        rendered = buffer.string.chomp
        rendered.empty? ? nil : rendered
      end

      # No type test, and that is the whole point. Every source answers
      # {Source::DiffOrigin}, so this reads ONE message and asks only the
      # question a human cares about. The first cut asked
      # `respond_to?(:diff_origin)` first -- a type test in duck costume, and
      # the one place this command branched on WHICH source it held -- and a
      # panel mutant that always reported proved the conditional was tested on
      # one leg only: an ordinary pull request rendered this note with an empty
      # reason. The Null on {Source::LocalBranch} deleted the branch and the
      # defect together.
      def fell_back(source)
        origin = source.diff_origin
        return nil unless origin.fell_back?

        format(FELL_BACK, reason: origin.reason, message: origin.message)
      end

      # Which source a target names -- its own object, because "what does this
      # string mean" is a separate question from "present a review of it", and
      # because the ambiguity refusal needs a git call that has nothing to do
      # with rendering.
      class Target
        # One resolved target: the source, what to call it on screen, and the
        # pull request a review of it can be posted back to.
        #
        # `number` is nil for a BRANCH, and that nil is decided here rather than
        # asked of the source later: this object is built by the two methods
        # that already know which of the two they resolved, so nothing
        # downstream has to type-test a source to find out whether a review of
        # it has anywhere to go. {Review::Submit::Outbox} is what turns the nil
        # into a refusal naming {#label}.
        Resolved = Data.define(:source, :label, :number) do
          # The name the round is JOURNALED under, derived from the source's own
          # class rather than written here as a literal -- a literal is what
          # goes on naming `local_branch` after the class it describes is
          # renamed, and {Review::ChangesetOpened} validates this field for
          # presence only, so nothing downstream would catch it.
          def name = source.class.name.split("::").last.underscore
        end

        # @param repo_root [String] the repository every git call reads
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(repo_root:, shell_out_factory:)
          @repo_root = File.expand_path(repo_root)
          @shell_out_factory = shell_out_factory
        end

        # @param target [String]
        # @param base [String, nil]
        # @return [Resolved]
        # @raise [Ambiguous] for a pull request spelling that also names a branch
        # @raise [BaseNotOverridable] for `--base` against a pull request
        # @raise [Source::UnknownRef] for a ref or pull request that resolves to
        #   nothing -- {Source}'s own doctrine, and the one this class inherits
        #   rather than restates
        def resolve(target, base:)
          return branch(target, base) unless pull_request?(target)
          raise BaseNotOverridable, base_message(target) unless base.nil?
          raise Ambiguous, ambiguous_message(target) if branch?(target)

          pull_request(target)
        end

        private

        def pull_request(target)
          source = Lain::Review::Source::GithubPr.new(pull_request: target, repo_root: @repo_root,
                                                      shell_out_factory: @shell_out_factory)
          Resolved.new(source:, label: "pull request #{source.number}", number: source.number)
        end

        def branch(target, base)
          source = Lain::Review::Source::LocalBranch.new(base: base || default_base, head: target,
                                                         repo_root: @repo_root,
                                                         shell_out_factory: @shell_out_factory)
          Resolved.new(source:, label: "branch #{target}", number: nil)
        end

        # The base a LANDING targets, because what a review reviews is what is
        # going to be landed, and one spelling is better than two. A repository
        # whose trunk is called something else refuses loudly naming the ref,
        # with `--base` in the same help output.
        def default_base = Lain::Forge::Landing::BASE

        # The two spellings {Source::GithubPr::Remote} already parses, READ from
        # it rather than restated: a target this class calls a pull request and
        # that class then finds no number in would refuse in the wrong words.
        def pull_request?(target)
          remote = Lain::Review::Source::GithubPr::Remote
          [remote::BARE_NUMBER, remote::URL_NUMBER].any? { |spelling| spelling.match?(target) }
        end

        # `refs/heads/` and never the bare name: `rev-parse --verify 4821`
        # resolves an OBJECT whose sha begins with those digits, so the bare
        # form would call a coincidence a branch and refuse a perfectly
        # ordinary pull request.
        def branch?(target)
          git("rev-parse", "--verify", "--quiet", "--end-of-options",
              "refs/heads/#{target}").exitstatus.zero?
        end

        # {Source::LocalBranch#git}'s shape, and its scrub: an ambient GIT_DIR
        # (a pre-commit hook sets one) would otherwise point this at the hook's
        # repository. Read from a method body for the load-order reason the
        # class doc gives.
        def git(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end

        def ambiguous_message(target)
          number = target.delete_prefix("#")
          "#{target.inspect} names both pull request #{number} and the branch refs/heads/#{target} in " \
            "#{@repo_root}, and this will not guess between them -- they review different changesets. " \
            "Say \"refs/heads/#{target}\" for the branch, or the pull request's URL (.../pull/#{number}) " \
            "for the pull request."
        end

        def base_message(target)
          "--base cannot override the base of pull request #{target.inspect}: GitHub names the base " \
            "branch itself and the review is anchored to the merge base of that branch and the head, " \
            "so a base chosen here would present a range GitHub is not showing. Review a branch to " \
            "choose a base."
        end
      end
    end
  end
end
