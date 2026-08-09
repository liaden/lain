# frozen_string_literal: true

module Lain
  module Middleware
    # Drops the sensitive paths out of a listing on the way OUT of the tool
    # phase, and says how many it dropped.
    #
    # {RedactSecretReads}' neighbour rather than its second job. That one masks
    # the region BYTES inside one file's content; this one filters a LIST of
    # paths. Two questions, two result shapes -- a mask rewrites a string in
    # place, a filter removes whole rows and owes a count -- sharing only a
    # phase. Folding them together would make one class's name describe half of
    # what it does; the cost of keeping them apart is one more {Stack} entry.
    #
    # == It filters the RESULT, so no tier-1 tool gains a path check
    #
    # `grep` must not print a matching line out of a gated file, and `glob` and
    # `list_files` must not enumerate a denied directory -- but the doctrine
    # `tools/glob.rb` states is that confinement never lives inside a tier-1
    # tool. Both hold at once because the check is here, above the tool, on what
    # it produced. The tools are unchanged.
    #
    # This withholds SENSITIVE paths, never OUTSIDE-ROOT ones. A pattern that
    # climbs out via `../` is still honoured, exactly as `tools/glob.rb:10-17`
    # says it is; what changes is only that a `.env` it reaches is not listed.
    #
    # == The filtering is always reported
    #
    # `3 paths withheld (protected)`, appended to the listing, never silent.
    # Silent truncation reads as "that is everything", which is a lie the agent
    # acts on -- and it is the same reasoning that made `grep` report `capped`
    # rather than truncate. Nothing withheld appends nothing, so an ordinary
    # listing is byte-identical to the tool's own.
    #
    # == The cap and the withholding are two facts, not one
    #
    # A capped grep that also withholds reports both, and they do not
    # contradict because they are about different things. `capped at 200
    # matches` is about the SEARCH: it stopped as soon as it had 200, and a
    # withheld match is one of those 200 -- it was found before this class saw a
    # row, and no middleware can un-find it. `1 match withheld` is about the
    # OUTPUT. So the arithmetic closes: rows shown plus rows withheld is what
    # the search returned.
    #
    # Making the cap ignore the withheld rows was the alternative and is not
    # available from here: this class sees a formatted result, not the walk, so
    # "200 that survived" would mean asking the tool to search again. It would
    # also leak by subtraction -- a cap that quietly slid to include one more
    # file says a withheld one was there.
    class WithholdSecretPaths < Base
      # How a row of one tool's output names paths, and what one withheld row is
      # called when it is counted.
      class Rows
        def noun(count) = count == 1 ? self.class::ONE : self.class::MANY
      end

      # `glob` and `list_files`: the row IS the path, so it has exactly one
      # reading per base.
      class Listing < Rows
        ONE = "path"
        MANY = "paths"

        def paths_in(row) = [row]
      end

      # `grep`: `path:lineno:text`. A colon is legal in a path AND in the
      # matched text, so there is no split that is right in every case -- every
      # split whose middle field is a line number is a reading, and
      # {Sensitivity::Filter} withholds the row if any of them is sensitive.
      #
      # A row with no such split is not a match row at all: grep's own
      # `... capped at 200 matches` trailer is the only one, and it names no
      # file, so it is left alone.
      class Matches < Rows
        ONE = "match"
        MANY = "matches"

        SEPARATOR = ":"
        LINE_NUMBER = /\A\d+\z/

        # `-1` keeps the trailing empty field, so a match on an EMPTY line
        # (`app.rb:3:`) still splits into three and still names its file.
        def paths_in(row)
          fields = row.split(SEPARATOR, -1)
          splits(fields).map { |at| fields.take(at).join(SEPARATOR) }
        end

        private

        # Every index whose field is a line number and which has a text field
        # after it -- so `12:34` on its own is not read as a path called `12`.
        def splits(fields) = (1...(fields.length - 1)).select { fields[_1].match?(LINE_NUMBER) }
      end

      LISTING = Listing.new.freeze
      MATCHES = Matches.new.freeze

      # Exact membership, {RefuseSecretWrites::GUARDED_TOOLS}' rule: a tool that
      # returns a list of paths under some other name is unguarded by design
      # until it earns a place here. `bash` listing a directory with `ls` is
      # deliberately NOT in this set -- that is the path boundary's job and a
      # different card's.
      GUARDED_TOOLS = { "glob" => LISTING, "list_files" => LISTING, "grep" => MATCHES }.freeze

      ROW = "\n"
      WITHHELD = "%<count>d %<noun>s withheld (%<reasons>s)"
      REASONS = ", "
      # What `glob` resolves an absent base to, exactly as {Tools::Glob#perform}
      # does -- and the same answer for a guarded tool whose input names no path
      # at all, whose rows can only be relative to where the worker stands.
      CWD = "."

      # Readable for {Agent::ToolRunner#handler}'s reason: what a guard was
      # wired to is not private business when the caller did not build it, and
      # a wiring spec has to be able to assert IDENTITY -- that this holds the
      # run's one filter rather than a second one over a fresh classifier.
      attr_reader :filter

      # @param filter [Sensitivity::Filter] which rows a listing may show.
      #   REQUIRED, with no default: a default is how a run ends up filtering
      #   against a classifier nobody chose. {Sensitivity::Filter::Null} is how
      #   a run that withholds nothing says so on purpose.
      # @raise [ArgumentError] on a nil filter
      def initialize(filter:)
        raise ArgumentError, "a filter is required: pass #{Sensitivity::Filter::Null.name} to withhold nothing" \
          unless filter

        @filter = filter
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        carried = downstream(env, &app)
        shape = GUARDED_TOOLS[effect.name]
        return carried unless shape

        guarded(carried, effect, shape)
      end

      private

      # {Middleware::Env} is `fetch`-based, so this merges over a `:result` the
      # tool has already set rather than short-circuiting past it.
      #
      # The rescue answers with an ERROR and never with the listing: a result
      # this class could not finish checking is one whose paths it cannot vouch
      # for. It reports the exception CLASS only -- a message can quote the
      # input that produced it, and the input here is the listing being
      # withheld.
      def guarded(carried, effect, shape)
        result = carried.fetch(:result)
        # A failed tool carries a message, never a listing, so there are no rows
        # here to sift.
        return carried if result.error?
        return unreadable(carried, effect) unless result.content.is_a?(String)

        reported(carried, effect, shape, result.content)
      rescue StandardError => e
        carried.merge(result: Tool::Result.error(
          "#{effect.name} could not be checked for sensitive paths (#{e.class}); nothing was returned."
        ))
      end

      # Content this class cannot read as rows cannot be vouched for, so it is
      # not sent. Forwarding the part it understood is the fail-open shape
      # {RedactSecretReads::Scan} refuses for the same reason: the part it did
      # not understand is what would carry the path out.
      def unreadable(carried, effect)
        carried.merge(result: Tool::Result.error(
          "#{effect.name} returned content this secret boundary cannot read as a listing, so it was withheld."
        ))
      end

      # Nothing withheld returns the CARRIED env untouched rather than a
      # rebuilt one, so an ordinary listing is byte-identical to the tool's own
      # -- a split-and-join would silently normalize a trailing newline a tool
      # someday emits.
      def reported(carried, effect, shape, content)
        sifted = sift(carried, effect, shape, content)
        return carried unless sifted.any?

        carried.merge(result: Tool::Result.ok([*sifted.kept, line(sifted, shape)].join(ROW)))
      end

      def line(sifted, shape)
        format(WITHHELD, count: sifted.count, noun: shape.noun(sifted.count),
                         reasons: sifted.reasons.join(REASONS))
      end

      def sift(carried, effect, shape, content)
        base = base(effect, carried.fetch(:context) || Session::Null.instance)
        @filter.sift(content.split(ROW)) { |row| shape.paths_in(row).map { reading(_1, base) } }
      end

      # An absolute row names itself. A relative one is joined to the target
      # LEXICALLY -- never through `File.expand_path`, whose tilde handling is
      # the getpwnam call {Sensitivity} exists without -- and the classifier's
      # own `cleanpath` folds it from there.
      #
      # A reading the classifier would call {Sensitivity::MALFORMED} is handed
      # over UNJOINED, because `File.join` raises on a NUL byte BEFORE anything
      # is classified -- and a raise here takes the ENTIRE listing down through
      # {#guarded}'s rescue, every ordinary row beside it included, where the
      # classifier withholds exactly the row nobody can read. Both fail closed;
      # only one of them still answers the question that was asked.
      #
      # It is reachable: a grep row carries a file's own matched bytes, so
      # `\0:12:` in a matched line IS a second reading of that row.
      #
      # {Sensitivity.readable?} also covers an encoding `start_with?` could not
      # compare, which is why it is asked first -- but no example pins that
      # order and none can: a reading is a slice of content this class already
      # split on a UTF-8 newline, so content that could not be compared never
      # reaches here.
      def reading(path, base)
        return path unless Sensitivity.readable?(path)
        return path if path.start_with?(File::SEPARATOR)

        File.join(base, path)
      end

      # What a relative row is relative to: the target the tool itself resolved,
      # read through {Sensitivity::Policy::PATH_FIELDS} so this class holds no
      # second copy of "which input field names a path". Absent -- `glob`'s
      # optional base -- it is the worker's cwd, exactly as {Tools::Glob#perform}
      # resolves it.
      #
      # A single-FILE `grep` is the one case where the target is not a directory:
      # it labels every hit with the model's own spelling (`tools/grep.rb:92-99`),
      # so the join produces the true path with the row appended to it. That is a
      # path no file has, and it is still the right thing to classify: every rule
      # here matches on a prefix, a whole segment, or the basename, and appending
      # the row preserves all three -- so a reading of it is exactly as strict as
      # a reading of the true path, and never less. A `stat` to tell the two
      # targets apart would put IO in the middle of a middleware to buy nothing.
      def base(effect, session)
        cwd = session.worker_env.cwd
        File.expand_path(at(effect.input, Sensitivity::Policy::PATH_FIELDS[effect.name]) || CWD, cwd)
      end

      # Both spellings, {Sensitivity::Policy#at}'s rule: a parsed provider
      # payload arrives with String keys while an in-process caller writes
      # Symbols, and reading only one of them misses the base entirely.
      def at(input, field)
        return nil unless field && input.is_a?(Hash)

        input[field] || input[field.to_sym]
      end
    end
  end
end
