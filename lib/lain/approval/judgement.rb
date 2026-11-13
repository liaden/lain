# frozen_string_literal: true

module Lain
  module Approval
    # Whether the judge may weigh a call, decided once, before a request is
    # paid for: {Weighable} with the facts it is told, or {Unweighable} with
    # the one reason it is not asked.
    #
    # A call that runs under the workspace profile has two things guarding its
    # output that a walk cannot see: the sandbox hides each secret the
    # session's mask list masks, and the values a sensitive file held in the
    # project's history are masked in what the command prints. So under it a
    # secret the list masks does not stop a walk, and a git read of the
    # project's own reachable history is not walked at all; the judge is told
    # both. Anything else is walked: a secret the list does not name, a path
    # the call names outright, and a git read of another repository or of an
    # object the project's refs may not reach.
    module Judgement
      REASONS = %i[opaque barred below_top git_store protected_target too_many].freeze

      # @!attribute [r] facts
      #   @return [Judge::Facts] what the judge is told, the sandbox's masks included
      Weighable = Data.define(:facts)

      Unweighable = Data.define(:reason, :details)

      # Reopened so the enumeration is read where the class body runs.
      #
      # @!attribute [r] reason
      #   @return [Symbol] one of {REASONS}
      # @!attribute [r] details
      #   @return [Array<String>] the path a protected target names, or each reason a bar gives; else none
      class Unweighable
        def initialize(reason:, details: [])
          raise ArgumentError, "#{reason.inspect} is not one of #{REASONS.inspect}" unless REASONS.include?(reason)

          super(reason:, details: Ractor.make_shareable(details.map { -_1.to_s }))
        end
      end

      # The workspace profile's sandbox around a call, read off the session's
      # mask list: what it hides is what the list masks when asked, as the
      # sandbox asks it, so a project the list cannot list hides nothing.
      class Masking
        # @param list [#masks] the session's {Confine::MaskList}
        def initialize(list)
          @list = list
          freeze
        end

        # @return [Boolean] true: the call runs under the profile's masks
        def on? = true

        # @return [Array<String>] absolute; each path the sandbox hides
        def hidden = @list.masks.map(&:path)
      end

      # A call no workspace sandbox wraps.
      module Unmasked
        # @return [Boolean] false
        def self.on? = false

        # @return [Array<String>] none
        def self.hidden = [].freeze
      end

      # @param effect [Effect::ToolCall]
      # @param bounds [Sensitivity::Policy::Confined] the requester's, as {Sensitivity::Policy.confined_at} answers
      # @param named [Shell::Named] every path the command names
      # @param facts [#call] `-> Judge::Facts`, asked only for a call whose paths were named and walked
      # @param masks [Masking, Unmasked] the sandbox a call the judge approves runs under
      # @param verdict [#call] `path -> Sensitivity::Verdict`, as the gate judges the path
      # @param barred [Boolean] whether the session barred the command from automatic approval
      # @param env [Hash{String=>String}] the environment the call runs with
      # @return [Weighable, Unweighable]
      def self.of(effect, bounds:, named:, facts:, masks:, verdict:, barred: false, env: {})
        return Unweighable.new(reason: :barred) if barred

        Weighing.new(bounds:, masks:, verdict:, env:).call(effect, named, facts)
      end

      # Whether a git command prints only history the output mask was read
      # from: the project's own objects as `rev-list --all --reflog` reaches
      # them ({Sensitivity::HistoryLiterals}). Never the working tree or the
      # index, whose files below the mask's depth no mask covers. An allowlist
      # of forms, failing closed: a word that could name an object, a ref
      # outside `refs/`, a read past the object database, an environment that
      # could point git elsewhere, or any form it cannot classify keeps the walk.
      class OwnHistory
        OBJECT_READS = %w[log show shortlog whatchanged describe rev-parse ls-tree range-diff ls-files].freeze
        STASH_READS = %w[show list].freeze
        # Only the listing forms: every other branch, tag or reflog form writes a ref, or runs an editor.
        LISTS = { "branch" => %w[-a --all -r --remotes -l --list -v -vv --verbose --show-current --color --no-color
                                 --column --no-column --sort --format --abbrev --no-abbrev],
                  "tag" => %w[-l --list -n --sort --format --color --no-color --column --no-column] }.freeze
        REFLOG_READS = [nil, "show"].freeze
        VERBOSE = /\A(-[^-]*v|--verbose\z)/
        RANGE = ".."
        PATHS = "--"
        VALUED = %w[-C -c].freeze
        # The git variables that cannot change which repository, objects or working tree git reads, or what
        # it prints; any other, an unknown one included, could point a read past the history the mask holds.
        HARMLESS_ENV = %w[GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_PAGER GIT_TERMINAL_PROMPT GIT_ASKPASS
                          GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
                          GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
                          GIT_OPTIONAL_LOCKS GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze
        GIT_ENV = /\AGIT_/
        # A bare hex run of 4 or more is what git takes as an abbreviated object id.
        OBJECT = /(?<![[:alnum:]])\h{4,}(?![[:alnum:]])|\w_HEAD\b/
        PAST_REFS = /\A(--(no-index|stdin|untracked|no-exclude-standard|git-dir|work-tree)\b|GIT_)/
        WORDS = /[;&|()<>]+|[^\s;&|()<>]+/
        BETWEEN = /\A[;&|()<>]+\z/
        # A diff driver runs a program over each blob a history read prints, and that program can print any
        # file at all; with none configured, an attribute naming one runs nothing.
        DRIVERS = '^diff\..*\.(textconv|command)$|^diff\.external$'
        CONFIG_ENV = %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM HOME XDG_CONFIG_HOME].freeze
        NO_MATCH = 1
        CONFIG_TIMEOUT = 10

        # @param command [Object] as the model sent it; anything but a String covers nothing
        # @param root [String, nil] absolute; the project's
        # @param files [FileFacts::Live, FileFacts::Recorded]
        # @param env [Hash{String=>String}] the environment the call runs with
        def initialize(command, root:, files:, env:)
          @words = command.is_a?(String) ? command.scan(WORDS).map { _1.delete(%q('")) } : nil
          @root = root
          @files = files
          @env = env
          @pointed = env.keys.any? { _1.match?(GIT_ENV) && !HARMLESS_ENV.include?(_1) }
        end

        # @param path [Shell::Named::Path] a git read's whole tree
        # @return [Boolean]
        def covers?(path)
          !@words.nil? && !@root.nil? && !@pointed && reached_only? && own?(path.resolved) && driverless?
        end

        # @return [Boolean] whether the command runs git at all
        def runs_git? = !@words.nil? && @words.any? { git?(_1) }

        private

        def reached_only?
          @reached_only = history_words? if @reached_only.nil?
          @reached_only
        end

        def history_words? = @words.none? { unreached?(_1) } && invocations.all? { history_only?(*_1) }

        # A path is not an object name, but an object name can lead a `<rev>:<path>`.
        def unreached?(word) = word.split(File::SEPARATOR, 2).first.to_s.match?(OBJECT) || word.match?(PAST_REFS)

        def invocations = @words.each_index.select { git?(@words[_1]) }.map { invoked(@words.drop(_1 + 1)) }

        def git?(word) = word == "git" || word.end_with?("/git")

        # @return [Array(String, Array<String>)] the subcommand, and every word after it up to the next command
        def invoked(rest)
          own = rest.take_while { !_1.match?(BETWEEN) }
          at = own.each_index.find { |index| !own[index].start_with?("-") && !valued?(own, index) }
          at ? [own[at], own.drop(at + 1)] : [nil, []]
        end

        def valued?(words, index) = index.positive? && VALUED.include?(words[index - 1])

        def history_only?(command, args)
          case command
          when *OBJECT_READS then true
          when *LISTS.keys then args.all? { LISTS.fetch(command).include?(_1.split("=", 2).first) }
          when "reflog" then REFLOG_READS.include?(args.find { !_1.start_with?("-") })
          when "status" then args.none? { _1.match?(VERBOSE) }
          when "stash" then STASH_READS.include?(args.find { !_1.start_with?("-") })
          when "diff" then ranges_only?(args)
          else false
          end
        end

        # A diff with no range compares a commit with the working tree or the index.
        def ranges_only?(args)
          revisions = args.take_while { _1 != PATHS }.reject { _1.start_with?("-") }
          revisions.any? && revisions.all? { _1.include?(RANGE) }
        end

        def driverless?
          @driverless = no_driver_configured? if @driverless.nil?
          @driverless
        end

        # Asked of git itself, under the config the call would read; an answer other than "none" keeps the walk.
        def no_driver_configured?
          Shell::Out.new("git", "-C", @root, "config", "--get-regexp", DRIVERS, environment: config_env,
                                                                                timeout: CONFIG_TIMEOUT)
                    .run_command.exitstatus.eql?(NO_MATCH)
        rescue Shell::Out::Timeout, SystemCallError
          false
        end

        # This process's own git variables are dropped, so the answer is the call's.
        def config_env
          ENV.keys.grep(GIT_ENV).to_h { [_1, nil] }.merge(CONFIG_ENV.to_h { [_1, @env[_1]] },
                                                          Isolation::Worktree::NO_LAZY_FETCH)
        end

        def own?(directory)
          own = store_of(directory)
          own && own == (@project ||= store_of(@root))
        end

        # The object database the nearest `.git` above a directory reads, a linked worktree's its common one.
        def store_of(directory)
          marker = File.join(directory, ".git")
          return pointed(marker) if @files.file?(marker)
          return File.realpath(marker) if @files.directory?(marker)

          parent = File.dirname(directory)
          store_of(parent) unless parent == directory
        rescue SystemCallError
          nil
        end

        def pointed(marker)
          gitdir = File.read(marker)[/\Agitdir: (.+)$/, 1]
          gitdir &&= File.expand_path(gitdir, File.dirname(marker))
          common = gitdir && File.join(gitdir, "commondir")
          return unless gitdir

          File.realpath(File.file?(common) ? File.expand_path(File.read(common).strip, gitdir) : gitdir)
        end
      end

      # One call's weighing, holding what every step reads.
      class Weighing
        WHOLE_TREE = "**"

        def initialize(bounds:, masks:, verdict:, env:)
          @env = env
          @bounds = bounds
          @files = bounds.file_facts
          @masks = masks
          @verdicts = Hash.new { |known, path| known[path] = verdict.call(path) }
        end

        def call(effect, named, facts)
          return Unweighable.new(reason: :opaque) if named.opaque?
          return Unweighable.new(reason: :below_top) if named.paths.any? { below_top?(_1) }

          walked(effect, named, facts)
        end

        private

        def walked(effect, named, facts)
          own = OwnHistory.new(command_of(effect), root: @bounds.root, files: @files, env: @env)
          history, walking = named.paths.partition { history_masked?(_1, own) }
          reached = walking.map { Judged::Reach.of(_1, facts: @files) }
          return Unweighable.new(reason: :too_many) if reached.any?(&:nil?)
          return Unweighable.new(reason: :git_store) if reached_store?(walking, reached)

          resolved = facts.call
          barred(resolved) || weighed(effect, walking.zip(reached), resolved, history: history.any?, own:)
        end

        def barred(facts) = (Unweighable.new(reason: :barred, details: facts.bar) unless facts.bar.empty?)

        def command_of(effect) = effect.input.is_a?(Hash) ? effect.input["command"] || effect.input[:command] : nil

        # The sandbox hides a file on disk, never the index or an object a git command reads, and a
        # rev-path names its file as a walk would, so a command that runs git has nothing hidden.
        def weighed(effect, walks, facts, history:, own:)
          found = own.runs_git? ? [] : walks.flat_map { |_, entries| entries.drop(1) }
          hidden = found.select { hidden?(_1) }
          named = [*Sensitivity::Policy.path_in(effect), *walks.flat_map(&:last)]
          target = (named - hidden).find { !@verdicts[_1].oracle_approvable? }
          return Unweighable.new(reason: :protected_target, details: [target]) if target

          Weighable.new(facts: hidden.empty? && !history ? facts : facts.masking(hidden, history:))
        end

        def history_masked?(path, own)
          @masks.on? && path.git && !path.written && path.pattern == File.join(path.resolved, WHOLE_TREE) &&
            own.covers?(path)
        end

        # Found by a walk or a glob, never named outright.
        def hidden?(entry)
          verdict = @verdicts[entry]
          !verdict.oracle_approvable? && Sensitivity::Policy.masks?(verdict) && listed?(entry)
        end

        def listed?(entry)
          landed = @files.realpath(entry)
          (@hidden ||= @masks.hidden).any? { landed == _1 || landed.start_with?("#{_1}#{File::SEPARATOR}") }
        rescue SystemCallError
          false
        end

        # Only what a pattern or recursive reach found counts: naming `.git/HEAD` is a file, not the store.
        # A pointer file, as in a linked worktree, is a store only to a path a git command implies.
        def reached_store?(paths, reached)
          paths.zip(reached).any? do |path, found|
            found.drop(1).any? { store_entry?(path.resolved, _1.delete_prefix(path.resolved), git: path.git) }
          end
        end

        # A checkout-local git write names the `.git` beside its cwd; with none
        # there, its pathspecs and `-A` are relative to a top level it never named.
        def below_top?(path)
          path.checkout_git? && !(@files.directory?(path.resolved) || @files.file?(path.resolved))
        end

        def store_entry?(root, relative, git:)
          segments = relative.split(File::SEPARATOR)
          index = segments.index(".git")
          index && begin
            dotgit = File.join(root, *segments.first(index + 1))
            @files.directory?(dotgit) || (git && @files.file?(dotgit))
          end
        end
      end
      private_constant :Weighing, :OwnHistory
    end
  end
end
