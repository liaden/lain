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
    # A bare word is named as a path too (`grep password src` names
    # `/p/password`): a word that is not a file costs a false positive, while
    # skipping one that is would be a bypass.
    class Named
      # @!attribute word [String] as the model wrote it, quotes included
      # @!attribute resolved [String] absolute; for a glob, its fixed directory
      # @!attribute written [Boolean] whether the command writes it, as far as
      #   {#written} knows
      # @!attribute directory [Boolean] a `cd` target the later stages run in
      # @!attribute pattern [String, nil] the absolute glob this path stands
      #   for, with a quoted glob character escaped: the word's own glob, or
      #   `<root>/**` for a search root such as find's
      Path = Data.define(:word, :resolved, :written, :directory, :pattern)

      # @param command [String] the command as the model wrote it
      # @param cwd [String] absolute directory the call runs in
      # @param home [String, nil] for `~`, from {Sensitivity::Policy#home}; a
      #   `~` word with none makes the command opaque
      # @return [Named]
      def self.of(command, cwd:, home:) = from(Parse.new.call(command), cwd:, home:)

      # @param result [Parse::Result] a parse a caller already holds
      # @param cwd [String] absolute directory the call runs in
      # @param home [String, nil] as for {.of}
      # @return [Named] opaque on a relative or missing cwd, against which no
      #   path resolves to where the call lands
      def self.from(result, cwd:, home:)
        return UNREADABLE unless cwd.is_a?(String) && cwd.start_with?("/")

        Walk.new(result, cwd:, home:).named
      end

      def opaque? = opaque

      # A lower bound: an output redirect's target, and the operands and output
      # options of the writers {Argv} lists. A program it does not list may
      # write any path it names, and that path is named as read.
      #
      # @return [Array<Path>]
      def written = paths.select(&:written)

      UNREADABLE = new(paths: [].freeze, opaque: true)

      # One word's quoting undone, when every span of it is literal: a
      # single-quoted span as written, a double-quoted one only when it holds
      # nothing bash would interpret, and bare text with no backslash, expansion
      # or brace. A quoted `*` is a file name and a bare one is not, so the
      # pattern escapes what was quoted.
      class Word
        SINGLE = /'([^'\0]*)'/
        DOUBLE = /"([^"$`\\!\0]*)"/
        BARE = /[^'"\\$`{\0]+/
        GLOB = /[*?\[]/
        GLOB_CHARACTER = /[*?\[\]\\{}]/

        Literal = Data.define(:text, :glob_at, :tilde, :pattern) do
          def glob? = !glob_at.nil?

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
          literal = Literal.new(text: "", glob_at: nil, tilde: raw.start_with?("~"), pattern: "")
          literal = span(scanner, literal) until literal.nil? || scanner.eos?
          literal
        end

        def self.span(scanner, literal)
          if scanner.scan(SINGLE) || scanner.scan(DOUBLE)
            quoted = scanner[1]
            literal.with(text: literal.text + quoted,
                         pattern: literal.pattern + quoted.gsub(GLOB_CHARACTER) { "\\#{_1}" })
          elsif scanner.scan(BARE)
            bare = scanner.matched
            glob = bare =~ GLOB
            literal.with(text: literal.text + bare, pattern: literal.pattern + bare,
                         glob_at: literal.glob_at || (glob && (literal.text.size + glob)))
          end
        end
        private_class_method :span
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
          "git" => ["co", %w[--output --output-directory --git-dir --namespace --work-tree]],
          "bundle" => ["", %w[--path --gemfile --jobs --retry --without --with]],
          "sort" => ["oTSkt", %w[--output --temporary-directory --buffer-size --key --field-separator]],
          "curl" => ["o", %w[--output]], "wget" => ["OP", %w[--output-document --directory-prefix]],
          "rg" => ["efgmABCtTjMr", %w[--regexp --file --glob --max-count --type --type-not --threads --replace]],
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

        private

        def value_letters = VALUES.fetch(@command, NONE).first

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

          all = value_letters + letters
          run = @words[index][1..]
          at = run[LETTERS].index(/[#{all}]/) unless all.empty?
          return [] if at.nil? || !letters.include?(run[at])

          [at == run.size - 1 ? index + 1 : index]
        end

        def old_tar_values(letters)
          taken = @words.first[1..].chars.select { value_letters.include?(_1) }
          taken.each_index.select { letters.include?(taken[_1]) }.map { _1 + 1 }
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

        # The git subcommands that read the whole tree, and those that take a
        # `<rev>:<path>` whose path is relative to the tree, not to the cwd.
        GIT_TREE_READERS = %w[diff log show grep stash blame].freeze
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
          "diff" => ["r", %w[--recursive]]
        }.freeze
        ALWAYS_RECURSES = %w[rg ag ack].freeze
        PATTERN_OPTION = ["ef", %w[--regexp --file --files]].freeze

        # @param texts [Array<String>] the stage's unquoted words, program first
        # @param untrusted [Boolean] the name may not be the program that runs,
        #   so only a reading that makes it opaque applies, never one that
        #   claims to know what it reads, writes or where it runs
        def initialize(texts, untrusted: false)
          @name = texts.first.to_s.rpartition("/").last
          @command = TARS.include?(@name) ? "tar" : Programs.canonical(@name)
          @untrusted = untrusted
          @argv = Argv.new(texts.drop(1), @command)
        end

        def opaque? = runs_others? || changes_directory? || extracts_outside?

        # Every path it names may be one it writes.
        def untrusted? = @untrusted

        # @param index [Integer] into the words after the program
        def option?(index) = @argv.option?(index)

        # @param index [Integer] into the words after the program
        def value_offset(index) = @untrusted ? nil : @argv.value_offset(index)

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
          when *ALWAYS_RECURSES then searched
          when *RECURSES.keys then recursive_roots
          when "tar" then tar_creates? ? operands : []
          else []
          end
        end

        # @return [Array<Symbol>] `:root` when it searches the directory it runs
        #   in without naming it, `:written` when it writes there
        def implied
          return [] if @untrusted

          if (@command == "find" && find_roots.empty?) || (searches? && searched.empty?) || git_tree? then [:root]
          elsif implied_write? then [:written]
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

        private

        def word(index) = index ? @argv.words[index].to_s : ""

        def operands = @argv.operands

        def runs_others?
          [@name, @command].intersect?(RUNS_OTHERS) || ALWAYS_OPAQUE.include?(@command) ||
            (@command == "find" && @argv.words.intersect?(FIND_ACTIONS)) ||
            (PROGRAM_OPTIONS.key?(@command) && @argv.flag?(*PROGRAM_OPTIONS[@command], before: global_end)) ||
            (@command == "bundle" && @argv.words.first != "install") || runs_code? || sed_runs?
        end

        # git's own options come before its subcommand; `git log -c` is log's.
        def global_end = @command == "git" ? operands.first : nil

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
            !@argv.flag?("f", %w[--file]) || @argv.flag?("eE", %w[--source --exec]) ||
              @argv.value_texts("f", %w[--file]).any? { STDIN_SCRIPT.match?(_1) }
          elsif FROM_A_FILE.include?(@command)
            @argv.flag?(*Programs::INLINE_CODE.fetch(@command, Argv::NONE)) || stdin_script?
          else
            false
          end
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

        def changes_directory?
          @argv.options.any? do |index|
            option = word(index)
            (DIRECTORY_LONG.include?(option.partition("=").first) && !own_flag?(option)) ||
              (!option.start_with?("--") && @argv.cluster(index).count(directory_letters).positive?)
          end
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

          @argv.flag?("ef", %w[--expression --file]) ? operands : operands.drop(1)
        end

        def git_written
          subcommand, *rest = operands
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

          subcommand, *rest = operands
          GIT_TREE_READERS.include?(word(subcommand)) ||
            (word(subcommand) == "add" && (@argv.flag?("A", %w[--all]) || rest.any? { word(_1) == "." }))
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
        def searched = @argv.flag?(*PATTERN_OPTION) ? operands : operands.drop(1)

        def recursive_roots
          return [] unless recursive?

          case @command
          when "cp" then @argv.values(*TARGET).empty? ? operands[0...-1] : operands
          when "zip" then operands.drop(1)
          when "diff" then operands
          else searched
          end
        end
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

      # One pass over a parse, stage by stage, carrying the directory a bound
      # `cd` moved to. Mutable while it walks; what it hands back is frozen.
      class Walk
        # Literal structure only. Anything else -- an assignment, an expansion,
        # a heredoc, a compound statement -- is read as opaque.
        READABLE_KINDS = %w[
          program list pipeline command command_name word number concatenation
          raw_string string file_redirect redirected_statement comment
        ].freeze

        DIRECTORY_CHANGERS = %w[cd pushd popd].freeze
        AND = "&&"
        AFTER_A_CD = [AND, "|"].freeze
        LONG_VALUE = /\A--[^=]+=/
        SHORT_LETTERS = /\A-[A-Za-z0-9]*/
        ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
        DUPLICATIONS = %w[>& <&].freeze
        DESCRIPTOR = /\A(\d+|-)\z/
        NOT_A_NAME = ["", ".", ".."].freeze
        LONE_DASH = "-"

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
        end

        # @return [Named]
        def named
          return UNREADABLE unless readable?

          @result.stages.each_index.all? { |index| step(index) }
          Named.new(paths: @paths.uniq.freeze, opaque: @opaque)
        end

        private

        def readable?
          @result.covered? && (@result.kinds - READABLE_KINDS).empty? &&
            @result.stages.sum { _1.redirects.size } == @result.redirects.size
        end

        # @return [Boolean, nil] nil once the rest of the command is opaque
        def step(index)
          return halt if @moved && !AFTER_A_CD.include?(join_before(index))

          stage = @result.stages[index]
          raws = [*stage.argv, *stage.redirects.flat_map(&:extra_words)]
          words = Words.new(raws:, literals: raws.map { Word.read(_1) })
          return change_directory(index, words) if DIRECTORY_CHANGERS.include?(words.texts.first)

          name(stage, words)
          true
        end

        def halt
          @opaque = true
          nil
        end

        # A `cd` binds what follows only when its directory is literal and `&&`
        # joins it on both sides: after `;`, `||` or `&` the next stage may run
        # where the cd failed to leave, a cd after `||` may never run, and a cd
        # in a pipeline runs in a subshell.
        def change_directory(index, words)
          target = cd_target(words)
          return halt unless target && joined_by_and?(index)

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
          named = program.opaque? ? [:opaque] : stage_paths(stage, inner, program)
          @opaque ||= named.include?(:opaque)
          @paths.concat(named.grep(Path))
        end

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
          named = [*program_path(words), *word_paths(words, program), *rev_paths(program), *implied_paths(program),
                   *redirect_paths(stage)]
          program.untrusted? ? named.map { possibly_written(_1) } : named
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
          program.implied.map do |kind|
            Path.new(word: "", resolved: @dir, written: kind == :written, directory: false,
                     pattern: File.join(@dir, "**").freeze)
          end
        end

        def redirect_paths(stage) = stage.redirects.map { redirect_path(_1) }

        def program_path(words)
          literal = words.literals.first
          return :opaque if literal.nil?

          path(words.raws.first, literal, written: false) if literal.text.include?("/")
        end

        def word_paths(words, program)
          written = program.written
          roots = program.roots
          words.raws.drop(1).each_with_index.flat_map do |raw, index|
            literal = words.literals[index + 1]
            if literal.nil?
              [:opaque]
            elsif program.option?(index)
              option_paths(raw, literal, program.value_offset(index), written.include?(index))
            else
              operand_paths(raw, literal, written: written.include?(index), root: roots.include?(index))
            end
          end
        end

        # Where the program's value letters are not known, an attached value
        # could start after any letter: `-xzf/x` might be `zf/x`, `f/x` or `/x`.
        def option_paths(raw, literal, offset, written)
          text = literal.text
          return [] if text == "--"

          unless text.start_with?("--")
            cuts = offset ? [offset] : (2..text[SHORT_LETTERS].to_s.size)
            return cuts.map { path(raw, literal.drop(_1), written:) }
          end

          match = LONG_VALUE.match(text)
          return [] if match.nil?

          value_paths(raw, literal, match.end(0), written:)
        end

        # `cat a=b` opens `a=b`, while `dd if=x` opens `x`, so both are named.
        def operand_paths(raw, literal, written:, root:)
          whole = path(raw, literal, written:, root:)
          match = ASSIGNMENT.match(literal.text)
          return [whole] if match.nil?

          [whole, *value_paths(raw, literal, match.end(0), written:)]
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

        def path(raw, literal, written:, root: false)
          return if literal.text.empty? || literal.text == LONE_DASH

          resolved = resolve(literal)
          return :opaque if resolved.nil?

          Path.new(word: -raw, resolved:, written:, directory: false, pattern: pattern(literal, resolved, root))
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

      private_constant :Word, :Argv, :Program, :SedScript, :Walk, :UNREADABLE
    end
  end
end
