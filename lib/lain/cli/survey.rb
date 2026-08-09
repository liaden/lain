# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "stringio"

module Lain
  module CLI
    # `lain survey PATH`: walk a directory, open a round over it AS IT STANDS,
    # and hand back what the surface drew.
    #
    # {CLI::Review}'s shape over the third source, and deliberately so -- the
    # journal, the round, the marks, the anchors and both surfaces are the same
    # objects, because a corpus answers the same port a diff does. What differs
    # is entirely above them: which collaborators are assembled (a walk, a
    # projection), and what a rendering owes a human that a diff review does not
    # (the disclosure below).
    #
    # Returns Strings; only the frontend prints (CLAUDE.md's Output discipline,
    # and `spec/output_discipline_spec.rb` enforces it mechanically). Every
    # refusal below is a {Lain::Error}, so `Boundary#render` in the exe turns
    # each into a `Thor::Error` -- message to stderr, nonzero exit, no
    # backtrace. There is a spec driving all five at once, because the
    # difference between that and a backtrace is the whole of what a human sees.
    #
    # == `Lain::Review` and `Lain::Survey` are both spelled out, everywhere
    #
    # This class is named `Survey`, so a bare `Survey::Walk` inside `Lain::CLI`
    # resolves HERE and dies -- {Effect::Handler::Sensitivity}'s trap, one
    # namespace over, and the same one `Review::Bounds` already falls into. Both
    # names are therefore qualified from `Lain`, and both are read from a METHOD
    # body and never from the class body: `lain.rb` loads `lain/cli` BEFORE
    # `lain/review` and `lain/survey`, so a constant here naming either would be
    # a load-time NameError. That is why {#default_scope} is a method rather
    # than the constant it would otherwise obviously be.
    #
    # == What a survey discloses that a review does not
    #
    # A diff review shows what changed; a survey shows a TREE, and a tree has
    # paths the walk will not hand over -- a private key, a binary blob, a link
    # out of the surveyed directory. `Source::Corpus#withheld` carries them and
    # nothing in `lib/` renders them, so this does: a listing four files short
    # with no word about why is the silent narrowing the whole secret boundary
    # is written against. A GATED file is not among them -- it enters masked to
    # its released regions ({Survey::Projection}), which is what keeps a survey
    # from being stricter than the read path over the same bytes.
    #
    # == The ledger, and why building one here is not the thing the rule forbids
    #
    # {Survey::Projection} requires the run's ONE region ledger and offers no
    # default and no Null, because a second ledger holds releases nobody ever
    # sees. A one-shot `lain survey` process has no Switchboard and no chat: the
    # ledger built here IS the run's, and there is exactly one of it. The
    # keyword stays open so the chat path -- `/survey`, which runs inside a
    # session that already has a board -- injects the board's rather than
    # minting a second.
    #
    # == The classifier is the RUN's, anchored where the human is standing
    #
    # `cwd:` and not the surveyed root: {Lain::Sensitivity} resolves a project's
    # relative rules against a working directory, and the `[sensitivity]` table
    # in force is the one belonging to the project the human invoked `lain` in
    # -- the same file `lain chat` would read there. {Lain::Project} cannot
    # stand in for it, since it requires cwd under root and a survey may point
    # anywhere; `Sensitivity` has no containment invariant and is the right
    # layer. A malformed table RAISES rather than degrading to a notice: this
    # table RESTRICTS, so dropping it fails OPEN, which is {Config.sensitivity}'s
    # own posture and not a decision taken here.
    class Survey
      HEADLINE = "surveying %<root>s at %<scope>s scope: %<count>d %<noun>s"

      # The disclosure's heading; each withheld path follows on its own
      # {Survey::Withheld#to_s} line, indented. Every part of it is a name the
      # survey was asked about and never a byte of a file, so it is as safe in a
      # prompt as it is on a screen.
      WITHHELD = "withheld %<count>d %<noun>s, not surveyed:"

      INDENT = "  "

      # What `--unbounded` means, as a whole {Review::Bounds} rather than a flag
      # threaded through the three objects that read a ceiling.
      #
      # TWO of the three ceilings lift. `max_critique_lines` is carried through
      # exactly as it was given, because `/critique` packs against a context
      # WINDOW rather than against a reader's patience -- a human saying they
      # will scroll anything has said nothing about how large a prompt may be.
      #
      # A whole Bounds and not a mutation: {Review::Bounds} is frozen, and the
      # value has to reach both the corpus (whose file ceiling is checked in its
      # constructor, from the walk alone) and {Review::Session#present}.
      #
      # @param bounds [Review::Bounds] the ceilings that would otherwise stand
      # @return [Review::Bounds]
      def self.unbounded(bounds)
        ceilings = Lain::Review::Bounds
        ceilings.new(max_files: ceilings::UNBOUNDED, max_lines: ceilings::UNBOUNDED,
                     max_critique_lines: bounds.max_critique_lines)
      end

      # @param paths [Paths] resolves `sessions_dir`, where the round is
      #   journaled, and supplies the HOME the classifier anchors its
      #   home-relative rules against. It does not care whether the surveyed
      #   directory is a repository.
      # @param cwd [String] what the classifier resolves a relative rule
      #   against, and the project whose `[sensitivity]` table is in force
      # @param bounds [Review::Bounds] the sizes past which a view is refused
      # @param surface [#present, nil] where the corpus is drawn; nil builds the
      #   text surface over a buffer this object owns
      # @param sensitivity [Lain::Sensitivity, nil] the run's path classifier;
      #   nil builds one from `cwd` and this project's own rules
      # @param ledger [Sensitivity::Ledger, nil] the run's ONE region ledger;
      #   nil builds this process's one and only, per the class doc
      # @raise [Config::Malformed] when the project's config file cannot be read
      def initialize(paths: Paths.new, cwd: Dir.pwd, bounds: Lain::Review::Bounds.new,
                     surface: nil, sensitivity: nil, ledger: nil)
        @paths = paths
        @bounds = bounds
        @surface = surface
        @sensitivity = sensitivity || classifier(cwd)
        @projection = Lain::Survey::Projection.new(ledger: ledger || Lain::Sensitivity::Ledger.new)
      end

      # @param path [String, Pathname] the directory to survey
      # @param scope [String, Symbol, nil] the name of a registered
      #   {Review::Partition::Strategy}; {Review::Partition::DEFAULT_SCOPE} when
      #   the flag is absent
      # @param unbounded [Boolean] present whatever the ceilings would refuse
      # @return [String] the headline, whatever the walk would not hand over,
      #   and the rendering beneath them
      # @raise [Lain::Error] every refusal here and below: a path that is not a
      #   directory, an undeclared scope, a grouping a corpus cannot answer, a
      #   view past a ceiling
      def present(path, scope: nil, unbounded: false)
        # FIRST, so a typo'd scope refuses before a tree is walked: resolution
        # needs no collaborators, and walking one to then reject the word the
        # human typed is work nobody asked for.
        at = Lain::Review::Session.scope!(scope || default_scope)
        ceilings = unbounded ? self.class.unbounded(@bounds) : @bounds
        walk = Lain::Survey::Walk.new(root: path.to_s, sensitivity: @sensitivity)
        opened(walk, corpus(walk, ceilings), at, ceilings)
      end

      private

      # The flag's absence, not a second declaration of the vocabulary: the word
      # comes off {Review::Partition::DEFAULT_SCOPE}, which is read out of the
      # registry, and it still goes through {Review::Session.scope!} on the same
      # line every explicit scope does.
      def default_scope = Lain::Review::Partition::DEFAULT_SCOPE

      def classifier(cwd)
        Lain::Sensitivity.new(home: @paths.home, cwd:, rules: Config.sensitivity(root: cwd))
      end

      def corpus(walk, ceilings)
        Lain::Review::Source::Corpus.new(walk:, projection: @projection, bounds: ceilings)
      end

      def opened(walk, source, scope, ceilings)
        buffer = StringIO.new
        surface = checked_surface(buffer)
        journal = Journal.open(paths: @paths)
        begin
          drawn(walk, round(source, journal, surface, ceilings), scope, buffer)
        ensure
          journal.close
        end
      end

      def round(source, journal, surface, ceilings)
        Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source:), journal:,
                                   source: source_name, surface:, bounds: ceilings)
      end

      # {CLI::Review::Target::Resolved#name}'s derivation and its reason: a
      # literal is what goes on naming `corpus` after the class it describes is
      # renamed, and {Review::ChangesetOpened} validates this field for presence
      # only, so nothing downstream would catch it.
      def source_name = Lain::Review::Source::Corpus.name.split("::").last.underscore

      # The default surface renders into a buffer this object owns, so the two
      # are built together. Checked BEFORE the journal is opened: a surface that
      # cannot answer the port would otherwise leave a round on record that
      # nothing ever drew.
      def checked_surface(buffer)
        (@surface || Lain::Review::Surface::Text.new(sink: buffer)).tap do |surface|
          Lain::Review::Surface.check!(surface)
        end
      end

      def drawn(walk, session, scope, buffer)
        answer = session.present(scope:)
        files = session.changeset.files
        [format(HEADLINE, root: walk.root, scope:, count: files.size, noun: "file".pluralize(files.size)),
         disclosure(walk.withheld),
         body(buffer, answer)].compact.join("\n")
      end

      # Nothing withheld says nothing, {CLI::Review#fell_back}'s rule: a note on
      # every ordinary survey is the same noise the requirement was written
      # against.
      def disclosure(withheld)
        return nil if withheld.empty?

        [format(WITHHELD, count: withheld.size, noun: "path".pluralize(withheld.size)),
         *withheld.map { |held| "#{INDENT}#{held}" }].join("\n")
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
    end
  end
end
