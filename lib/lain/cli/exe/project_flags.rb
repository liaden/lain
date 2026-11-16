# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # Which project the command line names, as opposed to which one the shell
      # happens to be standing in: `up`'s PATH positional and `chat`'s
      # `--root`/`--cwd`. One home rather than a helper apiece, because both are
      # the same translation and both refuse the same way -- a path a user TYPED,
      # expanded against the shell's directory, and named in its own refusal.
      module ProjectFlags
        # Declared through a module method rather than inline, the way {ModelFlags}
        # and {CompactionFlags} already are: Thor accumulates `method_option` onto
        # the command declared NEXT, so this call goes immediately before
        # `def chat`.
        def self.declare(thor)
          thor.method_option :root, type: :string, banner: "PATH",
                                    desc: "Treat PATH as this run's project root, instead of detecting one " \
                                          "by walking up from the working directory"
          thor.method_option :cwd, type: :string, banner: "PATH",
                                   desc: "Run as if the working directory were PATH; must lie under the root, " \
                                         "and defaults to it"
        end

        # `up`'s two arguments, cut out of one positional list.
        #
        # PATH shares an argv slot with the first `--`-forwarded flag, because Thor
        # drops the separator before the command method is entered.
        # {LainCLI.split_forwarded} puts it back from what argv really said.
        #
        # The two halves are then treated separately and absolutely: `forwarded` is
        # forwarded, and every own positional past the first is refused. Adding
        # them together -- which this did -- threw away the one thing the split
        # knows for certain, and `lain up /tmp/repo typo -- --provider x` shipped
        # "typo" to the chat pane to die inside tmux, after the session existed.
        def up_argv(path, chat_args)
          own, forwarded = self.class.split_forwarded([path, *chat_args].compact)
          refuse_strays!(own.drop(1))
          { path: own.first, chat_args: forwarded }
        end

        # What `--root`/`--cwd` change about `chat`, or NOTHING. Nothing is the
        # point of the empty Hash: an unflagged `lain chat` keeps
        # {Lain::CLI::ChatLaunch}'s own default factory --
        # `Lain::Project::Resolver.default_project`, the one place a run resolves
        # its own project -- rather than routing the ordinary case through a second
        # construction of the same resolver.
        #
        # `--cwd` DEFAULTS TO THE ROOT, because "open that project" is what
        # `--root PATH` alone means and the shell's directory is almost never
        # inside it. Left to `Resolver#call`'s own `cwd: Dir.pwd`, the common
        # invocation built a Project whose cwd lies outside its root, which
        # {Lain::Project}'s guard refuses with an `ArgumentError` -- not a
        # {Lain::Error}, so nothing between here and Thor rendered it and the flag
        # whose whole design is about naming a path in its own refusal answered
        # with a fourteen-frame backtrace.
        def project_override
          root = directory!(options[:root], "--root")
          cwd = directory!(options[:cwd], "--cwd")
          return {} if root.nil? && cwd.nil?

          { project_factory: -> { resolved_project(root:, cwd: cwd || root) } }
        end

        def trust_root(path) = directory!(path, "PATH") || Lain::Project::Resolver.default_project.root

        # A path the user typed, expanded against the shell's directory and refused
        # BY NAME when it is not a directory. The resolver would take a regular file
        # as a root perfectly happily -- it asks realpath, and a file has one -- and
        # a project rooted at a file is a typo, never an intent.
        #
        # A BLANK flag is no flag: `--root ""` is a truthy String, so it would reach
        # rung 1 and die inside `realpath("")`. An empty shell variable expanding to
        # nothing is the ordinary way that happens, and "an empty flag means no
        # flag" is the friendlier reading of it.
        def directory!(value, flag)
          return nil if value.nil? || value.empty?

          File.expand_path(value).tap do |path|
            raise ::Thor::Error, "#{flag} #{value} is not a directory" unless File.directory?(path)
          end
        end

        # The catch-all is the point, not the `UnusableHome` rename above it. This
        # lambda runs deep inside {Lain::CLI::ChatLaunch}, and only a
        # {Lain::Error} is rendered from there -- so every OTHER way resolution can
        # fail on a path a user TYPED (the `ArgumentError` a cwd outside its root
        # raises, an unreadable ancestor, a `.lain/config.rb` that will not run)
        # reached the terminal as a backtrace. Naming both flags and their values is
        # what makes the message actionable, since either one can be the wrong half.
        #
        # rubocop:disable Style/EnvHome -- {Lain::Project::Resolver.default_project}'s
        # own note, and this is the explicit-flag twin of it: `Dir.home` falls
        # through to getpwuid with HOME unset and raises a bare ArgumentError, which
        # is neither a Lain::Error this file can render nor a named refusal. `nil`
        # reaches Resolver::Home, which refuses it by name -- renamed here to the
        # same refusal `default_project` gives, so which flag was typed cannot
        # change what an unusable HOME says.
        def resolved_project(root:, cwd:)
          Lain::Project::Resolver.new(home: ENV.fetch("HOME", nil)).call(cwd:, root:).project
        rescue Lain::Project::Resolver::UnusableHome => e
          raise Lain::Project::Resolver::UnresolvableProject, e
        rescue StandardError => e
          raise ::Thor::Error, "cannot open --root #{root.inspect} at --cwd #{cwd.inspect}: #{e.message}"
        end
        # rubocop:enable Style/EnvHome
      end
    end
  end
end
