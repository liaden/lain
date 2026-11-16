# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "stringio"

module Lain
  module CLI
    # `qa-lain review <pull-request|branch>`: resolve a source, open a round on it,
    # and hand back what the surface drew.
    #
    # Returns Strings; only the frontend prints (CLAUDE.md's Output
    # discipline). Every refusal below is a {Lain::Error}, so `Boundary#render`
    # in the exe turns each into a `Thor::Error` -- message to stderr, nonzero
    # exit, no backtrace.
    #
    # == A target is never a command name HERE, and is at the exe
    #
    # Nothing below treats a target as anything but a ref: `present("help")`
    # reviews a branch called `help`. Thor is the half that reserves `help` and
    # `tree` as command names, so `qa-lain review open help` is the way through --
    # named in the exe's own `desc`, since this class cannot fix it from here.
    #
    # == `Lain::Review` is spelled out, everywhere
    #
    # A bare `Review` inside `Lain::CLI` resolves to THIS class, so
    # `Review::Bounds` would be a NameError rather than the guard. Every name
    # from the review and forge tiers is therefore qualified from `Lain`.
    # {#default_scope} stays a METHOD: it answers one caller once, so it has
    # never had a reader a constant would serve better -- the load-order rule
    # that used to force it is gone.
    #
    # == Where the size guard is called, and what moving it cost
    #
    # Not here. `bounds:` is still this command's to inject, but the ceiling is
    # enforced by {Review::Session#present}, the one place every surface is
    # reached through, so a re-callable `present`, an editor sidebar and
    # `/review` inside a chat are bounded by one caller instead of by whichever
    # command remembered to ask. The move cost one property: the ceiling now
    # runs AFTER `Session.open` has journaled the round, so a refused review
    # leaves a `changeset_opened` on record where it used to leave nothing.
    #
    # == The editor surface, and why this command does not build one
    #
    # `surface:` is injected; the default is {Review::Surface::Text} over a
    # buffer this object owns and returns. This command will not GUESS at one
    # from `$NVIM`: a one-shot process can attach to the nvim that spawned it,
    # but the lua half guards every entry point on `_G.__lain`, which only
    # `lain up` injects, so drawing into a plain nvim would report a success
    # that drew nothing. The gesture leg back is absent for the same reason:
    # the only thing that binds its adapter
    # ({CLI::HumanReplies#bind_changeset_review}) lives in the chat process,
    # not in a one-shot command.
    class Review
      # {Source::DiffOrigin}'s report, rendered, and ONLY when it fell back: a
      # fallback must never be silent, but a note on every ordinary review is
      # the same noise that requirement was written against.
      FELL_BACK = "note: GitHub did not serve the combined diff (%<reason>s), so it was read from the " \
                  "object database instead -- %<message>s"

      # @param repo_root [String] the repository every git call reads
      # @param root [String] the project root the round is journaled under
      # @param paths [Paths] resolves the sessions directory, where the round is
      #   journaled
      # @param bounds [Review::Bounds] the sizes past which a view is refused
      # @param surface [#present, nil] where the changeset is drawn; nil builds
      #   the text surface over a buffer this object owns
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   as {Forge::Gh} and both sources do
      def initialize(repo_root: Dir.pwd, root: Project::Resolver.default_project.root, paths: Paths.new, bounds: Lain::Review::Bounds.new,
                     surface: nil, shell_out_factory: Lain::Shell::Out.public_method(:new))
        @paths = paths
        @root = root
        @bounds = bounds
        @surface = surface
        @targets = Lain::Review::Target.new(repo_root:, shell_out_factory:)
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

      attr_reader :root

      # The flag's absence, not a second declaration of the vocabulary: the
      # word comes off {Review::Partition::DEFAULT_SCOPE}, which is read out of
      # the registry, and it still goes through {Review::Session.scope!} on the
      # same line every explicit scope does.
      def default_scope = Lain::Review::Partition::DEFAULT_SCOPE

      def opened(resolved, changeset, scope)
        buffer = StringIO.new
        surface = checked_surface(buffer)
        # BEFORE the round, and this order is what makes the note true rather
        # than lucky: only a source asked for its diff FIRST can report a
        # fallback. `Session.open` reads `base_ref`, which for a pull request
        # fetches, and a fetched source then serves the diff from the object
        # database and reports `already_local` for a combined diff GitHub
        # actually refused.
        report = fell_back(resolved.source)
        journal = Journal.open(paths: @paths, root:)
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
        [format(Lain::Review::Target::HEADLINE, label: resolved.label, scope:,
                                                base: session.changeset.base_ref, head: session.changeset.head_ref),
         report,
         body(buffer, answer)].compact.join("\n")
      end

      # A String answer is the port's REFUSAL (`spec/support/shared_examples/
      # review_surface.rb`, law #5); anything else means the surface took it,
      # and what it drew is in the buffer this object owns -- which is empty
      # for a surface that draws into an editor.
      def body(buffer, answer)
        return answer if answer.is_a?(String)

        rendered = buffer.string.chomp
        rendered.empty? ? nil : rendered
      end

      # No type test, and that is the whole point: every source answers
      # {Source::DiffOrigin}, so this reads ONE message. The first cut asked
      # `respond_to?(:diff_origin)` -- a type test in duck costume -- and a
      # mutant that always reported proved the conditional was tested on one
      # leg only: an ordinary pull request rendered this note with an empty
      # reason. The Null on {Source::LocalBranch} deleted the branch and the
      # defect together.
      def fell_back(source)
        origin = source.diff_origin
        return nil unless origin.fell_back?

        format(FELL_BACK, reason: origin.reason, message: origin.message)
      end
    end
  end
end
