# frozen_string_literal: true

module Lain
  module Review
    module Source
      # A directory of files reviewed AS THEY STAND: no diff, no base, no commit
      # walk. The third {Source}, and the one the port's model-values shape was
      # made for -- everything below it (hunk keys, marks, anchors, annotations,
      # {Session}, every surface, the docent) is reused unchanged.
      #
      # It answers the six universal messages and NEITHER witness: no `#diff`
      # and no `#commits`, so the cross-checks that hold one against the other
      # are diff-source laws it is never asked (`spec/support/shared_examples/
      # review_source.rb` records that split). {Partition::ByCommit} declines it
      # through `#supports?`; every other grouping takes it.
      #
      # == The base is a CONSTANT, and that is the incremental property
      #
      # {Marks} refuses to cross a base change before it consults a single key,
      # so a base derived from anything that moves -- a commit, a timestamp, the
      # tree's own digest -- would discard every mark on every re-survey. The
      # head is the opposite question and moves with the content, which is the
      # mirror of a diff source (whose base is what pins a review and whose head
      # moves with every amend): a corpus has no revisions, so the two roles are
      # played by a constant and a content address instead.
      #
      # == Opening reads every file ONCE and parses none of them
      #
      # Priced honestly, because it is the trade the whole arm rests on. The
      # address is content-addressed, so `#identity` streams every listed file
      # and hashes it -- O(total bytes), and unavoidable if "re-chunking does
      # not move the address" and "marks survive across surveys" are both to
      # hold. What laziness buys is the PARSE tier: chunking is per file, on
      # demand, through {LazyFile}, so presenting costs O(files ever marked)
      # rather than O(corpus).
      #
      # Round identity therefore does NOT depend on the chunking strategy.
      # Improving a chunker later does not open a new round over a tree nobody
      # touched, and a region release changes exactly the files it touched.
      #
      # "Opening reads every file once" is true of OPENING and of nothing more,
      # so the total is stated rather than left to be inferred: a fully worked
      # corpus reads each file TWICE -- once for the identity pass, once when
      # its file is finally chunked -- and a third time per {#file_at} an editor
      # asks for. {Reading#content} is deliberately not memoized: a memo would
      # hold the whole corpus resident for the life of the session, which is the
      # cost the accrete model (B12) exists to avoid, and a re-read is cheap
      # beside the parse it feeds.
      #
      # The file ceiling is checked in {#initialize}, from the walk alone: an
      # oversized corpus is refused without reading a byte it would then throw
      # away. That ordering is the promise, and putting the guard in the
      # constructor is what makes it structural rather than remembered.
      #
      # == Every line carries its `+`, blank lines included
      #
      # {Changeset#context?} reads `""` as CONTEXT (`changeset.rb`), so a blank
      # line emitted bare would advance the old-side counter, grow a side this
      # source does not have, and materialise anchors against a base that holds
      # nothing. A deliberate carry, not an oversight -- `old_start`/`old_count`
      # are fixed at `0,0` and {UnitHunk} marks every line.
      #
      # == Every path is named from ONE root, and it is the READER's
      #
      # A walk names what it found beneath the tree it was pointed at, which is
      # the only root it has. Everything downstream reads those names somewhere
      # ELSE: the sidebar row a `<CR>` resolves, the buffer `47_diff.lua` opens
      # against `getcwd(-1, -1)` -- the directory the editor was STARTED in --
      # and the path a verdict's refusal sends a human to go and look at. So
      # `/survey ./lib` labelled a row `greeter.rb` and opened an empty buffer
      # for a file that does not exist, and every object on that path had a
      # passing spec, because each was tested against a double standing where
      # the next one's root would have been.
      #
      # `named_from:` is that reader's root, and it is a CWD rather than a
      # project root. {Lain::Project} splits the two on purpose -- root is the
      # authority boundary, cwd is where a relative path RESOLVES -- and a
      # monorepo chat runs with cwd deep in a subtree while root sits at the
      # repository top, so naming from the root breaks `/survey .`, which works
      # today. {Lain::CLI::Survey}'s class doc states the same rule one file
      # over, about the classifier. nil names from the surveyed tree itself,
      # which is the same answer whenever the two coincide.
      #
      # LEXICAL, and never resolved. The prefix is joined the way the EDITOR
      # joins it: `Dir.pwd` and nvim's `getcwd` are both physical, and a survey
      # root is `File.expand_path` of what a human typed -- so a symlinked
      # subdirectory names `lib/x`, the editor opens `<cwd>/lib/x`, and both
      # follow the same link to the same file. `realpath` here would mint a
      # prefix that no longer sits under the editor's cwd at all.
      #
      # It moves the ADDRESS, since {#identity} is composed from the paths: one
      # tree surveyed from two roots is two corpora, and a mark made under one
      # does not carry to the other. That is the price, and it is the right way
      # round -- a name a reader cannot resolve is worse than a mark set that
      # belongs to the directory it was made in.
      #
      # == Collaborators are injected, all four
      #
      # The walk decides which paths enter, the projection which bytes of them
      # do, {Bounds} how many is too many, and the chunker how a file divides.
      # None is constructed here. The chunker in particular is not a
      # convenience: it is the seam a counting chunker rides so that "this
      # survey chunked nothing" is a measurement through the real stack rather
      # than a flag the subject sets about itself.
      class Corpus
        # What every old-side anchor would rest on, if there were one. Fixed
        # forever: see the class doc.
        BASE_REF = "corpus-as-it-stands-v1"

        # The corpus address's namespace. Its OWN, never {Diffed}'s -- an
        # address that claimed to be a diff's would be forgeable across the two.
        DIGEST_SCHEME = "survey-corpus-v1"

        # The origin marker every line of a unit wears. See the class doc.
        MARKER = "+"

        UnitHunk = Data.define(:unit, :lines)

        # One {Survey::Unit}, as the hunk the review model reads.
        #
        # It answers {Hunk}'s duck and is deliberately not one: the KEYS are the
        # unit's, under `unit-content-v1`, and a {Hunk} subclass would either
        # re-derive them under a second layout wearing the same scheme name or
        # keep the hunk scheme and collide. That collision is demonstrable, not
        # hypothetical -- a one-unit surveyed file and the same bytes newly
        # ADDED in a branch diff have the same path frame and the same all-`+`
        # body, so under `hunk-content-v1` a corpus mark would satisfy a diff
        # hunk.
        #
        # `lines` is a member rather than a derivation, because `#lines` is read
        # by the anchor walk, the ceiling and the docent, and rebuilding the
        # marked body per call is allocation nobody asked for.
        #
        # == The batch runs through {Hunk.keys}, NOT {Survey::Unit.keys}
        #
        # Worth a pointer, because the other one looks like the survey's keying
        # path and is not: `Session::MarkedChangeset.keys_by_path` and
        # `Marks#states` both call `Hunk.keys`, so that is the ladder a corpus
        # is keyed by, and it reaches these three messages. {Survey::Unit.keys}
        # has NO consumer in `lib/` -- it is the same two-rung rule written for
        # units, and the two must not be allowed to drift into two answers.
        class UnitHunk
          # @param unit [Survey::Unit]
          # @return [UnitHunk]
          def self.of(unit) = new(unit:, lines: unit.lines.map { -"#{MARKER}#{_1}" }.freeze)

          def path = unit.path

          # The unit's label. A hunk heading is display text on both arms, which
          # is why the unit keeps its label out of its key.
          def heading = unit.label

          # There is no old side, so the span is empty rather than absent: a
          # {Hunk} carries Integers and `nil` would break the arithmetic every
          # consumer does over them.
          def old_start = 0
          def old_count = 0

          def new_start = unit.start_line
          def new_count = unit.lines.size

          def content_key = unit.content_key

          def span_key = unit.span_key

          # {Hunk.keys}' third rung, and it is UNREACHABLE here rather than
          # merely unused -- so it forwards rather than inventing a fourth
          # layout. The ladder ties only if two units share a span key, and
          # {Survey::Unit} proves they cannot: the coverage contract gives every
          # unit of a file a distinct start line, and the span key frames both
          # the path and that line. A content key can never tie with a span key
          # either, since the schemes differ.
          #
          # What the ladder DOES do here is the property worth knowing: two
          # byte-identical units in one file share a content key and both fall
          # to the span key, which embeds where they start -- so an insertion
          # above the pair discards both their marks. Accepted, and spec'd.
          def full_span_key = unit.span_key
        end

        # Where one directory sits under another, as the prefix a name carries.
        #
        # `between("/p", "/p/lib")` is `lib`, a directory and itself is `""`,
        # and a tree the root merely sits BESIDE climbs -- `../notes` -- because
        # a survey may point anywhere and an absolute name is no answer
        # (`47_diff.lua` refuses one; the old side's buffer embeds it verbatim).
        # The comparison is SEGMENT-wise, so `/p/library` is not under `/p/lib`.
        #
        # Its own namespace because "where does this directory sit under that
        # one" is a question with adversarial answers -- a climb, a shared
        # prefix that is not a shared segment, the filesystem root, a name that
        # does not decode -- and pinning them through a real tree, a real walk
        # and a real corpus costs a fixture each. Here they are one call each.
        #
        # BYTES throughout: `String#split` raises `ArgumentError` on a name that
        # is not valid UTF-8 ({Survey::Walk#skipped?} carries the same note and
        # the `café.tex` that taught it), and Pathname's own arithmetic runs
        # through regexes with the identical failure. The answer is forced back
        # to the encoding the walk's names carry so the two concatenate; it is
        # NOT a claim that an undecodable name survives display, which
        # {Reading#path} scrubs like any other.
        module Prefix
          module_function

          # @param root [String] the directory a name is read from
          # @param directory [String] the directory that is being named
          # @return [String] frozen, possibly empty
          def between(root, directory)
            named = segments(root)
            walked = segments(directory)
            shared = named.zip(walked).take_while { |from, to| from == to }.size

            -[*Array.new(named.size - shared, ".."), *walked.drop(shared)]
              .join(File::SEPARATOR).force_encoding(Survey::Walk::FILESYSTEM)
          end

          # `File.expand_path` and not `realpath`: see the class doc's LEXICAL
          # paragraph. Empty segments are dropped so `/` and a trailing
          # separator answer the same list.
          def segments(directory) = File.expand_path(directory).b.split(File::SEPARATOR).reject(&:empty?)
        end

        Reading = Data.define(:listing, :projection, :prefix)

        # One listed file, as the corpus is allowed to see it: its whole bytes,
        # with every region nobody has released masked.
        #
        # A value, and shared by the identity pass and the chunking, so a file
        # is read through ONE expression however it is reached. Value equality
        # is what lets two derivations of a corpus produce equal {LazyFile}s --
        # {Session::MarkedChangeset}'s row table is a no-default `fetch` keyed
        # by the file object, and a chunker that compared unequal after a
        # rebuild would raise a `KeyError` a long way from its cause.
        class Reading
          # What the whole review calls this file: the walk's own name for it,
          # under `prefix` -- the surveyed tree's position beneath the root the
          # corpus names from, empty whenever the two are the same directory.
          #
          # UTF-8 and scrubbed, {Source::Parser#path_text}'s rule and its
          # reason: a path is journalled as JSON into an NDJSON record that one
          # unencodable line breaks. Unlike the parser's, this scrub costs
          # nothing -- the walk carries the filesystem's own bytes on
          # `absolute`, so the file is still OPENED by the name it really has.
          #
          # What it does cost is stated rather than left to be found: two names
          # differing only in bytes that do not decode scrub to ONE name, and
          # the corpus is keyed by this, so one of them would be dropped in
          # silence. The same residual {Source::Parser} carries, in a tree where
          # it is rarer still -- a survey lists what a human pointed at.
          #
          # The scrub runs over the JOINED name, so an ANCESTOR directory that
          # does not decode is replaced here too and an editor is then sent a
          # name it cannot resolve. Nothing above can do better -- a path that
          # must survive JSON and a path that must open a file are two different
          # requirements over the same bytes -- and the new side of such a name
          # is a buffer `47_diff.lua` refuses to write, which is the failure
          # closed rather than hidden.
          def path = -named.dup.force_encoding(Encoding::UTF_8).scrub

          # Raw bytes, never decoded: an anchor's evidence is compared byte for
          # byte against the line the file now holds, and substituting U+FFFD
          # for a latin-1 file's bytes would report drift on a line nobody
          # touched.
          #
          # `size:` is deliberately NOT passed to the projection, and that is a
          # judgement rather than an omission. It is a cross-check against a
          # truncated read, and this one cannot truncate -- it reads the whole
          # file, which is what earns the projection's `complete: true`. What it
          # WOULD catch is the walk's `stat` disagreeing with the bytes, and
          # that is ordinary in a survey: a human edits a file while the survey
          # is open, and the honest answer is to read what is there rather than
          # to raise an ArgumentError about a size measured a minute ago.
          #
          # The OTHER half of that same fact, which the sentence above does not
          # cover: this re-reads, so a file edited after the identity pass yields
          # hunks describing bytes the journaled address does not. The round is
          # then legitimately `Session#regenerated?` against a corpus rebuilt
          # over the tree as it now stands -- which is exactly what a re-survey
          # is for -- but WITHIN one session the two answers are of different
          # moments, and nothing here pretends otherwise. Freezing them together
          # means holding every file's bytes for the session; see the class doc.
          def content = projection.project(listing.absolute, File.binread(listing.absolute))

          private

          # `File.join` and not interpolation, so a prefix is joined by one rule
          # rather than by one that has to be remembered per caller.
          def named = prefix.empty? ? listing.path : File.join(prefix, listing.path)
        end

        Chunking = Data.define(:reading, :dispatch)

        # What a {LazyFile} calls when something finally asks for its hunks: one
        # read, one chunker, one list of hunks. Called at most once per file --
        # the memo is the lazy file's.
        class Chunking
          # @return [Array<UnitHunk>]
          def call
            source = reading.content
            dispatch.call(reading.path).call(path: reading.path, source:).map { |unit| UnitHunk.of(unit) }
          end
        end

        Read = Data.define(:digest, :lines)
        private_constant :Read

        # @param walk [Survey::Walk] which paths may be read, already walked
        # @param projection [Survey::Projection] which bytes of them may be seen
        # @param bounds [Bounds] the file ceiling, checked here and now
        # @param chunker [#call] resolves a path to the chunker it gets; the
        #   real dispatch by default. Substituting one is the observation seam,
        #   and it carries ONE obligation: {#rendered_bound} is a bound only
        #   over chunkers that keep {Chunker::Granularity}'s floor. A wrapper
        #   around the real dispatch keeps it; a chunker that emits a unit per
        #   paragraph does not, and a ceiling then under-measures.
        # @param named_from [String, nil] the directory every path in this
        #   corpus is NAMED from, which must be the one whoever reads a name
        #   resolves it against -- the CWD of the chat, which is the directory
        #   the attached editor was started in, and not the project root. See
        #   the class doc; nil names them from the surveyed tree itself.
        # @raise [Bounds::TooLarge] for a tree over the file ceiling
        def initialize(walk:, projection:, bounds: Bounds.new, chunker: Survey::Chunker.method(:for),
                       named_from: nil)
          @walk = walk
          @projection = projection
          @chunker = chunker
          @prefix = Prefix.between(named_from || walk.root, walk.root)
          refuse_oversized!(bounds)
        end

        # @return [String] {BASE_REF}, always
        def base_ref = BASE_REF

        # The corpus's own content address, worn as a revision: the hex half of
        # {#identity}'s digest, so it reads and truncates like the shas every
        # other source answers ({Anchor#to_s} shows seven characters of it).
        #
        # @return [String]
        def head_ref = @head_ref ||= -identity.digest.delete_prefix("#{DIGEST_SCHEME}:")

        # @return [Array<Withheld>] what the walk found and would not hand over,
        #   forwarded so a surface can disclose it without a second walk
        def withheld = @walk.withheld

        # Every listed file, unchunked. A {LazyFile} rather than a
        # {ChangedFile}: chunking every file when a survey opens is the cost
        # this arm exists to avoid, and the file whose hunks nobody reads should
        # never have been read.
        #
        # Every one of them is `added` -- there is no revision under a corpus,
        # so no file has an old side.
        #
        # @return [Array<LazyFile>] frozen, ascending by path
        def files
          @files ||= readings.values.map { |reading| lazy(reading) }.freeze
        end

        # `(path, content digest)` pairs over the PROJECTION, so a release
        # legitimately changes what the survey can show and the affected units
        # honestly demand a re-read.
        #
        # No parse: one streamed read and one blake3 per file, which is what
        # makes the address independent of how a chunker divides anything.
        #
        # @return [Identity]
        def identity
          @identity ||= Identity.new(scheme: DIGEST_SCHEME,
                                     parts: reads.flat_map { |path, read| [path, read.digest] })
        end

        # One file, as the head holds it. The base holds nothing, so it answers
        # nothing there -- which is the same statement as every file being
        # `added`.
        #
        # @param revision [String] {#base_ref} or {#head_ref}
        # @param path [String] one of {#files}' paths
        # @return [String, nil] raw bytes, projected; nil for any other revision
        #   or for a path this corpus does not carry
        def file_at(revision, path)
          reading = readings[path.to_s] if revision.to_s == head_ref

          reading&.content
        end

        # The object database answered and nobody was asked -- the same fact
        # {LocalBranch} reports, for the same reason.
        #
        # @return [DiffOrigin]
        def diff_origin = @diff_origin ||= DiffOrigin.already_local

        private

        # From the WALK, before a byte is read. `Bounds` owns the ceiling and
        # the refusal type; the measurement is a file count this object already
        # has, so asking it here is what keeps "an oversized corpus is refused
        # without reading a byte" a property of construction rather than of
        # whoever remembers to check first.
        def refuse_oversized!(bounds)
          measured = @walk.files.size
          return if measured <= bounds.max_files

          raise Bounds::TooLarge,
                "this corpus is #{measured} files, over the ceiling of #{bounds.max_files} -- " \
                "survey a subdirectory instead, or raise the ceiling"
        end

        def readings
          @readings ||= @walk.files.to_h do |listing|
            reading = Reading.new(listing:, projection: @projection, prefix: @prefix)
            [reading.path, reading]
          end.freeze
        end

        # `fetch` without a default: both tables are keyed by the same
        # {Reading#path}, so a miss is a corpus disagreeing with itself.
        def lazy(reading)
          LazyFile.new(old_path: nil, new_path: reading.path,
                       chunker: Chunking.new(reading:, dispatch: @chunker),
                       rendered_lines: rendered_bound(reads.fetch(reading.path).lines))
        end

        # What this file costs a reader, in {Bounds::Size}'s unit -- an UPPER
        # BOUND, never a count, and the distinction is the whole of it.
        #
        # `Size` measures RENDERED lines: a hunk's body plus its `@@` header.
        # So a surveyed file costs its own lines plus ONE PER UNIT, and the unit
        # count is knowable only by chunking -- the walk this message exists to
        # avoid. Measured, the shortfall of a bare line count is exactly the
        # unit count: 3% on `./planning`, 6.8% on `lib/lain/review`, 25% over
        # fifty small files.
        #
        # Under-measuring is the direction that cannot be accepted. `max_lines`
        # is a prompt-size guard, so a corpus reporting source lines while a
        # diff source reports rendered ones puts the two on different tapes --
        # {Bounds::Size}' own docstring names that trap one level down -- and
        # lets an oversized view through. So this over-measures instead, and
        # nothing about a diff source's number moves.
        #
        # The bound rests on {Chunker::Granularity}: every emitted unit holds at
        # least `DEFAULT_MINIMUM` lines (the trailing runt merges backward),
        # unless the file yields only one unit. So the unit count is at most
        # `max(1, lines / DEFAULT_MINIMUM)`. It is EXACT on a file that chunks to
        # one unit, which is the common small-file case, and loosens as a file
        # grows -- about 16% high over `./planning`.
        #
        # == The caveat, which is real
        #
        # The floor is the DISPATCH's chunkers' contract, not the port's. An
        # injected `chunker:` is held to nothing: a wrapper around the real
        # dispatch preserves the bound, and a chunker emitting a unit per
        # paragraph exceeds it. Said here and where `chunker:` is documented,
        # and pinned by a spec, rather than left as an invariant that quietly
        # is not one.
        def rendered_bound(lines) = lines + [1, lines / Survey::Chunker::DEFAULT_MINIMUM].max

        # ONE pass, harvesting both facts the opening of a survey needs: the
        # content digest the address is composed from, and the line count a
        # ceiling is decided from. Memoized, because a corpus's address must not
        # move under the session that journalled it.
        def reads = @reads ||= readings.transform_values { |reading| read_of(reading) }.freeze

        def read_of(reading)
          content = reading.content

          Read.new(digest: -Ext.blake3_hex(content), lines: line_count(content))
        end

        # {Survey::Unit.lines_of}'s rule as arithmetic: a trailing newline
        # TERMINATES the last line rather than starting an empty one, and a file
        # that is only a newline still holds one line. Counted rather than split
        # because materialising every line to count them is the parse tier's
        # cost, paid in the pass that exists to avoid it. `.b` because `count`
        # validates, and a latin-1 byte in a UTF-8-tagged file would raise.
        def line_count(content)
          return 0 if content.empty?

          content.b.count("\n") + (content.end_with?("\n") ? 0 : 1)
        end
      end
    end
  end
end
