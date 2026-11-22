# frozen_string_literal: true

require "strscan"

module Lain
  module Shell
    Named = Data.define(:paths, :opaque)

    # The paths a bash command names, resolved against the directory each stage
    # runs in, so an approval rung can ask about the files a call touches rather
    # than about its `cwd`.
    #
    # Opaque is the answer whenever a path could be named under the wrong
    # directory or spelled differently from what bash would pass, or when the
    # program opens paths its argv does not name: a parse that was not fully
    # read, an expansion, a quoting form this object does not undo, a `cd` that
    # might not bind the stages after it, a directory option, a `..` a symlink
    # could redirect, a program that runs other programs. Opaque is the safe
    # direction, because every consumer parks on it, so nothing here guesses.
    # A bare word is named as a path too (`frobnicate password src` names
    # `/p/password`): a word that is not a file costs a false positive, while
    # skipping one that is would be a bypass. Only an operand whose role
    # {OperandRoles} is certain of, such as grep's pattern, goes unnamed.
    class Named
      # @!attribute word [String] as the model wrote it, quotes included
      # @!attribute resolved [String] absolute; for a glob, its fixed directory
      # @!attribute written [Boolean] whether the command writes it, as far as
      #   {#written} knows
      # @!attribute directory [Boolean] a `cd` target the later stages run in
      # @!attribute pattern [String, nil] the absolute glob this path stands
      #   for, with a quoted glob character escaped: the word's own glob, or
      #   `<root>/**` for a search root such as find's
      # @!attribute guess [Boolean] one of several places an unknown program's
      #   attached value could start, so most of them name no real file
      # @!attribute git [Boolean] a tree a git subcommand reads or writes, so its
      #   history is reached through `.git` even where that is a pointer file;
      #   with no pattern, the `.git` a checkout-local write lands in
      Path = Data.define(:word, :resolved, :written, :directory, :pattern, :guess, :git) do
        # Data has no per-member defaults, so the keywords are defaulted here.
        def initialize(guess: false, git: false, **) = super

        def checkout_git? = git && pattern.nil?

        # Whether the command wrote it so that the directory it runs in cannot
        # move it: a rooted path, or a `~` the home resolves.
        def absolute? = word.delete(%q('")).start_with?("/", "~")
      end

      # @param command [String] the command as the model wrote it
      # @param cwd [String] absolute directory the call runs in
      # @param home [String, nil] for `~`, from {Sensitivity::Policy#home}; a
      #   `~` word with none makes the command opaque
      # @return [Named]
      def self.of(command, cwd:, home:) = from(Parse.new.call(command), cwd:, home:)

      # The tilde bash expands from HOME alone; {Verdict} expands the same one.
      HOMED = %r{\A~(/|\z)}
      COMMAND = "command"
      RUNS_IN = "cwd"
      UNPLACED = "/.lain-unplaced-cwd"
      private_constant :RUNS_IN, :UNPLACED

      # The one reading of where a call runs, so the rungs that read one call
      # cannot place its paths under different directories.
      #
      # @param effect [Lain::Effect::ToolCall] its `cwd` field resolves against the session's
      # @param context [Object] answers `worker_env` as a session does
      # @param home [String, nil] as for {.of}
      # @param parsed [Parse::Result, nil] the command's parse when the caller already holds it
      # @return [Named] {UNREADABLE} when the call names no command or the session's directory is not absolute;
      #   opaque when only the call's own `cwd` cannot be resolved
      def self.for_call(effect, context, home:, parsed: nil)
        cwd = ::Lain::Session.cwd_of(context)
        return UNREADABLE unless cwd.is_a?(String) && cwd.start_with?("/")

        for_input(effect.input, cwd:, home:, parsed:)
      end

      # @param input [Object] as the model sent it; only the command and `cwd` fields are read
      # @param cwd [String] absolute; the session's directory for the call
      # @param home [String, nil] as for {.of}
      # @param directory [String, nil] where the call runs, for a caller that already resolved it
      # @param parsed [Parse::Result, nil] the command's parse when the caller already holds it
      # @return [Named] {UNREADABLE} when the input holds no command String; opaque when the
      #   directory cannot be resolved
      def self.for_input(input, cwd:, home:, directory: directory_of(input, cwd:, home:), parsed: nil)
        command = field_of(input, COMMAND)
        return UNREADABLE unless command.is_a?(String)

        result = parsed || Parse.new.call(command)
        directory ? from(result, cwd: directory, home:) : unplaced(result, home:)
      end

      # A command whose directory cannot be resolved still names the words it
      # wrote as absolute, but a relative one lands nowhere known, so the whole
      # is opaque.
      def self.unplaced(result, home:)
        read = from(result, cwd: UNPLACED, home:)
        new(paths: read.paths.select(&:absolute?).freeze, opaque: true)
      end
      private_class_method :unplaced

      # Where a call runs: its `cwd` field resolved against the session's, or
      # the session's when it has none.
      #
      # @param input [Object] as the model sent it
      # @param cwd [String] absolute; the session's directory for the call
      # @param home [String, nil] for a leading `~`
      # @return [String, nil] nil for a field no tool could resolve
      def self.directory_of(input, cwd:, home:)
        at = field_of(input, RUNS_IN) || "."
        at.is_a?(String) ? resolved(at, cwd, home:) : nil
      end

      # A `~` is the session's home when one is known, as the policy reads it,
      # so a path tool and a command spelling the same file meet.
      #
      # @param path [String] as the call wrote it
      # @param cwd [String] absolute; where the call resolves a relative path
      # @param home [String, nil] for a leading `~`; nil leaves it to the process
      # @return [String, nil]
      def self.resolved(path, cwd, home: nil)
        homed = home && path.match?(HOMED) ? File.join(home, path.delete_prefix("~")) : path
        File.expand_path(homed, cwd)
      rescue ArgumentError, EncodingError
        nil
      end

      # @param input [Object] as the model sent it
      # @param name [String] the field
      # @return [Object, nil] the field under its String or Symbol key; nil for an input that is not a Hash
      def self.field_of(input, name) = input.is_a?(Hash) ? input[name] || input[name.to_sym] : nil

      # @param result [Parse::Result] a parse a caller already holds
      # @param cwd [String] absolute directory the call runs in
      # @param home [String, nil] as for {.of}
      # @return [Named] opaque on a relative or missing cwd, against which no
      #   path resolves to where the call lands
      def self.from(result, cwd:, home:)
        return UNREADABLE unless cwd.is_a?(String) && cwd.start_with?("/")

        Walk.new(LoopReading.unrolled(result) || result, cwd:, home:).named
      end

      # Read by the same walk that binds each `cd`, so a stage's words and its directory come from one reading.
      # A plain glob is expanded as bash would, sorted, and kept as written when
      # it matches nothing. A stage's assignments are handed to `env`, unless
      # the program is a builtin.
      #
      # @param result [Parse::Result]
      # @param cwd [String] absolute directory the call runs in
      # @param home [String, nil] what a leading `~` names; with none, a `~` word cannot be told
      # @return [Array<Array(Array<String>, String)>, nil] one per stage: its words as bash passes them, and
      #   the directory it runs in or nil; nil for a `**` or brace, an expansion, an escape, a word that is not
      #   literal, or a glob in a stage it cannot place
      def self.stages(result, cwd:, home:) = Walk.new(result, cwd:, home:).stages

      def opaque? = opaque

      # A lower bound: an output redirect's target, and the operands and output
      # options of the writers {Argv} lists. A program it does not list may
      # write any path it names, and that path is named as read.
      #
      # @return [Array<Path>]
      def written = paths.select(&:written)

      # What every command this object cannot read answers.
      UNREADABLE = new(paths: [].freeze, opaque: true)

      # One word's quoting undone, when every span of it is literal: a
      # single-quoted span as written, a double-quoted one only when it holds
      # nothing bash would interpret but `$?`, `$$` or `$#`, and bare text with
      # no backslash, expansion or brace. A quoted `*` is a file name and a bare
      # one is not, so the pattern escapes what was quoted. Inside double
      # quotes a backslash bash would not remove is kept, and `!` is text: a
      # shell that is not interactive expands no history.
      class Word
        SINGLE = /'([^'\0]*)'/
        DIGITS = /\$[?$#]/
        DOUBLE = /"((?:[^"$`\\\0]|\\[^"$`\\\0\n]|#{DIGITS})*)"/
        DOUBLE_PARTS = /(#{DIGITS})/
        BARE = /[^'"\\$`{\0]+/
        GLOB = /[*?\[]/
        GLOB_CHARACTER = /[*?\[\]\\{}]/
        OPEN_WILDCARD = /(?<!\\)(?:\\\\)*\*\z/
        LEADING_WILDCARDS = /\A\*+/

        # @!attribute filled [Boolean] the shell fills in digits the text
        #   only names, so the word is known as a pattern and not as text
        # @!attribute wild [Boolean] it holds a bare glob character, not only a fill
        Literal = Data.define(:text, :glob_at, :tilde, :pattern, :filled, :wild) do
          def glob? = !glob_at.nil?

          def take(count)
            with(text: text[...count], glob_at: (glob_at if glob_at && glob_at < count),
                 pattern: pattern.scan(/\\.|./m).take(count).join)
          end

          # The literal after its first `count` characters, as an option's
          # value is read. A `~` there is not at the start of a word.
          def drop(count)
            with(text: text[count..], glob_at: glob_at&.-(count), tilde: false,
                 pattern: pattern.scan(/\\.|./m).drop(count).join)
          end
        end

        # @param raw [String]
        # @return [Literal, nil] nil when any span cannot be read for certain
        def self.read(raw)
          scanner = StringScanner.new(raw)
          literal = Literal.new(text: "", glob_at: nil, tilde: raw.start_with?("~"), pattern: "", filled: false,
                                wild: false)
          literal = span(scanner, literal) until literal.nil? || scanner.eos?
          literal
        end

        def self.span(scanner, literal)
          if scanner.scan(SINGLE)
            quoted(literal, scanner[1])
          elsif scanner.scan(DOUBLE)
            double(literal, scanner[1])
          elsif scanner.scan(BARE)
            bare = scanner.matched
            glob = bare =~ GLOB
            literal.with(text: literal.text + bare, pattern: wildcard_joined(literal.pattern, bare),
                         glob_at: literal.glob_at || (glob && (literal.text.size + glob)),
                         wild: literal.wild || !glob.nil?)
          end
        end

        # A fill beside another wildcard matches what one does, and the `**`
        # they would spell reads as recursive.
        def self.wildcard_joined(pattern, addition)
          pattern.match?(OPEN_WILDCARD) ? pattern + addition.sub(LEADING_WILDCARDS, "") : pattern + addition
        end

        def self.double(literal, quoted)
          quoted.split(DOUBLE_PARTS).inject(literal) do |read, part|
            part.match?(DIGITS) ? filled(read, part) : quoted(read, part)
          end
        end

        def self.quoted(literal, text)
          literal.with(text: literal.text + text, pattern: literal.pattern + text.gsub(GLOB_CHARACTER) { "\\#{_1}" })
        end

        # An exit status, a process id or an argument count names no file of
        # its own, but it can finish a word that does, so it matches as `*`.
        def self.filled(literal, parameter)
          literal.with(text: literal.text + parameter, pattern: wildcard_joined(literal.pattern, "*"), filled: true,
                       glob_at: literal.glob_at || literal.text.size)
        end
        private_class_method :span, :wildcard_joined, :double, :quoted, :filled
      end

      # A program's words read as options, option values and operands, from the
      # value-taking options this object knows per program. Unquoted, because
      # bash passes `'-C'` as `-C`.
      class Argv
        COPIES = ["St", %w[--suffix --target-directory]].freeze
        GREP = ["efmABCDd", %w[
          --regexp --file --max-count --after-context --before-context --context --directories --devices
          --include --exclude --exclude-dir --exclude-from --label
        ]].freeze
        CC = ["DILo", %w[--output]].freeze
        AWK = ["fvFeE", %w[--file --assign --field-separator --source --exec]].freeze
        CURL_DATA = ["dFHXAue", %w[
          --data --data-ascii --data-raw --data-binary --data-urlencode --json --form --header --request
          --user-agent --user --referer
        ]].freeze

        CURL_FILES = ["KTbcEDrmwxyYzCUQtP", %w[
          --config --upload-file --cookie --cookie-jar --cert --dump-header --range --max-time --write-out --proxy
          --speed-time --speed-limit --time-cond --continue-at --proxy-user --quote --telnet-option --ftp-port
        ]].freeze

        # Values a program sends rather than opens. A commit's message is read
        # by {GitWrite}, which knows that subcommand's clusters.
        DATA_OPTIONS = { "curl" => CURL_DATA, "gh api" => ["f", %w[--raw-field]] }.freeze
        SHORT_NAMES = { "F" => "--form" }.freeze
        # curl reads the file after an `@`; a URL-encoded field's `@` counts
        # only before any `=`, and a form field is read by {CurlForm}.
        FILE_AT = /\A@/
        FILE_FORMS = { "--data-urlencode" => /\A[^=@]*@/ }.freeze
        FORM = "--form"

        # Without these a value reads as an operand or as a cluster of flags:
        # `-e s/a/b/` is sed's script, not its file, and `-Ispec` is not ruby's
        # `-e`.
        VALUES = {
          "cp" => COPIES, "mv" => COPIES, "ln" => COPIES,
          "install" => ["mogSt", %w[--mode --owner --group --suffix --target-directory]],
          "sed" => ["efl", %w[--expression --file --line-length]],
          "ruby" => ["IrCxE", []], "perl" => ["IMm", []], "python" => ["WX", []],
          "tar" => ["fCIFTXbgHKLNV", %w[
            --file --directory --use-compress-program --info-script --new-volume-script --files-from
            --exclude-from --to-command
          ]],
          "git" => ["Cco", %w[--output --output-directory --git-dir --namespace --work-tree]],
          "bundle" => ["", %w[--path --gemfile --jobs --retry --without --with]],
          "sort" => ["oTSkt", %w[--output --temporary-directory --buffer-size --key --field-separator]],
          "curl" => ["o#{CURL_DATA.first}#{CURL_FILES.first}", ["--output", *CURL_DATA.last, *CURL_FILES.last]],
          "wget" => ["OP", %w[--output-document --directory-prefix]],
          "rg" => ["efgmABCtTjMrEd", %w[
            --regexp --file --glob --max-count --type --type-not --threads --replace --ignore-file --iglob
            --max-depth --max-filesize --max-columns --encoding --engine --sort --sortr --type-add --type-clear
            --pre --pre-glob --colors --color --colour --context-separator --field-context-separator
            --field-match-separator --path-separator --hostname-bin --hyperlink-format --dfa-size-limit
            --regex-size-limit --after-context --before-context --context
          ]],
          "ag" => ["GgmABC", []], "ack" => ["mABC", []],
          **Programs::AWKS.to_h { [_1, AWK] },
          **%w[grep egrep fgrep zgrep].to_h { [_1, GREP] },
          **%w[cc gcc g++ c++ clang clang++ ld as rustc go].to_h { [_1, CC] }
        }.freeze

        NONE = ["", [].freeze].freeze
        LETTERS = /\A[A-Za-z0-9]*/
        TAR_CLUSTER = /\A[A-Za-z]+\z/

        attr_reader :words

        # @param words [Array<String>] unquoted, after the program
        # @param command [String] the program's canonical name
        def initialize(words, command)
          @command = command
          @old_tar = command == "tar" && TAR_CLUSTER.match?(words.first.to_s)
          @words = @old_tar ? ["-#{words.first}", *words.drop(1)] : words
          @end = @words.index("--") || @words.size
        end

        # @param index [Integer]
        # @return [Boolean] an option, or the `--` that ends them
        def option?(index) = index == @end || (index < @end && @words[index].start_with?("-") && @words[index] != "-")

        def options = @words.each_index.select { option?(_1) }

        # @return [Array<Integer>] neither an option nor an option's separate value
        def operands
          separate = values(*VALUES.fetch(@command, NONE)).reject { option?(_1) }
          @words.each_index.reject { option?(_1) || separate.include?(_1) }
        end

        # @param letters [String] short options
        # @param longs [Array<String>] long options
        # @param before [Integer, nil] only options before this word count
        # @return [Boolean]
        def flag?(letters, longs, before: nil)
          options.take_while { before.nil? || _1 < before }.any? do |index|
            word = @words[index]
            longs.include?(word.partition("=").first) ||
              (!word.start_with?("--") && cluster(index).count(letters).positive?)
          end
        end

        # A cluster's letters stop at its first value-taking letter, because
        # what follows is that letter's value. An old-style tar cluster takes
        # every value from the words after it, so all of it is letters.
        #
        # @param index [Integer]
        # @return [String]
        def cluster(index)
          letters = @words[index][1..][LETTERS]
          return letters if @old_tar && index.zero?

          value_at = letters.index(/[#{value_letters}]/) unless value_letters.empty?
          value_at ? letters[..value_at] : letters
        end

        # @param letters [String] short options
        # @param longs [Array<String>] long options
        # @return [Array<Integer>] the word holding each one's value: the
        #   option itself when attached, else a later word
        def values(letters, longs)
          options.flat_map do |index|
            word = @words[index]
            word.start_with?("--") ? long_value(index, longs) : short_value(index, letters)
          end
        end

        # @param letters [String] short options
        # @param longs [Array<String>] long options
        # @return [Array<String>] each one's value
        def value_texts(letters, longs)
          values(letters, longs).filter_map { value_text(_1) }
        end

        # @param index [Integer] a short option's word
        # @return [Integer, nil] where its attached value starts, or nil when
        #   this program's value-taking letters are not known
        def value_offset(index)
          return if value_letters.empty? || (@old_tar && index.zero?)

          at = @words[index][1..][LETTERS].index(/[#{value_letters}]/)
          at ? at + 2 : @words[index].size
        end

        # @return [Hash{Integer=>Array<Range>, nil}] each data option's value
        #   word, to the spans of its text that name a file it reads, or nil
        #   when they cannot be told
        def data_files
          letters, longs = DATA_OPTIONS[data_key]
          return {} unless letters

          options.filter_map { data_value(_1, letters, longs) }.to_h
        end

        # @param index [Integer] the word holding the value
        # @param start [Integer] where the value starts in it
        # @param name [String] the option's long name, or its letter
        # @return [Array(Integer, Array<Range>), Array(Integer, nil)]
        def data_at(index, start, name)
          text = @words[index].to_s[start..].to_s
          long = SHORT_NAMES.fetch(name, name)
          spans = long == FORM ? CurlForm.files(text) : at_file(FILE_FORMS.fetch(long, FILE_AT).match(text), text)
          [index, spans&.map { (_1.begin + start)...(_1.end + start) }]
        end

        private

        def value_letters = VALUES.fetch(@command, NONE).first

        def data_key = DATA_OPTIONS.key?(@command) ? @command : "#{@command} #{operands.first&.then { @words[_1] }}"

        def data_value(index, letters, longs)
          name, start = data_option(index, letters, longs)
          data_at(start ? index : index + 1, start || 0, name) if name
        end

        def at_file(match, text) = match ? [match.end(0)...text.size] : []

        # @return [Array(String, Integer), Array(String, nil), nil] the option's
        #   name, and where its value starts when attached
        def data_option(index, letters, longs)
          word = @words[index]
          if word.start_with?("--")
            name = word.partition("=").first
            [name, (name.size + 1 if word.include?("="))] if longs.include?(name)
          else
            at = letter_at(index, letters)
            [word[at + 1], (at + 2 if at + 2 < word.size)] if at
          end
        end

        def value_text(index)
          word = @words[index]
          return word unless word && option?(index)

          word.start_with?("--") ? word.partition("=").last : word[value_offset(index)..]
        end

        def long_value(index, longs)
          name, equals, = @words[index].partition("=")
          return [] unless longs.include?(name)

          [equals.empty? ? index + 1 : index]
        end

        def short_value(index, letters)
          return old_tar_values(letters) if @old_tar && index.zero?

          at = letter_at(index, letters)
          return [] if at.nil?

          [at == @words[index].size - 2 ? index + 1 : index]
        end

        def letter_at(index, letters)
          all = value_letters + letters
          run = @words[index][1..]
          at = run[LETTERS].index(/[#{all}]/) unless all.empty?
          at if at && letters.include?(run[at])
        end

        def old_tar_values(letters)
          taken = @words.first[1..].chars.select { value_letters.include?(_1) }
          taken.each_index.select { letters.include?(taken[_1]) }.map { _1 + 1 }
        end
      end

      # A git write that lands in this checkout, read by its own subcommand's
      # options rather than git's shared value letters, under which `commit -o`
      # and `restore -m`, both flags, would swallow the pathspec after them.
      class GitWrite
        NONE = ["", [].freeze].freeze

        # @!attribute flags [String] short options that take no value
        # @!attribute valued [String] short options that take the rest of the cluster or the next word
        # @!attribute attached [String] short options whose value can only be attached
        # @!attribute long_values [Array<String>] long options that take the next word when no `=` gives a value
        # @!attribute files [String] value options whose value names a file
        # @!attribute refused [Array(String, Array<String>)] options that leave it out of the class
        # @!attribute whole [Array(String, Array<String>)] options that reach the whole tree
        # @!attribute message [Array(String, Array<String>), nil] one of which a commit needs, or it opens an editor
        # @!attribute paths [Symbol] which operands are pathspecs: `:all`, `:separated` (after `--`), `:none`
        # @!attribute writes_paths [Boolean] it writes the files its pathspecs name, not only reads them
        # @!attribute rewrites [Boolean] a whole-tree option writes the tree, not only reads it
        Reading = Data.define(:flags, :valued, :attached, :long_values, :files, :refused, :whole, :message, :paths,
                              :writes_paths, :rewrites) do
          def initialize(flags: "", valued: "", attached: "", long_values: [].freeze, files: "", refused: NONE,
                         whole: NONE, message: nil, paths: :all, writes_paths: false, rewrites: false)
            super
          end

          def plain = flags + refused.first + whole.first

          # A letter that takes a value ends the cluster even where it is also
          # refused, as commit's `-c` is.
          def stops?(letter) = valued.include?(letter) || attached.include?(letter) || !plain.include?(letter)
        end

        # A stash, a tag and every other branch are shared with the main
        # checkout, so only writes to this checkout's files, index and own
        # branch are here. A skipped hook, a pathspec read from a file the judge
        # never sees, and an editor or prompt a headless run would wait on
        # forever are refused.
        NOT_LOCAL = %w[--no-verify --pathspec-from-file].freeze
        READINGS = {
          "commit" => Reading.new(
            flags: "qvsizo", valued: "mFtCc", attached: "uS", files: "Ft",
            long_values: %w[
              --author --date --message --file --template --reuse-message --reedit-message --fixup --squash --cleanup
              --trailer --pathspec-from-file
            ].freeze,
            refused: ["nepc", %w[--edit --patch --interactive --reedit-message].freeze], whole: ["a", %w[--all].freeze],
            message: ["mF", %w[--message --file --no-edit --reuse-message].freeze]
          ),
          "add" => Reading.new(flags: "nvfN", long_values: %w[--chmod].freeze,
                               refused: ["ipe", %w[--interactive --patch --edit].freeze],
                               whole: ["Au", %w[--all --update --no-ignore-removal].freeze]),
          "restore" => Reading.new(flags: "WSqm", valued: "s", long_values: %w[--source --conflict].freeze,
                                   refused: ["p", %w[--patch].freeze], writes_paths: true),
          "rm" => Reading.new(flags: "fnrq", writes_paths: true),
          "mv" => Reading.new(flags: "fknv", writes_paths: true),
          "reset" => Reading.new(flags: "qN", refused: ["p", %w[--patch].freeze],
                                 whole: ["", %w[--hard --merge --keep].freeze], rewrites: true),
          "checkout" => Reading.new(flags: "qfm", long_values: %w[--conflict].freeze,
                                    refused: ["pbBtl", %w[--patch --orphan --track].freeze],
                                    whole: ["", %w[--detach].freeze], paths: :separated, writes_paths: true,
                                    rewrites: true),
          "switch" => Reading.new(flags: "fmq", long_values: %w[--conflict].freeze,
                                  refused: ["cCt", %w[--create --force-create --orphan --track].freeze],
                                  whole: ["d", %w[--detach].freeze], paths: :none, rewrites: true)
        }.freeze
        MESSAGE = "--message"
        # git expands these itself, so the files they match are known only to it.
        MAGIC = /\A:|[*?\[]/

        # @param words [Array<String>] after the program, the subcommand first
        # @return [GitWrite, nil] nil for anything but a checkout-local write
        def self.of(words)
          reading = READINGS[words.first]
          write = reading && new(words, reading)
          write if write&.local?
        end

        def initialize(words, reading)
          @words = words
          @reading = reading
          @separator = nil
          @shorts = {}
          @longs = {}
          @taken = Set.new
          @unknown = false
          (1...words.size).each { scan(_1) }
        end

        # A letter the subcommand does not know might take a value, so the
        # pathspecs cannot be told from it. Its cwd is the top level, so a
        # relative pathspec with no `..` is the only one known, lexically, to
        # stay inside; a link inside the tree is still followed.
        def local?
          !@unknown && !has?(@reading.refused.first, [*@reading.refused.last, *NOT_LOCAL]) &&
            (@reading.message.nil? || has?(*@reading.message)) &&
            (@reading.paths == :all || whole? || pathspecs.any?) && pathspecs.none? { outside?(@words[_1]) }
        end

        # @return [Array<Integer>] the words, among those after the program, it takes as pathspecs
        def pathspecs
          case @reading.paths
          when :none then []
          when :separated then separated
          else (1...(@separator || @words.size)).reject { @taken.include?(_1) || option?(_1) } + separated
          end
        end

        def written = @reading.writes_paths ? pathspecs : []

        # @return [Array<Symbol>] `:git` for the `.git` it lands in, then
        #   `:root` or `:written` when it reaches the whole tree
        def implied
          matched = pathspecs.any? { MAGIC.match?(@words[_1]) }
          return [:git] unless whole? || matched

          writes = (whole? && @reading.rewrites) || (matched && @reading.writes_paths)
          [:git, writes ? :written : :root]
        end

        # @return [Hash{Integer=>Integer}] each `-m` or `--message` value's word,
        #   to where the message starts in it
        def messages
          shorts = @shorts.filter_map { |index, letters| value_at(index, letters.size + 1) if letters.end_with?("m") }
          longs = @longs.filter_map { |index, name| value_at(index, name.size + 1) if message_long?(name) }
          (shorts + longs).to_h
        end

        # @return [Integer, nil] where an attached message or template file starts
        def file_offset(index)
          letters = @shorts[index]
          letters.size + 1 if letters && !letters.empty? && @reading.files.include?(letters[-1])
        end

        private

        def option?(index) = @words[index].start_with?("-") && @words[index] != "-"

        def message_long?(name) = name.size > 2 && MESSAGE.start_with?(name)

        def value_at(index, start)
          word = @words[index]
          word.size > start || word.include?("=") ? [index, start] : [index + 1, 0]
        end

        def outside?(text) = text.start_with?("/", "~") || text.split("/").include?("..")

        def separated = @separator ? ((@separator + 1)...@words.size).to_a : []

        def whole? = has?(*@reading.whole)

        # git takes any unambiguous prefix of a long option, so a prefix counts as the option.
        def has?(letters, longs)
          @shorts.each_value.any? { _1.count(letters).positive? } ||
            @longs.each_value.any? { |name| name.size > 2 && longs.any? { _1.start_with?(name) } }
        end

        # A `--` ends the options only where it is not the value an option before it takes.
        def scan(index)
          return if @separator
          return @separator = index if @words[index] == "--" && !@taken.include?(index)

          read(index)
        end

        def read(index)
          return if @taken.include?(index) || !option?(index)

          text = @words[index]
          text.start_with?("--") ? read_long(index, text) : read_short(index, text[1..])
        end

        def read_long(index, text)
          name, equals, = text.partition("=")
          @longs[index] = name
          @taken << (index + 1) if equals.empty? && @reading.long_values.include?(name)
        end

        def read_short(index, run)
          at = run.each_char.find_index { @reading.stops?(_1) } || run.size
          @shorts[index] = run[0..at]
          read_stop(index, run[at], last: at == run.size - 1)
        end

        # The first letter that is not a plain flag: a value's, an attached
        # value's, or one this subcommand does not know.
        def read_stop(index, letter, last:)
          return if letter.nil?

          valued = @reading.valued.include?(letter)
          @unknown ||= !valued && !@reading.attached.include?(letter)
          @taken << (index + 1) if valued && last
        end
      end

      # What a program does with the words {Argv} read, where this object
      # knows it: whether it runs other programs or moves to another directory,
      # what it writes, and what it searches recursively.
      class Program
        RUNS_OTHERS = (Programs::TAKES_A_COMMAND - %w[find bundle] + Programs::WRAPPERS + Programs::PRIVILEGE +
                       Programs::SHELL_ESCAPES).freeze
        ALWAYS_OPAQUE = %w[irb deno busybox].freeze
        FROM_A_FILE = (Programs::INTERPRETERS - %w[sed] - Programs::AWKS).freeze
        STDIN_SCRIPT = %r{\A(-|/dev/stdin|/dev/fd/\d+|/proc/[^/]+/fd/\d+)\z}
        ASKS_FOR_HELP = %w[--version -v -V --help -h -version -help].freeze
        # gawk's other options load, include, dump or profile to files the words do not show.
        AWK_OPTION = /\A(--\z|-[Fv]|--(field-separator|assign)(=|\z))/

        TARS = %w[bsdtar gtar].freeze

        # The options through which these name a program to run.
        PROGRAM_OPTIONS = {
          "git" => ["c", %w[--config-env --exec-path]],
          "tar" => ["IF", %w[
            --to-command --use-compress-program --checkpoint-action --info-script --new-volume-script
          ]],
          "rsync" => ["e", %w[--rsh --rsync-path]],
          "sort" => ["", %w[--compress-program]]
        }.freeze

        # The git subcommands that print no file contents. An allowlist, because
        # nearly every other one can print a blob, a patch or a commit body (a
        # body can quote any file); `log` joins them only when it prints neither.
        # Last, those that take a `<rev>:<path>` whose path is relative to the
        # tree, not to the cwd.
        GIT_TREE_FREE = %w[status ls-files ls-tree rev-parse shortlog].freeze
        GIT_PATCH = ["puSGLUc", %w[
          --patch --unified --patch-with-stat --patch-with-raw --word-diff --color-words --cc --remerge-diff
        ]].freeze
        # The last of these git reads decides the format. A bare `--pretty` is
        # medium, which prints the body, as `log`'s default does.
        GIT_FORMAT_OPTION = /\A--(oneline\z|format(=|\z)|pretty(=|\z))/
        GIT_BODY_FORMATS = %w[medium full fuller raw email mboxrd].freeze
        GIT_BODY = /%[-+ ]?[bB]/
        GIT_REV_PATHS = %w[show cat-file diff grep ls-tree archive blame log].freeze
        REV_PATH = /\A[^:]*:(?:[0-3]:)?(.*)\z/m
        GIT_READ_ONLY = %w[
          log show diff status grep blame cat-file ls-files ls-tree rev-parse describe shortlog rev-list for-each-ref
        ].freeze
        UNZIP_ABSOLUTE = /\A-[^-]*:/

        FIND_ACTIONS = %w[-exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls].freeze
        FIND_FLAGS = %w[-H -L -P].freeze
        FIND_EXPRESSION = /\A[-(!]/

        # A list of exceptions rather than of directory changers, so a program
        # nobody listed -- ninja, bsdtar, pnpm -- stays opaque on `-C`.
        DIRECTORY_LETTERS = Hash.new("C").merge(
          %w[grep egrep fgrep zgrep rg ag ack diff ls].to_h { [_1, ""] },
          "patch" => "Cd", "unzip" => "Cd", "ruby" => "Cx", "perl" => "x"
        ).freeze
        DIRECTORY_LONG = %w[--directory --chdir --cwd --work-tree].freeze
        OWN_FLAG = { "ls" => %w[--directory], "install" => %w[--directory] }.freeze

        WRITES_EVERY_OPERAND = %w[tee touch mkdir rm rmdir mv truncate chmod chown chgrp].freeze
        WRITES_THE_DESTINATION = %w[cp ln install rsync scp].freeze
        TARGET = ["t", %w[--target-directory]].freeze
        OUTPUTS = {
          "sort" => ["o", %w[--output]], "curl" => ["o", %w[--output]],
          "wget" => ["OP", %w[--output-document --directory-prefix]],
          **%w[cc gcc g++ c++ clang clang++ ld as rustc go].to_h { [_1, ["o", %w[--output]]] }
        }.freeze
        GIT_OUTPUTS = ["o", %w[--output --output-directory]].freeze
        TAR_WRITES = ["cruA", %w[--create --append --update --concatenate]].freeze
        TOP_LEVEL = "--one-top-level="

        GREPS = %w[grep egrep fgrep zgrep].freeze
        RECURSES = {
          **GREPS.to_h { [_1, ["rR", %w[--recursive --dereference-recursive]]] },
          "cp" => ["rRa", %w[--recursive --archive]], "zip" => ["r", %w[--recurse-paths]],
          "diff" => ["r", %w[--recursive]], "rsync" => ["ra", %w[--recursive --archive]], "scp" => ["r", []]
        }.freeze
        ALWAYS_RECURSES = %w[rg ag ack].freeze
        # jq reads a module's file, from its library path, for each of these; a filter file may hold any of them.
        JQ_LOADS = /\b(?:import|include|modulemeta)\b/

        # @param texts [Array<String>] the stage's unquoted words, program first
        # @param untrusted [Boolean] the name may not be the program that runs,
        #   so only a reading that makes it opaque applies, never one that
        #   claims to know what it reads, writes or where it runs
        def initialize(texts, untrusted: false)
          @written_name = texts.first.to_s
          @name = @written_name.rpartition("/").last
          @command = TARS.include?(@name) ? "tar" : Programs.canonical(@name)
          @untrusted = untrusted
          @argv = Argv.new(texts.drop(1), @command)
          @displaced = OperandRoles.displaced?(@command, @argv)
          @git_from = git? ? subcommand_at : 0
          @git_write = GitWrite.of(@argv.words.drop(@git_from)) if git?
        end

        def git? = @command == "git" && !@untrusted

        def opaque? = runs_others? || changes_directory? || extracts_outside?

        # Every path it names may be one it writes.
        def untrusted? = @untrusted

        # @param index [Integer] into the words after the program
        def option?(index) = @argv.option?(index)

        # @param index [Integer] into the words after the program
        def value_offset(index)
          return if @untrusted

          return @argv.words[index].size if @command == "find"

          @git_write&.file_offset(index - @git_from) || @argv.value_offset(index)
        end

        # @return [Hash{Integer=>Array<Range>, nil}] see {Argv#data_files}
        def data_files = @untrusted ? {} : @argv.data_files.merge(commit_messages)

        # @return [Array<Integer>] the operands it reads as text rather than as files
        def unnamed
          return [] if @untrusted

          roles = OperandRoles.of(@command, operands.size, displaced: @displaced)
          operands.zip(roles).filter_map { |index, role| index unless role == :file }
        end

        # `dd if=x` opens `x`; the whole word names no file.
        def assignments? = @command == "dd" && !@untrusted

        # @return [Array<Integer>] the words, or the option words holding an
        #   attached value, that this program writes
        def written
          return [] if @untrusted

          case @command
          when *WRITES_EVERY_OPERAND then operands + @argv.values(*TARGET)
          when *WRITES_THE_DESTINATION then destination
          when "sed" then in_place
          when "dd" then operands.select { word(_1).start_with?("of=") }
          when "git" then git_written
          when "tar" then tar_written
          when "zip" then operands.first(1)
          when "bundle" then @argv.values("", %w[--path])
          else OUTPUTS.key?(@command) ? @argv.values(*OUTPUTS[@command]) : []
          end
        end

        # @return [Array<Integer>] the words it searches everything under
        def roots
          return [] if @untrusted

          case @command
          when "find" then find_roots
          when "git" then @git_write ? from_subcommand(@git_write.pathspecs) : []
          when *ALWAYS_RECURSES then searched
          when *RECURSES.keys then recursive_roots
          when "tar" then tar_creates? ? operands : []
          else []
          end
        end

        # @return [Array<Symbol>] `:root` when it searches the directory it runs
        #   in without naming it, `:written` when it writes there, which covers
        #   the reading too
        def implied
          return [] if @untrusted

          if implied_write? then [:written]
          elsif @git_write then @git_write.implied
          elsif (@command == "find" && find_roots.empty?) || (searches? && searched.empty?) || git_tree? then [:root]
          else []
          end
        end

        # @return [Hash{Integer=>String}] each `<rev>:<path>` operand's path
        def rev_paths
          return {} if @untrusted || !(@command == "git" && GIT_REV_PATHS.include?(word(operands.first)))

          operands.drop(1).each_with_object({}) do |index, found|
            match = REV_PATH.match(word(index))
            found[index] = match[1] if match
          end
        end

        # A git's one `-C`, written before the subcommand, names the directory
        # it runs in, so its stage can be read from there. A writing
        # subcommand is read only where the `-C` leads it alone, because its
        # write is read from the subcommand on, and another global option
        # could move where that write lands.
        #
        # @return [Integer, nil] the word, among those after the program, that holds the directory
        def git_directory
          subcommand = operands.first
          return unless @command == "git" && !@untrusted && subcommand

          found = @argv.values("C", [])
          entered = found.first if found.one? && found.first < subcommand && directory_option?(found.first)
          entered if entered && (GIT_READ_ONLY.include?(word(subcommand)) || leads_subcommand?(entered))
        end

        private

        def word(index) = index ? @argv.words[index].to_s : ""

        def operands = @argv.operands

        def runs_others?
          ([@name, @command].intersect?(RUNS_OTHERS) && !bare_env?) || ALWAYS_OPAQUE.include?(@command) ||
            (@command == "find" && @argv.words.intersect?(FIND_ACTIONS)) ||
            (PROGRAM_OPTIONS.key?(@command) && @argv.flag?(*PROGRAM_OPTIONS[@command], before: global_end)) ||
            (@command == "bundle" && @argv.words.first != "install") || runs_code? || sed_runs? || jq_loads?
        end

        # git's own options come before its subcommand; `git log -c` is log's.
        def global_end = @command == "git" ? operands.first : nil

        # With nothing to run, env prints the environment the child was lent.
        def bare_env? = @written_name == "env" && !@untrusted && @argv.words.empty?

        def subcommand_at
          entered = git_directory
          entered && leads_subcommand?(entered) ? operands.first : 0
        end

        # @param entered [Integer] the word holding the `-C` directory
        def leads_subcommand?(entered) = entered + 1 == operands.first && word(0).start_with?("-C")

        def from_subcommand(indexes) = indexes.map { _1 + @git_from }

        def commit_messages
          subcommand = operands.first
          return {} unless git? && word(subcommand) == "commit"

          write = GitWrite.new(@argv.words.drop(subcommand), GitWrite::READINGS["commit"])
          write.messages.to_h { |index, start| @argv.data_at(index + subcommand, start, GitWrite::MESSAGE) }
        end

        # Each of these may write a name the archive or patch chose, anywhere.
        def extracts_outside?
          case @command
          when "tar" then @argv.flag?("P", %w[--absolute-names])
          when "cpio" then @argv.flag?("i", %w[--extract]) && !@argv.flag?("", %w[--no-absolute-filenames])
          when "git" then word(operands.first) == "apply" && @argv.words.include?("--unsafe-paths")
          when "unzip" then @argv.options.any? { UNZIP_ABSOLUTE.match?(word(_1)) }
          else false
          end
        end

        def runs_code?
          if Programs::SHELLS.include?(@command)
            @argv.flag?("cs", %w[--command]) || stdin_script?
          elsif Programs::AWKS.include?(@command)
            !awk_reads_only?
          elsif FROM_A_FILE.include?(@command)
            @argv.flag?(*Programs::INLINE_CODE.fetch(@command, Argv::NONE)) || stdin_script?
          else
            false
          end
        end

        # A program file could hold any command, so only an inline one is read.
        def awk_reads_only?
          program = operands.first
          !program.nil? && @argv.options.all? { AWK_OPTION.match?(word(_1)) } && AwkScript.reads_only?(word(program))
        end

        # No script operand reads the program from stdin, unless all it asked
        # for was a version or help.
        def stdin_script?
          script = operands.first
          return STDIN_SCRIPT.match?(word(script)) if script

          !@argv.words.intersect?(ASKS_FOR_HELP)
        end

        # A script file sed has not been shown could hold any command, so only
        # `--sandbox`, which refuses the ones that reach outside, lets it by.
        def sed_runs?
          return false unless @command == "sed" && !@argv.flag?("", %w[--sandbox])

          @argv.flag?("f", %w[--file]) || sed_scripts.any? { !SedScript.safe?(_1) }
        end

        def sed_scripts
          from_options = @argv.value_texts("e", %w[--expression])
          from_options.empty? ? operands.first(1).map { word(_1) } : from_options
        end

        def jq_loads?
          @command == "jq" && (@argv.flag?("f", %w[--from-file]) || operands.any? { JQ_LOADS.match?(word(_1)) })
        end

        def changes_directory?
          entered = git_directory
          own = entered && (@argv.option?(entered) ? entered : entered - 1)
          @argv.options.any? { _1 != own && moves?(_1) }
        end

        def moves?(index)
          option = word(index)
          (DIRECTORY_LONG.include?(option.partition("=").first) && !own_flag?(option)) ||
            (!option.start_with?("--") && @argv.cluster(index).count(directory_letters).positive?)
        end

        # `-C` itself, not a cluster that happens to end in the letter.
        def directory_option?(value)
          @argv.option?(value) ? word(value).start_with?("-C") : word(value - 1) == "-C"
        end

        def own_flag?(option) = !@untrusted && OWN_FLAG.fetch(@command, []).include?(option)

        # An exception for `-C` narrows; an untrusted program keeps the default.
        def directory_letters = @untrusted ? "C#{DIRECTORY_LETTERS[@command]}" : DIRECTORY_LETTERS[@command]

        def destination
          return operands if @command == "install" && @argv.flag?("d", %w[--directory])

          targets = @argv.values(*TARGET)
          targets.empty? ? operands.last(1) : targets
        end

        def in_place
          return [] unless @argv.flag?("i", %w[--in-place])

          @displaced ? operands : operands.drop(1)
        end

        def git_written
          subcommand, *rest = operands
          return from_subcommand(@git_write.written) if @git_write

          case word(subcommand)
          when "clone" then rest.size >= 2 ? rest.last(1) : []
          when "init" then rest
          when "worktree" then word(rest.first) == "add" ? rest.drop(1) : []
          when "archive", "format-patch", "diff" then @argv.values(*GIT_OUTPUTS) + git_dir
          else git_dir
          end
        end

        def git_dir = GIT_READ_ONLY.include?(word(operands.first)) ? [] : @argv.values("", %w[--git-dir])

        def git_tree?
          return false unless @command == "git"

          subcommand = word(operands.first)
          return false if GIT_TREE_FREE.include?(subcommand)

          subcommand != "log" || @argv.flag?(*GIT_PATCH) || git_body?
        end

        def git_body?
          chosen = @argv.options.map { @argv.words[_1] }.grep(GIT_FORMAT_OPTION).last
          return true if chosen.nil?

          format = chosen == "--oneline" ? "oneline" : chosen.partition("=").last
          format.empty? || GIT_BODY_FORMATS.include?(format) || GIT_BODY.match?(format)
        end

        def implied_write?
          subcommand, *rest = operands
          case [@command, word(subcommand)]
          in ["git", "clone"] then rest.size < 2
          in ["git", "init"] then rest.empty?
          in ["bundle", "install"] then true
          else false
          end
        end

        def tar_creates? = @argv.flag?(*TAR_WRITES)

        def tar_written
          archive = tar_creates? ? @argv.values("f", %w[--file]) : []
          archive + @argv.words.each_index.select { word(_1).start_with?(TOP_LEVEL) }
        end

        def find_roots
          indexes = @argv.words.each_index.drop_while { FIND_FLAGS.include?(word(_1)) }
          indexes.take_while { !FIND_EXPRESSION.match?(word(_1)) }
        end

        def searches? = ALWAYS_RECURSES.include?(@command) || (GREPS.include?(@command) && recursive?)

        def recursive? = @argv.flag?(*RECURSES.fetch(@command))

        # A searcher's first operand is its pattern unless an option gave one.
        def searched = @displaced ? operands : operands.drop(1)

        def recursive_roots
          return [] unless recursive?

          case @command
          when "cp" then @argv.values(*TARGET).empty? ? operands[0...-1] : operands
          when "rsync", "scp" then operands[0...-1]
          when "zip" then operands.drop(1)
          when "diff" then operands
          else searched
          end
        end
      end

      # An inline awk program read for what reaches past the files it is given:
      # `system` and a pipe run a command, `getline` reads a file or a command,
      # `ARGV` and `ARGC` choose the files read, `@` loads, includes or calls
      # code by name, and a `>` after a `print` may be its output redirect.
      # Matched anywhere in the text, a string or regex included, so nothing
      # can hide inside one; the cost is a false positive.
      module AwkScript
        REACHES_OUT = /system|getline|ARGV|ARGC|@|\|/
        PRINT_REDIRECT = /print.*>/m
        OR = "||"

        # @param program [String]
        # @return [Boolean]
        def self.reads_only?(program)
          !program.gsub(OR, "").match?(REACHES_OUT) && !program.match?(PRINT_REDIRECT)
        end
      end

      # A curl form field's value read for the files curl opens, as curl's
      # own parser reads them: an `@` file and each one after a `,`, or one
      # `<` file, then a `headers=@` or `headers=<` file after any `;`. A name
      # ends at a `;`, and among `@` uploads at a `,` too; blanks around an
      # unquoted name are not part of it. A quoted name is read when it holds
      # no backslash, which curl unescapes.
      module CurlForm
        BLANKS = /[ \t\n\v\f\r]*/
        HEADERS = /headers=[@<]/i
        QUOTED = /"([^"\\]*)"/
        ESCAPED = /"(?:[^"\\]|\\.)*"/m
        UPLOAD_NAME = /[^;,]*/
        FIELD_NAME = /[^;]*/

        # @param text [String] the field, `name=value`
        # @return [Array<Range>, nil] nil when a name cannot be read for certain
        def self.files(text)
          equals = text.index("=")
          return [] if equals.nil?

          scanner = StringScanner.new(text)
          scanner.pos = equals + 1
          upload = !scanner.skip(/@/).nil?
          found = part(scanner, upload, upload || !scanner.skip(/</).nil?)
          found.concat(part(scanner, upload, true)) while upload && scanner.skip(/,/)
          found.include?(:unread) ? nil : found
        end

        def self.part(scanner, upload, read)
          name = word(scanner, upload)
          found = read ? [name] : []
          found.concat(parameter(scanner, upload)) while scanner.skip(/;/)
          found
        end

        def self.parameter(scanner, upload)
          scanner.skip(BLANKS)
          headers = scanner.skip(HEADERS)
          name = word(scanner, upload)
          headers ? [name] : []
        end

        # @return [Range, Symbol] the name's span, or `:unread`
        def self.word(scanner, upload)
          scanner.skip(BLANKS)
          start = scanner.pos
          return quoted(scanner, upload, start) if scanner.check(ESCAPED)

          scanner.skip(upload ? UPLOAD_NAME : FIELD_NAME)
          start...(start + scanner.matched.rstrip.size)
        end

        # curl ignores what follows a closing quote, up to the name's end.
        def self.quoted(scanner, upload, start)
          name = scanner.scan(QUOTED) ? (start + 1)...(scanner.pos - 1) : :unread
          scanner.skip(ESCAPED) if name == :unread
          scanner.skip(upload ? UPLOAD_NAME : FIELD_NAME)
          name
        end
        private_class_method :part, :parameter, :word, :quoted
      end

      # A sed script read for the commands that reach outside sed: `e` runs one,
      # `r` and `R` read a file in, `w` and `W` write one, and an `s` command
      # flagged `e` or `w` does the same. Letters inside a regex, an `s` body, a
      # label or a text command's text are not commands. Anything it cannot
      # read through is unsafe.
      class SedScript
        OUTSIDE = /[erRwW]/
        SKIPPED = /\s+|[;!{}$,~+=#]|\d+/
        LABEL = /[:btT][^;\n]*/
        TEXT = /[aic][^\n]*/
        FLAGS = /[^;\n}]*/

        # @param script [String]
        # @return [Boolean]
        def self.safe?(script)
          scanner = StringScanner.new(script)
          safe = true
          safe = command_safe?(scanner) while safe && !scanner.eos?
          safe
        end

        def self.command_safe?(scanner)
          if scanner.scan(SKIPPED) || scanner.scan(LABEL) || scanner.scan(TEXT) then true
          elsif scanner.scan(%r{/}) then closed?(scanner, "/")
          elsif scanner.scan(/\\(.)/m) then closed?(scanner, scanner[1])
          elsif scanner.scan(/[sy]/) then substitution_safe?(scanner, scanner.matched)
          else !OUTSIDE.match?(scanner.getch)
          end
        end

        # The flags are read here rather than as commands, because the `i` flag
        # would read as the `i` command and swallow the rest of the line.
        def self.substitution_safe?(scanner, kind)
          delimiter = scanner.getch
          return false if delimiter.nil? || delimiter.match?(/[\\\n]/)
          return false unless 2.times.all? { closed?(scanner, delimiter) }

          kind == "y" || !scanner.scan(FLAGS).match?(/[ew]/)
        end

        def self.closed?(scanner, delimiter)
          quoted = Regexp.escape(delimiter)
          !scanner.scan(/(?:[^\\#{quoted}]|\\.)*#{quoted}/m).nil?
        end
        private_class_method :command_safe?, :substitution_safe?, :closed?
      end

      # Where a parse's compound statements bound its stages and redirects:
      # which subshell a stage runs in, which loop repeats it, and which
      # redirect bash applies to a whole compound rather than to one stage.
      # Mutable while a walk enters and leaves subshells.
      class Compounds
        SUBSHELL = "subshell"
        LOOP = "while_statement"

        # @param result [Parse::Result]
        def initialize(result)
          @result = result
          @open = []
        end

        # Bash opens one where its compound starts, so it lands where the walk
        # started only when no stage before it moved the shell.
        #
        # @yieldparam stage [Parse::Stage] one that starts before a redirect no stage owns
        # @yieldreturn [Boolean] whether that stage may move the shell
        # @return [Array<Parse::Redirect>, nil] those no stage owns; nil when a stage before one moved
        def unowned_at_start
          found = unowned
          found unless found.any? { |redirect| @result.stages.any? { before?(_1, redirect) && yield(_1) } }
        end

        # Each unowned redirect follows a compound with no stage or join
        # between, so bash applies it to the whole of that compound.
        def readable? = unowned.all? { trailing?(_1.byte_range.begin) }

        # @param at [Integer] where a stage starts
        def looped?(at) = !ranges(LOOP, at).empty?

        # Bash runs a subshell in a copy of the shell, so leaving one restores
        # the state it was entered with.
        #
        # @param at [Integer] where the next stage starts
        # @param state [Object] the walk's state before it
        # @return [Object] the state the stage runs with
        def enter(at, state)
          left = @open.reject { |range, _| range.cover?(at) }
          state = left.first.last unless left.empty?
          @open -= left
          entered = ranges(SUBSHELL, at).reject { |range| @open.any? { _1.first == range } }
          @open.concat(entered.map { [_1, state] })
          state
        end

        private

        def unowned = @result.redirects - @result.stages.flat_map(&:redirects)

        def before?(stage, redirect) = stage.byte_range.begin < redirect.byte_range.begin

        def ranges(kind, at)
          @result.compounds.select { _1.kind == kind && _1.byte_range.cover?(at) }.map(&:byte_range)
        end

        def trailing?(at)
          @result.compounds.any? do |compound|
            from = compound.byte_range.end
            from <= at && [*@result.stages, *@result.separators].none? { _1.byte_range.begin.between?(from, at) }
          end
        end
      end

      # One pass over a parse, stage by stage, carrying the directory a bound
      # `cd` moved to. Mutable while it walks; what it hands back is frozen.
      class Walk
        # Literal structure and the compound statements whose keywords the parse
        # places. Anything else -- an expansion, a function, a case -- is read as
        # opaque. A simple expansion, an assignment and a heredoc are here only
        # because {Word}, {HARMLESS_ASSIGNMENT} and the heredoc check read the few
        # they can and refuse every other. A substitution is here so the walk
        # reaches it, and it never reads, since bash splits and globs what it prints.
        READABLE_KINDS = %w[
          program list pipeline command command_name word number concatenation
          raw_string string simple_expansion file_redirect redirected_statement comment
          variable_assignment heredoc_redirect command_substitution
          subshell compound_statement while_statement if_statement
        ].freeze

        # An allowlist, because a name nobody listed may choose the program
        # (`PATH`), load code (`LD_PRELOAD`, `BASH_ENV`) or name a file the
        # words do not; a value with no slash keeps a locale or zone off disk.
        HARMLESS_ASSIGNMENT = /\A(?:RUST_BACKTRACE|RUST_LOG|NO_COLOR|FORCE_COLOR|CLICOLOR(?:_FORCE)?|COLUMNS|
                                LANG|LANGUAGE|LC_[A-Z]+|TZ)=[A-Za-z0-9_.,:@+-]*\z/x
        # Quoted whole, so the body is not expanded and the word bash ends it on is known for certain.
        QUOTED_DELIMITER = /\A(?:'(\w+)'|"(\w+)"|\\(\w+))\z/
        BLANK_LINE = /\A[ \t]*\z/
        DASHED = "<<-"
        LEADING_TABS = /\A\t+/
        ENV = "env"
        # bash expands a `~` after the `=` or a `:` of an assignment, which the argv would not show.
        ASSIGNED_TILDE = /[=:]~/
        # A builtin's prefix assignments can outlive the stage, and these run another command in the shell.
        IN_THE_SHELL = %w[exec command builtin eval source .].freeze

        DIRECTORY_CHANGERS = %w[cd pushd popd].freeze
        # Each changes how bash expands the words after it: `dotglob` lets `*`
        # match `.env`, `set -f` stops globbing, `globstar` makes `**` recurse.
        SHELL_OPTIONS = %w[shopt set].freeze
        AND = "&&"
        AFTER_A_CD = [AND, "|"].freeze
        LONG_VALUE = /\A--[^=]+=/
        SHORT_LETTERS = /\A-[A-Za-z0-9]*/
        ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
        DUPLICATIONS = %w[>& <&].freeze
        DESCRIPTOR = /\A(\d+|-)\z/
        NOT_A_NAME = ["", ".", ".."].freeze
        LONE_DASH = "-"
        RECURSIVE = "**"

        Words = Data.define(:raws, :literals) do
          # An unreadable word stays as written; naming it makes the command opaque.
          def texts = literals.zip(raws).map { |literal, raw| literal&.text || raw }
        end

        def initialize(result, cwd:, home:)
          @result = result
          @home = home if home.is_a?(String) && home.start_with?("/")
          @dir = cwd
          @moved = false
          @paths = []
          @opaque = false
          @directories = []
          @compounds = Compounds.new(result)
        end

        # @return [Named]
        def named
          return UNREADABLE unless readable?

          compound_redirects && @result.stages.each_index.all? { |index| step(index) }
          Named.new(paths: @paths.uniq.freeze, opaque: @opaque)
        end

        # @return [Array<Array(Array<String>, String)>, nil]
        def stages
          return unless readable?

          placed = directories
          argvs = @result.stages.each_with_index.map { |stage, index| argv_of(stage, placed[index]) }
          argvs.zip(placed) if argvs.all? { |argv| argv&.any? && argv.none?(&:nil?) }
        end

        # @return [Array<String, nil>]
        def directories
          stages = @result.stages.size
          return Array.new(stages) unless readable?

          @result.stages.each_index.all? { |index| step(index) }
          @directories + Array.new(stages - @directories.size)
        end

        private

        def readable?
          @result.covered? && (@result.kinds - READABLE_KINDS).empty? && @compounds.readable? &&
            @result.heredocs.all? { literal_heredoc?(_1) } && @result.assignments.all? { prefixes_a_stage?(_1) }
        end

        # The rest of its line must be blank, since a word or command there is
        # folded into the heredoc and would run unread. The grammar also ends
        # one on lines bash does not, ` EOF` or `EOF;x`, so the line it ended
        # on must be the word exactly. And it can run past an exact end line,
        # as it does after a lone `\` line, so no body line may match the word.
        def literal_heredoc?(heredoc)
          word = heredoc.delimiter[/\w+/] if heredoc.delimiter.match?(QUOTED_DELIMITER)
          lines = heredoc.lines.map { heredoc.operator == DASHED ? _1.sub(LEADING_TABS, "") : _1 }
          *body, ending = lines
          !word.nil? && heredoc.rest_of_line.match?(BLANK_LINE) && ending == word &&
            body.none? { _1.match?(/\A\s*#{word}(?:[\s;&|#]|\z)/) }
        end

        def compound_redirects
          unowned = @compounds.unowned_at_start { DIRECTORY_CHANGERS.include?(words_of(_1).texts.first) }
          return halt unless unowned

          found = unowned.filter_map { redirect_path(_1) }
          @opaque ||= found.include?(:opaque)
          @paths.concat(found.grep(Path))
          true
        end

        # One standing alone sets the variable for every stage after it.
        def prefixes_a_stage?(range) = @result.stages.any? { _1.byte_range.cover?(range.begin) }

        def assigned(stage) = stage.argv.take(@result.assignments.count { stage.byte_range.cover?(_1.begin) })

        # @return [Boolean, nil] nil once the rest of the command is opaque
        def step(index)
          stage = @result.stages[index]
          @dir, @moved = @compounds.enter(stage.byte_range.begin, [@dir, @moved])
          return halt if @moved && !AFTER_A_CD.include?(join_before(index))

          words = words_of(stage)
          @directories << @dir
          return halt if changes_the_shell?(stage, words)
          return change_directory(index, stage, words) if DIRECTORY_CHANGERS.include?(words.texts.first)

          name(stage, words)
          true
        end

        def changes_the_shell?(stage, words)
          assigned = assigned(stage)
          program = words.texts.first
          !assigned.all?(HARMLESS_ASSIGNMENT) || (assigned.any? && in_the_shell?(program)) ||
            SHELL_OPTIONS.include?(program)
        end

        def in_the_shell?(program)
          (Verdict.builtin?(program) || IN_THE_SHELL.include?(program)) && !DIRECTORY_CHANGERS.include?(program)
        end

        def argv_of(stage, directory)
          literals = words_of(stage).literals
          return if assigned(stage).any? { _1.match?(ASSIGNED_TILDE) }

          assignments = assigned(stage).map { Word.read(_1) }
          return if [*literals, *assignments].any? { _1.nil? || _1.filled }

          argv = literals.flat_map { |literal| literal.glob? ? expanded(literal, directory) : [bash_text(literal)] }
          wrapped(assignments.map(&:text), argv)
        end

        # A stage's own assignments reach its program as `env` would lend them,
        # and a cd's stay with the shell, which runs it; nil for any other builtin.
        def wrapped(assignments, argv)
          return argv if assignments.empty? || argv.empty? || DIRECTORY_CHANGERS.include?(argv.first)

          [ENV, *assignments, *argv] unless in_the_shell?(argv.first)
        end

        def expanded(literal, directory)
          return [nil] if directory.nil? || literal.tilde || literal.pattern.include?(RECURSIVE)

          matches = Dir.glob(literal.pattern, base: directory).sort
          matches.empty? ? [literal.text] : matches
        end

        def bash_text(literal)
          return literal.text unless literal.tilde

          @home && literal.text.match?(HOMED) ? @home + literal.text.delete_prefix("~") : nil
        end

        def words_of(stage)
          raws = [*stage.argv.drop(assigned(stage).size), *stage.redirects.flat_map(&:extra_words)]
          Words.new(raws:, literals: raws.map { Word.read(_1) })
        end

        def halt
          @opaque = true
          nil
        end

        # A `cd` binds what follows only when its directory is literal and `&&`
        # joins it on both sides: after `;`, `||` or `&` the next stage may run
        # where the cd failed to leave, a cd after `||` may never run, and a cd
        # in a pipeline runs in a subshell. In a loop, each pass starts where the
        # last one left.
        def change_directory(index, stage, words)
          target = cd_target(words)
          return halt unless target && joined_by_and?(index) && !@compounds.looped?(stage.byte_range.begin)

          @paths << Path.new(word: -words.raws.last, resolved: target, written: false, directory: true, pattern: nil)
          @dir = target
          @moved = true
          true
        end

        def joined_by_and?(index)
          (index.zero? || join_before(index) == AND) &&
            (index == @result.stages.size - 1 || join_before(index + 1) == AND)
        end

        def cd_target(words)
          return unless words.texts in ["cd", _]

          literal = words.literals.last
          resolve(literal) if literal && !literal.text.start_with?("-") && !literal.glob?
        end

        def name(stage, words)
          inner = unbundled(words)
          program = Program.new(inner.texts, untrusted: !inner.equal?(words))
          named = program.opaque? || filled_option?(inner) ? [:opaque] : stage_paths(stage, inner, program)
          @opaque ||= named.include?(:opaque)
          @paths.concat(named.grep(Path))
        end

        # Argv reads an option's letters from its text, but bash hands the
        # program digits where a fill sits, so the cluster it runs is unknown.
        def filled_option?(words) = words.literals.any? { _1&.filled && _1.text.start_with?("-") }

        # `bundle exec X` runs X as the bundle resolves it -- a binstub, or a
        # gem's code loaded first -- so X may not be the program its name says,
        # and only the readings that make it opaque still apply.
        def unbundled(words)
          bundle, exec, program = words.texts
          return words unless bundle.to_s.rpartition("/").last == "bundle" && exec == "exec" &&
                              program && !program.start_with?("-")

          Words.new(raws: words.raws.drop(2), literals: words.literals.drop(2))
        end

        def stage_paths(stage, words, program)
          named = [*program_path(words), *program_paths(words, program), *redirect_paths(stage)]
          program.untrusted? ? named.map { possibly_written(_1) } : named
        end

        def program_paths(words, program)
          index = program.git_directory
          return within_directory(words, program) if index.nil?

          entered = word_paths(words, program, only: index).map { _1.is_a?(Path) ? _1.with(directory: true) : _1 }
          return [:opaque] unless entered.one? && entered.first.is_a?(Path) && entered.first.pattern.nil?

          [*entered, *in_directory(entered.first.resolved) { within_directory(words, program, except: index) }]
        end

        def within_directory(words, program, except: nil)
          [*word_paths(words, program, except:), *rev_paths(program), *implied_paths(program)]
        end

        # Every later `..` is unsafe there, as after a `cd`.
        def in_directory(directory)
          before = [@dir, @moved]
          @dir = directory
          @moved = true
          yield
        ensure
          @dir, @moved = before
        end

        def possibly_written(found) = found.is_a?(Path) ? found.with(written: true) : found

        # A path inside a revision is relative to the tree's root, which may sit
        # above the cwd, so it may match anywhere below it.
        def rev_paths(program)
          program.rev_paths.values.map { rev_path(_1.delete_prefix("./")) }
        end

        def rev_path(inside)
          return :opaque if inside.start_with?("/") || inside.split("/").include?("..")

          Path.new(word: -inside, resolved: File.expand_path(File.join(@dir, inside)).freeze, written: false,
                   directory: false, pattern: File.join(@dir, "**", inside).freeze)
        end

        def implied_paths(program)
          program.implied.map { _1 == :git ? dotgit : tree(_1, program) }
        end

        def tree(kind, program)
          Path.new(word: "", resolved: @dir, written: kind == :written, directory: false,
                   pattern: File.join(@dir, "**").freeze, git: program.git?)
        end

        def dotgit
          Path.new(word: "", resolved: File.join(@dir, ".git").freeze, written: true, directory: false, pattern: nil,
                   git: true)
        end

        def redirect_paths(stage) = stage.redirects.map { redirect_path(_1) }

        def program_path(words)
          literal = words.literals.first
          return :opaque if literal.nil? || literal.filled

          path(words.raws.first, literal, written: false) if literal.text.include?("/")
        end

        def word_paths(words, program, only: nil, except: nil)
          written = program.written
          roots = program.roots
          data = program.data_files
          unnamed = program.unnamed
          chosen(words, only, except).flat_map do |index|
            literal = words.literals[index + 1]
            if literal.nil? then [:opaque]
            elsif unnamed.include?(index) then []
            elsif data.key?(index) then data_paths(words.raws[index + 1], literal, data[index])
            else argument_paths(words, index, program, written: written.include?(index), root: roots.include?(index))
            end
          end
        end

        def argument_paths(words, index, program, written:, root:)
          raw = words.raws[index + 1]
          literal = words.literals[index + 1]
          return option_paths(raw, literal, program.value_offset(index), written) if program.option?(index)

          operand_paths(raw, literal, written:, root:, assignment: program.assignments?, git: program.git?)
        end

        def chosen(words, only, except)
          words.raws.drop(1).each_index.select { (only.nil? || _1 == only) && _1 != except }
        end

        # Where the program's value letters are not known, an attached value
        # could start after any letter: `-xzf/x` might be `zf/x`, `f/x` or `/x`.
        def option_paths(raw, literal, offset, written)
          text = literal.text
          return [] if text == "--"

          unless text.start_with?("--")
            cuts = offset ? [offset] : (2..text[SHORT_LETTERS].to_s.size)
            return cuts.map { path(raw, literal.drop(_1), written:, guess: offset.nil?) }
          end

          match = LONG_VALUE.match(text)
          return [] if match.nil?

          value_paths(raw, literal, match.end(0), written:)
        end

        # `cat a=b` opens `a=b`, so a name=value operand names the whole word and its
        # value; `dd if=x` opens only `x`, so dd names the value alone.
        def operand_paths(raw, literal, written:, root:, assignment:, git:)
          whole = path(raw, literal, written:, root:, git: root && git)
          match = ASSIGNMENT.match(literal.text)
          return [whole] if match.nil?

          [*(whole unless assignment), *value_paths(raw, literal, match.end(0), written:)]
        end

        # A value bash would glob may expand to more words, or to an `@` name,
        # so it is known only where its one file runs to its end.
        def data_paths(raw, literal, files)
          return [:opaque] if files.nil? || (literal.wild && !(files.one? && files.first.end == literal.text.size))

          files.map { file_path(raw, literal, _1) }
        end

        def file_path(raw, literal, span)
          file = literal.take(span.end).drop(span.begin)
          file.glob_at&.negative? ? :opaque : path(raw, file, written: false)
        end

        # Bash expands a `~` after the `=` of an argument shaped like an
        # assignment, and after a `:` in one; `/bin/sh` in posix mode expands
        # neither. Which applies depends on the shell and the argument's shape,
        # so a leading `~` is named both ways, and one after a `:` is opaque.
        def value_paths(raw, literal, offset, written:)
          value = literal.drop(offset)
          tilde = value.text.start_with?("~")
          return [:opaque] if value.text.include?(":~") || value.glob_at&.negative?

          [path(raw, value, written:), (path(raw, value.with(tilde: true), written:) if tilde)].compact
        end

        def redirect_path(redirect)
          return if DUPLICATIONS.include?(redirect.operator) && DESCRIPTOR.match?(redirect.target)

          literal = Word.read(redirect.target)
          return :opaque if literal.nil?

          found = path(redirect.target, literal, written: redirect.operator.include?(">"))
          found unless found.is_a?(Path) && found.resolved == File::NULL
        end

        def path(raw, literal, written:, root: false, guess: false, git: false)
          return if literal.text.empty? || literal.text == LONE_DASH

          resolved = resolve(literal)
          return :opaque if resolved.nil?

          Path.new(word: -raw, resolved:, written:, directory: false, pattern: pattern(literal, resolved, root),
                   guess:, git:)
        end

        def pattern(literal, resolved, root)
          if literal.glob?
            fixed = literal.text[0...literal.glob_at][%r{\A.*/}].to_s
            File.join(resolved, literal.pattern.split("/", -1).drop(fixed.count("/")).join("/")).freeze
          elsif root
            File.join(resolved, "**").freeze
          end
        end

        # A quoted `~` is a file name, so a relative path is joined rather than
        # handed to `File.expand_path`, which would expand it.
        def resolve(literal)
          return unless lexical?(literal.text)

          text = literal.glob? ? literal.text[0...literal.glob_at][%r{\A.*/}].to_s : literal.text
          return home_path(text) if literal.tilde

          File.expand_path(text.start_with?("/") ? text : File.join(@dir, text)).freeze
        end

        # `File.expand_path` folds `a/..` without asking where `a` leads, and a
        # symlink decides that. A leading `..` is safe only in the directory the
        # call was given, not in one a `cd` entered.
        def lexical?(text)
          segments = text.split("/")
          segments.each_index.none? do |index|
            segments[index] == ".." && (@moved || segments.take(index).any? { !NOT_A_NAME.include?(_1) })
          end
        end

        def home_path(text)
          return unless @home && (text == "~" || text.start_with?("~/"))

          File.expand_path(File.join(@home, text.delete_prefix("~"))).freeze
        end

        # The operator joining a stage to the one before it, or nil when there is
        # none -- a newline, which the grammar reports as no separator at all.
        # Anything else between two stages is uncovered, and opaque already.
        def join_before(index)
          from = stage_end(@result.stages[index - 1])
          to = @result.stages[index].byte_range.begin
          between = @result.separators.select { from <= _1.byte_range.begin && _1.byte_range.end <= to }
          between.first.text if between.size == 1
        end

        def stage_end(stage) = [stage.byte_range.end, *stage.redirects.map { _1.byte_range.end }].max
      end

      private_constant :Argv, :GitWrite, :Program, :AwkScript, :SedScript, :Walk
    end
  end
end
