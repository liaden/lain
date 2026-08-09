# frozen_string_literal: true

module Lain
  module Review
    # A file in a changeset that has not been chunked yet, and is chunked once,
    # when something finally asks for its hunks.
    #
    # It answers {Source::ChangedFile}'s messages -- `old_path`, `new_path`,
    # `path`, `binary?`, `status`, `rendered_lines`, `hunks` -- and every one of
    # them but the last without chunking, which is what lets {Bounds} size a
    # whole view over these. It is what a corpus source hands a {Changeset} in
    # place of one. A survey opens over a directory, not a diff: chunking every
    # file up front is the cost the corpus arm exists to avoid, and the file
    # whose hunks nobody reads should never have been read.
    #
    # == Why this is NOT a Data, when everything shaped like it is
    #
    # Because a memo is reachable mutable state, and in this codebase a `Data`
    # is the claim that there is none: `spec/value_object_shareability_spec.rb`
    # builds one of every `Data` subclass under `Lain` and asserts
    # `Ractor.shareable?` on all of them. A `Data` here memoises fine -- an ivar
    # box set BEFORE `super` survives the freeze `super` applies (verified under
    # 4.0.6; assignment after `super`, and `instance_variable_set`, both raise
    # `FrozenError`) -- and it fails that sweep, correctly. So this is a plain
    # class that writes its own value equality, which is the honest spelling of
    # "defined by its attributes, but not a value object".
    #
    # The other shape that fits -- a `ChangedFile` whose `hunks` member is a
    # lazy collection answering `to_ary` (which `flat_map` flattens), needing no
    # parallel duck at all -- was rejected on EQUALITY. `Data#hash` hashes every
    # member, so `ChangedFile`'s identity would run through that collection.
    # Deriving the collection's hash from its contents chunks the file to answer
    # `#hash`, and {Session::MarkedChangeset.of}'s `files.to_h` hashes every
    # file, so building the row table would chunk the whole corpus. Deriving it
    # from anything else gives one class two equality semantics, value-flavoured
    # for a diff file and identity-flavoured for a surveyed one.
    #
    # == What it is honest about
    #
    # `Ractor.shareable?` is **false**, where a {Source::ChangedFile} is
    # deeply frozen and true. Twice over: the memo Hash is mutable, and a
    # callable is never shareable. That is the price of memoising anything at
    # all, and it reaches further than this object. TWO existing pins are
    # therefore DIFF-source laws, not universal ones, and both are spec'd next
    # to this class rather than left to be discovered:
    #
    #   - `changeset_spec.rb`'s deep-immutability group, over `changeset.files`;
    #   - `session_spec.rb`'s "the values this card adds are shareable", which
    #     asserts the whole {Session::MarkedChangeset} graph -- a {FileRow}
    #     holds its file, so one lazy leaf makes the graph unshareable.
    #
    # Equality is by value over `(old_path, new_path, binary, chunker)`, and the
    # memo is deliberately outside it: a file that has chunked still fetches the
    # row its unchunked twin keyed, which is what {Session::MarkedChangeset}'s
    # no-default `rows.fetch(file)` needs. `rendered_lines` is outside it for a
    # different reason -- it is DERIVED from the same content the chunker stands
    # for, so two sources disagreeing about it is a bug in one of them rather
    # than two files, and inside the value that bug would surface as a `KeyError`
    # three objects away naming the path it could not name the size of. The
    # chunker IS in the value, because
    # it stands in for the content -- two files over one path that would produce
    # different hunks are different files.
    #
    # Equality over the chunker is the chunker's OWN, which decides how a caller
    # keeps two derivations of one corpus comparing equal. A rebuilt lambda never
    # compares equal, so a caller building lambdas must thread the same instances
    # through; a chunker shaped as a VALUE -- a frozen `Data` answering `#call`
    # -- compares equal across derivations and needs no threading at all. The
    # second is the cheaper half and is the one to prefer when the chunker is
    # being designed rather than inherited.
    class LazyFile
      # The vocabulary itself, not a copy of it -- {Source::ChangedFile}
      # declares it and this is the same object, so a member dropped there
      # raises here too. Resolvable at class-body time because `review.rb`
      # requires `source` before this file, and {Source::ChangedFile} is defined
      # in `source.rb`'s own module body rather than in one of its children --
      # so it exists as soon as that line has run. `changeset` between the two
      # is incidental: this constant stopped coming from there when the file
      # value moved onto the port.
      STATUSES = Source::ChangedFile::STATUSES

      attr_reader :old_path, :new_path, :binary, :chunker, :rendered_lines

      # @param old_path [String, nil] nil for a file this changeset adds
      # @param new_path [String, nil] nil for a file it deletes
      # @param chunker [#call] answers this file's hunks, called at most once
      # @param rendered_lines [Integer] what this file costs a reader, in
      #   {Bounds::Size}'s unit. SUPPLIED and never derived, which is the half
      #   of laziness {Bounds} needs: a size answered by chunking would chunk
      #   the corpus to decide whether the corpus can be presented. A source
      #   harvests it in the streamed read its identity pass already makes.
      #   See {#sized} for why it is checked here and nowhere else.
      # @param binary [Boolean]
      # @raise [ArgumentError] for a negative size, or one that is not a number
      def initialize(old_path:, new_path:, chunker:, rendered_lines:, binary: false)
        @old_path = old_path && -old_path
        @new_path = new_path && -new_path
        @binary = binary
        @chunker = chunker
        @rendered_lines = sized(rendered_lines)
        # The memo is a BOX because the freeze below forbids assigning an ivar
        # afterwards. Everything this file IS stays immutable; the cache is the
        # one mutable thing, and it is the whole of what costs shareability.
        @memo = {}
        freeze
      end

      # @return [String] the file's identity: the new path wherever there is one
      def path = new_path || old_path

      def binary? = binary

      # {Source::ChangedFile#status}'s rule, over {STATUSES}' spellings. The
      # rule is restated rather than shared because its home is `changeset.rb`;
      # a spec drives both objects over the same four path pairs, so the two
      # cannot drift while they are apart.
      #
      # @return [Symbol] one of {STATUSES}' values
      def status
        return STATUSES.fetch("added") if old_path.nil?
        return STATUSES.fetch("deleted") if new_path.nil?

        STATUSES.fetch(old_path == new_path ? "modified" : "renamed")
      end

      # The splat COPIES, and that is the whole reason it is there: the array
      # belongs to the chunker, which is injected and unknown, so freezing it in
      # place would raise inside somebody else's object on a later file with
      # nothing in the backtrace naming the file that froze it. `.to_a` is not a
      # copy -- `Array#to_a` answers `self` -- and neither is `Array()`. The
      # splat also accepts any Enumerable, which `.freeze` alone would not.
      #
      # @return [Array<Hunk>] frozen, and the same array every time: `Hunk.keys`
      #   tallies twice over a whole file's hunks, so the batch is materialised
      #   rather than streamed
      def hunks = @memo.fetch(:hunks) { @memo[:hunks] = [*chunker.call].freeze }

      # `dup` copies the ivars and does not re-freeze, so a copy would otherwise
      # share -- and write into -- the frozen original's cache. A copy gets its
      # own empty box and is frozen like anything else this class hands out.
      def initialize_copy(other)
        super
        @memo = {}
        freeze
      end

      # `instance_of?`, not `is_a?`, so equality stays symmetric under any
      # future subclass -- what `Data` does, for the reason it does it.
      def ==(other) = other.instance_of?(self.class) && identity == other.identity

      alias eql? ==

      # The class is hashed in for the same reason `Data` hashes it in: without
      # it a subclass shares this bucket while comparing unequal, and so does a
      # bare Array of the same parts.
      def hash = [self.class, *identity].hash

      # What a `KeyError` from {Session::MarkedChangeset}'s `rows.fetch(file)`
      # prints, and the reason it is not the default: Ruby truncates the key's
      # `inspect` at 80 characters, and the default spends most of that on an
      # object id and the memo -- cutting the path and the status, which are the
      # only two facts that identify the file that missed.
      def inspect = "#<#{self.class.name} #{path.inspect} #{status}>"

      protected

      def identity = [old_path, new_path, binary, chunker]

      private

      # An asserted size is one a source can get WRONG, and this is the only
      # place the mistake can still be caught. {Bounds} sums what it is told, so
      # a single file reporting a negative cancels its neighbours: 250,000
      # rendered lines pass a 30,000-line ceiling and go on to a `/critique`
      # chunk 35x the context ceiling, which is precisely the
      # success-that-isn't-one {Bounds} exists to refuse -- produced by {Bounds}
      # itself, in silence. Downstream cannot check it without the walk this
      # message exists to avoid, so the check is here or it is nowhere.
      #
      # There is no honest negative. Zero IS honest and is left alone: it is
      # what a binary file, a mode-only change and an unrendered file all cost.
      #
      # `Integer()` first, for {Bounds}' own reason -- a ceiling compared
      # against a String is a `nil`-shaped failure with an `ArgumentError`'s
      # cure. A decimal String is deliberately not blessed by any spec:
      # `Integer("010")` is 8, and a line count that reads as octal is a defect
      # nobody would look for.
      def sized(value)
        lines = Integer(value)
        raise ArgumentError, "a file cannot render #{lines} lines" if lines.negative?

        lines
      end
    end
  end
end
