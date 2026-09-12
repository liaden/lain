# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "stringio"

module Lain
  module CLI
    # `lain survey PATH`: walk a directory, open a round over it AS IT STANDS,
    # and hand back what the surface drew.
    #
    # {CLI::Review}'s shape over the third source, deliberately: the journal,
    # the round, the marks, the anchors and both surfaces are the same objects,
    # because a corpus answers the same port a diff does.
    #
    # Returns Strings; only the frontend prints (CLAUDE.md's Output
    # discipline). Every refusal below is a {Lain::Error}, so `Boundary#render`
    # in the exe turns each into a `Thor::Error` -- message to stderr, nonzero
    # exit, no backtrace.
    #
    # == `Lain::Review` and `Lain::Survey` are both spelled out, everywhere
    #
    # This class is named `Survey`, so a bare `Survey::Walk` inside `Lain::CLI`
    # resolves HERE and dies, the same trap `Review::Bounds` falls into. Both
    # names are therefore qualified from `Lain`, and both are read from a
    # METHOD body and never from the class body: `lain.rb` loads `lain/cli`
    # BEFORE `lain/review` and `lain/survey`, so a constant here naming either
    # would be a load-time NameError. That is why {#default_scope} is a method
    # rather than the constant it would otherwise obviously be.
    #
    # == What a survey discloses that a review does not
    #
    # A diff review shows what changed; a survey shows a TREE, and a tree has
    # paths the walk will not hand over -- a private key, a binary blob, a link
    # out of the surveyed directory. `Source::Corpus#withheld` carries them and
    # nothing in `lib/` renders them, so this does: a listing four files short
    # with no word about why is the silent narrowing the whole secret boundary
    # is written against. A GATED file is not among them -- it enters masked to
    # its released regions ({Survey::Projection}), which keeps a survey from
    # being stricter than the read path over the same bytes.
    #
    # == The ledger
    #
    # {Survey::Projection} requires the run's ONE region ledger and offers no
    # default and no Null, because a second ledger holds releases nobody ever
    # sees. A one-shot `lain survey` process has no Switchboard and no chat, so
    # the ledger built here IS the run's. The keyword stays open so `/survey`,
    # running inside a session that already has a board, injects the board's
    # rather than minting a second.
    #
    # == The classifier is the RUN's, and it takes a resolved Project
    #
    # Two questions, and a bare `cwd:` answered both with one directory: WHOSE
    # rules are in force is the project's ROOT, and what a relative path
    # resolves against is where the human is STANDING -- so `lain survey` run
    # below the repository top found no `.lain/config.toml` at all and
    # classified with `Rules.empty`. The surveyed tree is neither half: it is
    # {#present}'s argument and may point anywhere. A malformed table RAISES
    # rather than degrading to a notice: this table RESTRICTS, so dropping it
    # fails OPEN -- {Config.sensitivity}'s own posture, not a decision taken here.
    class Survey
      HEADLINE = "surveying %<root>s at %<scope>s scope: %<count>d %<noun>s"

      # The disclosure's heading; each withheld path follows on its own
      # {Survey::Withheld#to_s} line, indented. Every part of it is a name the
      # survey was asked about and never a byte of a file, so it is as safe in
      # a prompt as it is on a screen.
      WITHHELD = "withheld %<count>d %<noun>s, not surveyed:"

      INDENT = "  "

      # What `--unbounded` means, as a whole {Review::Bounds} rather than a flag
      # threaded through the three objects that read a ceiling -- and a whole
      # Bounds rather than a mutation, since {Review::Bounds} is frozen.
      #
      # Only TWO of the three ceilings lift. `max_critique_lines` carries
      # through as given, because `/critique` packs against a context WINDOW
      # rather than against a reader's patience: a human saying they will
      # scroll anything has said nothing about how large a prompt may be.
      #
      # @param bounds [Review::Bounds] the ceilings that would otherwise stand
      # @return [Review::Bounds]
      def self.unbounded(bounds)
        ceilings = Lain::Review::Bounds
        ceilings.new(max_files: ceilings::UNBOUNDED, max_lines: ceilings::UNBOUNDED,
                     max_critique_lines: bounds.max_critique_lines)
      end

      # @param project [Lain::Project] the run's resolved project: its ROOT holds
      #   the `[sensitivity]` table in force, its CWD is what a relative path
      #   resolves against. REQUIRED and resolved by the CALLER -- `exe/lain` is
      #   where a resolution that refuses can be rendered, and a resolver
      #   evaluated here walks the tree (and can raise) before anybody reads it
      # @param paths [Paths] resolves `sessions_dir`, where the round is
      #   journaled, and supplies the HOME the classifier anchors its
      #   home-relative rules against
      # @param bounds [Review::Bounds] the sizes past which a view is refused
      # @param surface [#present, nil] where the corpus is drawn; nil builds the
      #   text surface over a buffer this object owns
      # @param ledger [Sensitivity::Ledger, nil] the run's ONE region ledger;
      #   nil builds this process's one and only, per the class doc
      # @raise [Config::Malformed] when the project's config file cannot be read
      # @raise [Lain::Sensitivity::Rules::Refusal] when its `[sensitivity]`
      #   table is malformed -- a wrong table and an unreadable file are
      #   different failures, and both refuse here
      def initialize(project:, paths: Paths.new, bounds: Lain::Review::Bounds.new, surface: nil, ledger: nil)
        @paths = paths
        @bounds = bounds
        @surface = surface
        @sensitivity = classifier(project)
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
        # FIRST, so a typo'd scope refuses before a tree is walked: walking one
        # to then reject the word the human typed is work nobody asked for.
        at = Lain::Review::Session.scope!(scope || default_scope)
        ceilings = unbounded ? self.class.unbounded(@bounds) : @bounds
        walk = Lain::Survey::Walk.new(root: path.to_s, sensitivity: @sensitivity)
        opened(walk, corpus(walk, ceilings), at, ceilings)
      end

      private

      # The flag's absence, not a second declaration of the vocabulary: the word
      # comes off the registry's {Review::Partition::DEFAULT_SCOPE} and still
      # goes through {Review::Session.scope!} on the same line every explicit
      # scope does.
      def default_scope = Lain::Review::Partition::DEFAULT_SCOPE

      # Each half of the question asked of the half of the Project that answers
      # it: the table under the root, the anchor at the cwd.
      def classifier(project)
        Lain::Sensitivity.new(home: @paths.home, cwd: project.cwd,
                              rules: Config.sensitivity(root: project.root))
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
      # literal goes on naming `corpus` after the class it describes is
      # renamed, and {Review::ChangesetOpened} validates this field for
      # presence only, so nothing downstream would catch it.
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
      # review_surface.rb`, law #5); anything else means the surface took it,
      # and what it drew is in the buffer this object owns -- which is empty
      # for a surface that draws into an editor.
      def body(buffer, answer)
        return answer if answer.is_a?(String)

        rendered = buffer.string.chomp
        rendered.empty? ? nil : rendered
      end
    end
  end
end
