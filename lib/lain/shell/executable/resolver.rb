# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # Answers which file each stage of a term runs, the way execvp would find
      # it, and classes it by who could have put it there. One per session, so
      # that the bash call, the approval ladder and the judge read one answer.
      #
      # `:system` is decided by writability, never by owner: a file is `:user`
      # when this process could write it or any directory above it, since either
      # lets a user swap what runs without root.
      class Resolver
        # The freshness answer before any journal has been read.
        module NeverFresh
          # @param _path [String]
          # @return [false]
          def self.fresh?(_path) = false
        end

        # @param root [String] the project root; a file under it is `:project`
        # @param fresh [#fresh?] whether a path changed during this lineage
        # @param stat [Stat] the filesystem port
        # @param host_env [#to_h] what a child inherits before the worker's env is laid over it
        def initialize(root:, fresh:, stat: Stat.new, host_env: ENV)
          @fresh = fresh
          @stat = stat
          @host_env = host_env
          @roots = [root, stat.real(root)].uniq.freeze
        end

        # The child inherits the host env with the worker's laid over it, a nil
        # value deleting, so its PATH and its anomalies are read from that. A
        # checkout a lease cut is a copy of the project, so its files are the
        # project's too.
        #
        # @param worker_env [WorkerEnv]
        # @return [Bound]
        def for(worker_env)
          Bound.new(roots: roots_of(worker_env.checkout), fresh: @fresh, stat: @stat,
                    env: @host_env.to_h.merge(worker_env.env).compact, cwd: worker_env.cwd)
        end

        # A {Resolver} bound to one worker's env and cwd.
        class Bound
          # glibc's execvp searches this when PATH is unset.
          DEFAULT_PATH = "/bin:/usr/bin"

          # A word still holding an expansion was never a literal program name.
          EXPANSION = /[$`]/

          # Linux's MAXSYMLINKS: the kernel gives up on a longer chain with ELOOP.
          MAX_LINKS = 40

          # @param roots [Array<String>] the project root, as given and as its realpath
          # @param fresh [#fresh?]
          # @param stat [Stat]
          # @param env [Hash{String=>String}] what the child would inherit
          # @param cwd [String]
          def initialize(roots:, fresh:, stat:, env:, cwd:)
            @roots = roots
            @fresh = fresh
            @stat = stat
            @env = env
            @cwd = cwd
            @run_files = RunFiles.new(cwd:, stat:)
          end

          # @param term [Term]
          # @return [Array<Executable>] one per stage, wrappers unwrapped to the program they run
          def call(term) = term.stages.map { |stage| unwrap(stage.argv, @env, []) }

          private

          def unwrap(argv, env, wrappers, files = [])
            found = @run_files.of(argv)
            return unresolved(argv.first.to_s, env, wrappers) unless found

            files += found
            peel = Peel.of(argv, env)
            return with_run_files(resolve(argv.first.to_s, env, wrappers), files) unless peel

            inner = [*wrappers, resolve(argv.first, env, [])]
            case peel.outcome
            when :run then unwrap(peel.command, peel.env, inner, files)
            when :hidden_env then hidden(peel, env, inner, files)
            else with_run_files(unresolved(argv.first, env, inner), files)
            end
          end

          # What the wrapper's own env hides is the program, but its words still name files.
          def hidden(peel, env, wrappers, files)
            with_run_files(unresolved(peel.command.first, env, wrappers), [*files, *@run_files.of(peel.command)])
          end

          def with_run_files(executable, paths)
            Executable.new(**executable.to_h, run_files: paths.uniq.map { |path| run_file(path) })
          end

          def run_file(path)
            paths = paths_of(links([path]), @stat.realpath(path))
            RunFiles::Entry.new(path:, klass: klass(paths), fresh: fresh?(paths))
          rescue SystemCallError
            RunFiles::Entry.new(path:, klass: :unresolved, fresh: false)
          end

          def unresolved(name, env, wrappers, anomalies: anomalies_of(env))
            Executable.unresolved(name, anomalies:, wrappers:)
          end

          def resolve(name, env, wrappers)
            return unresolved(name, env, wrappers) if opaque?(name)
            return by_path(name, env, wrappers) if name.include?("/")

            search(name, env, wrappers)
          rescue SystemCallError
            unresolved(name, env, wrappers)
          end

          def opaque?(name) = name.empty? || name.match?(EXPANSION)

          def by_path(name, env, wrappers)
            path = absolute(name)
            return unresolved(name, env, wrappers) unless @stat.executable?(path)

            identify(name, path, [], anomalies_of(env), wrappers)
          end

          def search(name, env, wrappers)
            entries = path_entries(env)
            hits = entries.map { |entry| File.join(absolute(entry), name) }
            index = hits.index { |hit| @stat.executable?(hit) }
            anomalies = path_anomalies(index ? entries.take(index + 1) : entries) | anomalies_of(env)
            return unresolved(name, env, wrappers, anomalies:) unless index

            identify(name, hits[index], shadowed(hits, index), anomalies, wrappers)
          end

          # execvp reads an empty PATH as one empty entry, which is the cwd.
          def path_entries(env)
            path = env.fetch("PATH", DEFAULT_PATH)
            path.empty? ? [""] : path.split(":", -1)
          end

          def identify(name, resolved, shadowed, anomalies, wrappers)
            chain = links([resolved])
            realpath = @stat.realpath(resolved)
            paths = paths_of(chain, realpath)
            Executable.new(name:, resolved:, realpath:, chain:, shadowed:, anomalies:,
                           klass: klass(paths), fresh: fresh?(paths), run_files: [],
                           wrappers:)
          end

          def paths_of(chain, realpath) = [*chain, *chain.map { |link| canonical(link) }, realpath].uniq

          def fresh?(paths) = paths.any? { |path| @fresh.fresh?(path) }

          def shadowed(hits, index)
            own = @stat.realpath(hits[index])
            hits.drop(index + 1).select { |hit| @stat.executable?(hit) }
                .uniq { |hit| @stat.realpath(hit) }.reject { |hit| @stat.realpath(hit) == own }
          end

          # execvp does not expand a tilde, so neither does this.
          def absolute(path)
            Pathname.new(path.start_with?("/") ? path : File.join(@cwd, path)).cleanpath(true).to_s
          end

          def links(chain)
            last = chain.last
            return chain unless chain.size < MAX_LINKS && @stat.lstat(last).symlink?

            # The kernel reads `..` after following a symlinked directory, so a
            # textual fold could name a different file than the one that runs.
            target = @stat.readlink(last)
            links([*chain, target.start_with?("/") ? target : File.join(@stat.real(File.dirname(last)), target)])
          end

          def klass(paths)
            return :project if paths.any? { |path| inside_root?(path) }

            paths.any? { |path| replaceable?(path) } ? :user : :system
          end

          def replaceable?(path) = ancestry(path).any? { |each| @stat.writable?(each) }

          def ancestry(path)
            parent = File.dirname(path)
            parent == path ? [path] : [path, *ancestry(parent)]
          end

          def path_anomalies(entries)
            entries.flat_map do |entry|
              [(:empty_path_entry if entry.empty?),
               (:relative_path_entry unless entry.empty? || entry.start_with?("/")),
               (:project_path_entry if project_entry?(absolute(entry)))].compact
            end.uniq
          end

          def project_entry?(directory) = [directory, @stat.real(directory)].any? { |path| inside_root?(path) }

          # An exported function reaches any bash a stage starts, whatever its
          # name, so every one counts against every stage.
          def anomalies_of(env)
            [(:exported_function if env.keys.any? { |key| key.start_with?("BASH_FUNC_") }),
             (:ld_preload unless env["LD_PRELOAD"].to_s.empty?)].compact
          end

          def inside_root?(path) = @roots.any? { |root| path == root || path.start_with?("#{root}/") }

          def canonical(path) = File.join(@stat.real(File.dirname(path)), File.basename(path))
        end

        Peel = Data.define(:command, :env, :outcome)
        Options = Data.define(:flags, :valued)

        # A wrapper's options: `flags` are patterns a whole word matches, and a
        # `valued` option takes the next word, or its value attached (`-n19`,
        # `--adjustment=19`).
        class Options
          # @param args [Array<String>] the words after the wrapper
          # @return [Array<String>, nil] the words after its options; nil when one is not known
          def rest(args)
            word = args.first.to_s
            return args unless word.start_with?("-") && word != "-"
            return args.drop(1) if word == "--"
            return rest(args.drop(1)) if flag?(word) || attached?(word)
            return rest(args.drop(2)) if valued.include?(word)

            nil
          end

          private

          def flag?(word) = flags.any? { |flag| word.match?(flag) }

          def attached?(word) = valued.any? { |option| word != option && word.start_with?(attachment(option)) }

          def attachment(option) = option.start_with?("--") ? "#{option}=" : option
        end

        # A wrapper stage taken apart: the command it runs and the env that
        # command inherits. `:hidden_env` means the wrapper rewrites that env
        # from somewhere this cannot read (bundler's bin path, an `.envrc`), and
        # `:unreadable` that what it runs cannot be read from its words: an
        # option this does not know, or a runner this does not model at all.
        class Peel
          NICE = Ractor.make_shareable(Options.new(flags: [/\A-[+-]?\d+\z/], valued: %w[-n --adjustment]))
          TIME = Ractor.make_shareable(
            Options.new(flags: [/\A-[pvqa]\z/, /\A--(?:portability|verbose|quiet|append)\z/],
                        valued: %w[-f -o --format --output])
          )
          TIMEOUT = Ractor.make_shareable(
            Options.new(flags: [/\A-v\z/, /\A--(?:preserve-status|foreground|verbose)\z/],
                        valued: %w[-s -k --signal --kill-after])
          )
          BUNDLE_EXEC = Ractor.make_shareable(
            Options.new(flags: [/\A--keep-file-descriptors\z/], valued: %w[--gemfile])
          )

          # Every program whose words can name another program to run.
          RUNNERS = (Programs::WRAPPERS + Programs::PRIVILEGE + Programs::TAKES_A_COMMAND).uniq.freeze

          # The actions through which find runs a program; without one it runs nothing.
          FIND_EXECS = %w[-exec -execdir -ok -okdir].freeze

          # @param argv [Array<String>] a stage
          # @param env [Hash{String=>String}] what the stage inherits
          # @return [Peel, nil] nil when the stage runs no other program
          def self.of(argv, env)
            args = argv.drop(1)
            program = File.basename(argv.first.to_s)
            case program
            when "env" then build(*env_options(args, env), :run)
            when "nice" then build(NICE.rest(args), env, :run)
            when "time" then build(TIME.rest(args), env, :run)
            when "timeout" then build(TIMEOUT.rest(args)&.drop(1), env, :run)
            when "bundle", "direnv" then exec_of(program, args, env)
            when "find" then unreadable(env) if args.intersect?(FIND_EXECS)
            else unreadable(env) if RUNNERS.include?(program)
            end
          end

          # Both rewrite the env of what they run, so its program is named but
          # cannot be resolved here.
          #
          # @param program [String] `bundle` or `direnv`
          # @param args [Array<String>]
          # @param env [Hash{String=>String}]
          # @return [Peel, nil]
          def self.exec_of(program, args, env)
            return unless args.first == "exec"

            build(program == "bundle" ? BUNDLE_EXEC.rest(args.drop(1)) : args.drop(2), env, :hidden_env)
          end

          # @param env [Hash{String=>String}]
          # @return [Peel]
          def self.unreadable(env) = new(command: [], env:, outcome: :unreadable)

          # @param command [Array<String>, nil]
          # @param env [Hash{String=>String}]
          # @param outcome [Symbol]
          # @return [Peel, nil]
          def self.build(command, env, outcome)
            return unreadable(env) if command.nil?

            new(command:, env:, outcome:) unless command.empty?
          end

          # @param args [Array<String>]
          # @param env [Hash{String=>String}]
          # @return [Array(Array<String>, Hash), Array(nil, Hash)]
          def self.env_options(args, env)
            case args.first
            when "-i", "--ignore-environment", "-" then env_options(args.drop(1), {})
            when "-u" then env_options(args.drop(2), env.except(args[1].to_s))
            when /\A(?:-u|--unset=)(.+)\z/m then env_options(args.drop(1), env.except(Regexp.last_match(1)))
            when "--" then env_assignments(args.drop(1), env)
            when /\A-/ then [nil, env]
            else env_assignments(args, env)
            end
          end

          # @param args [Array<String>]
          # @param env [Hash{String=>String}]
          # @return [Array(Array<String>, Hash)]
          def self.env_assignments(args, env)
            name, value = args.first.to_s.split("=", 2)
            return [args, env] if value.nil? || name.empty?

            env_assignments(args.drop(1), env.merge(name => value))
          end

          private_class_method :exec_of, :unreadable, :build, :env_options, :env_assignments
        end

        # Resolves every stage `:unresolved`: the resolver where no session exists.
        class Null
          # @param _worker_env [WorkerEnv]
          # @return [Null]
          def for(_worker_env) = self

          # @param term [Term]
          # @return [Array<Executable>]
          def call(term) = term.stages.map { |stage| Executable.unresolved(stage.program.to_s) }
        end

        NULL = Null.new.freeze

        private

        def roots_of(checkout) = checkout ? [*@roots, checkout, @stat.real(checkout)].uniq : @roots
      end
    end
  end
end
