# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # Names the files a stage will execute or load without its argv showing
      # them as programs: an interpreter's script, a test runner's spec files, a
      # build tool's config, git's hooks. A planted one runs as surely as a
      # planted binary, so each is classed like one. Under-reporting is the
      # unsafe direction, so whatever cannot be read from the words is nil.
      class RunFiles
        # One run file, classed the way its stage's program is.
        Entry = Data.define(:path, :klass, :fresh) do
          # @return [Hash{String=>Object}] JSON-safe, for a journal record
          def to_journal = { "path" => path, "klass" => klass.to_s, "fresh" => fresh }
        end

        # `busybox` takes an applet first.
        INTERPRETERS = (Programs::SHELLS - %w[busybox] + %w[perl python python2 python3 ruby node php lua]).freeze

        PYTHONS = %w[python python2 python3].freeze

        SHELL_VALUED = %w[-o -O +o +O --rcfile --init-file].freeze

        # Without these the next word would be taken for the script.
        VALUED = {
          "ruby" => %w[-I -r], "perl" => %w[-I -M], "python" => %w[-W -X], "python2" => %w[-W -X],
          "python3" => %w[-W -X], "node" => %w[-r --require --import]
        }.freeze

        # Options that move the directory or the search a script is found by.
        RUBY_REDIRECTS = /\A(?:-[a-zA-Z]*[CxS]|--chdir)/

        BUILD_FILES = {
          "rake" => %w[Rakefile rakefile Rakefile.rb rakefile.rb], "bundle" => %w[Gemfile Gemfile.lock],
          "npm" => %w[package.json], "yarn" => %w[package.json], "pnpm" => %w[package.json],
          "cargo" => %w[Cargo.toml build.rs], "direnv" => %w[.envrc]
        }.freeze

        # GNU make's own search order.
        MAKEFILES = %w[GNUmakefile makefile Makefile].freeze

        # What each runner reads when given no operand; `*` matches within a name.
        TEST_RUNNERS = {
          "rspec" => %w[spec .rspec],
          "pytest" => %w[tests test pytest.ini conftest.py pyproject.toml setup.cfg],
          "py.test" => %w[tests test pytest.ini conftest.py pyproject.toml setup.cfg],
          "jest" => %w[package.json jest.config.*], "vitest" => %w[package.json vitest.config.*],
          "mocha" => %w[test package.json .mocharc.*], "phpunit" => %w[tests phpunit.xml phpunit.xml.dist]
        }.freeze

        # Flags after which an interpreter prints and exits instead of reading stdin.
        INFORMATION = %w[-v -V -h --version --help].freeze

        # Git options that change which repository or config is read.
        GIT_REDIRECTS = /\A(?:-C|-c|--git-dir|--work-tree|--config-env|--exec-path)/

        # @param cwd [String]
        # @param stat [Stat]
        def initialize(cwd:, stat:)
          @cwd = cwd
          @stat = stat
        end

        # @param argv [Array<String>] one stage, wrappers not yet peeled
        # @return [Array<String>, nil] absolute paths; nil when they cannot be told from the words
        def of(argv)
          program = File.basename(argv.first.to_s)
          args = argv.drop(1)
          return script(program, args) if INTERPRETERS.include?(program)
          return makefile(args) if program == "make"
          return git(args) if program == "git"
          return existing(BUILD_FILES.fetch(program)) if BUILD_FILES.key?(program)

          TEST_RUNNERS.key?(program) ? runner(program, args) : []
        end

        private

        def script(program, args)
          operand = operand(program, args)
          return [absolute(operand)] if operand.is_a?(String)
          return module_files(*operand) if operand.is_a?(Array)

          stdin = operand.nil? && !(args.intersect?(INFORMATION) && !args.include?("-"))
          stdin ? nil : []
        end

        # @return [String, Array, :inline, nil] a script path; a python module and its
        #   arguments; or nil when nothing names the program
        def operand(program, args)
          word = args.first
          return if word.nil? || word == "-" || unplaceable?(program, word)

          word == "--" ? args[1] : after_options(program, word, args)
        end

        def after_options(program, word, args)
          if PYTHONS.include?(program) && word.match?(/\A-[a-z]*?m/) && !word.match?(/\A-[a-z]*?c/)
            module_operand(word, args)
          elsif inline?(program, word)
            :inline
          elsif valued(program).include?(word)
            operand(program, args.drop(2))
          elsif word.start_with?("-", "+")
            operand(program, args.drop(1))
          else
            word
          end
        end

        def module_operand(word, args)
          attached = word.sub(/\A-[a-z]*?m/, "")
          attached.empty? ? [args[1], args.drop(2)] : [attached, args.drop(1)]
        end

        def unplaceable?(program, word)
          (program == "ruby" && word.match?(RUBY_REDIRECTS)) ||
            (Programs::SHELLS.include?(program) && word.match?(/\A-[a-z]*s/) && !word.match?(/\A-[a-z]*c/))
        end

        def valued(program) = Programs::SHELLS.include?(program) ? SHELL_VALUED : VALUED.fetch(program, [])

        def module_files(name, rest)
          return unless name

          name == "pytest" ? runner("pytest", rest) : nil
        end

        # Only an all-lowercase cluster counts: a false "inline" hides a script,
        # while a false "file" only classes one more path.
        def inline?(program, word)
          letters, longs = Programs::INLINE_CODE.fetch(program,
                                                       Programs::SHELLS.include?(program) ? ["c", []] : ["", []])
          return longs.include?(word.split("=").first) if word.start_with?("--")

          !letters.empty? && word.match?(/\A-[a-z]*[#{letters.delete("m")}]/)
        end

        def makefile(args)
          file = makefile_option(args)
          return nil if file == "-"

          base = make_directory(args)
          return [File.absolute_path(file, base)] if file

          found = existing_at(base, MAKEFILES).first(1)
          found.empty? ? existing(MAKEFILES).first(1) : found
        end

        def make_directory(args)
          flag = args.index { |word| word.match?(/\A(?:-C|--directory)(?:=|\z)/) || word.start_with?("-C") }
          return @cwd unless flag

          word = args.fetch(flag)
          attached = word.sub(/\A(?:--directory=|-C)/, "")
          absolute(attached.empty? ? args[flag + 1].to_s : attached)
        end

        def makefile_option(args)
          flag = args.index { |word| word.match?(/\A(?:-f|--file|--makefile)(?:=|\z)/) || word.start_with?("-f") }
          return unless flag

          word = args.fetch(flag)
          attached = word.sub(/\A(?:--file=|--makefile=|-f)/, "")
          attached.empty? ? args[flag + 1] : attached
        end

        def runner(program, args)
          given = operands(args)
          given.empty? ? conventional(TEST_RUNNERS.fetch(program)) : given
        end

        def operands(args)
          args.reject { |word| word.start_with?("-") }
              .map { |word| absolute(word.sub(/(?::\d+)+\z/, "")) }.select { |path| exist?(path) }.uniq
        end

        def conventional(names)
          present = children(@cwd)
          names.flat_map { |name| present.select { |child| File.fnmatch(name, child, File::FNM_DOTMATCH) } }
               .map { |child| File.join(@cwd, child) }.uniq
        end

        def git(args)
          return if args.take_while { |word| word.start_with?("-") }.any? { |word| word.match?(GIT_REDIRECTS) }

          directories = git_directories(@cwd)
          return [] if directories == :none
          return unless directories

          gitdir, common, top = directories
          hooks = hooks_directory(common, gitdir, top)
          hooks && [*existing_at(common, %w[config]), *existing_at(gitdir, %w[config.worktree]), *hook_files(hooks)]
        end

        # @return [Array(String, String, String), :none, nil] git dir, common dir and
        #   work tree top; :none outside a repository; nil when the pointer cannot be read
        def git_directories(from)
          dot = File.join(from, ".git")
          return [dot, dot, from] if @stat.directory?(dot)
          return linked(dot, from) if exist?(dot)

          parent = File.dirname(from)
          parent == from ? :none : git_directories(parent)
        end

        def linked(dot, top)
          pointer = File.read(dot)[/\Agitdir:\s*(.+?)\s*\z/m, 1]
          return unless pointer

          gitdir = File.absolute_path(pointer, top)
          return unless @stat.directory?(gitdir)

          common = File.join(gitdir, "commondir")
          [gitdir, exist?(common) ? File.absolute_path(File.read(common).strip, gitdir) : gitdir, top]
        rescue SystemCallError
          nil
        end

        # core.hooksPath moves the hooks, and an include can hide it, so an
        # include, an unreadable config or a value in config syntax this does
        # not parse leaves them unknown.
        def hooks_directory(common, gitdir, top)
          texts = [common, gitdir].uniq.map { |directory| config_text(directory) }
          return if texts.any? { |text| text.match?(/^\s*\[include/i) }

          value = texts.filter_map { |text| text[/^\s*hookspath\s*=\s*(.*?)\s*$/i, 1] }.last
          return File.join(common, "hooks") unless value
          return if value.empty? || value.match?(/["\\#;~$]/)

          File.absolute_path(value, top)
        rescue SystemCallError
          nil
        end

        def config_text(directory)
          %w[config config.worktree].filter_map do |name|
            path = File.join(directory, name)
            File.read(path) if exist?(path)
          end.join("\n")
        end

        def hook_files(directory)
          children(directory).map { |name| File.join(directory, name) }.reject { |path| @stat.directory?(path) }
        end

        def existing(names) = existing_at(@cwd, names)

        def existing_at(directory, names)
          names.map { |name| File.join(directory, name) }.select { |path| exist?(path) }
        end

        def exist?(path)
          @stat.lstat(path)
          true
        rescue SystemCallError
          false
        end

        def absolute(path) = File.absolute_path(path, @cwd)

        def children(directory)
          @stat.children(directory)
        rescue SystemCallError
          []
        end
      end
    end
  end
end
