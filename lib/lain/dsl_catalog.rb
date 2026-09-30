# frozen_string_literal: true

module Lain
  # The shape both `.lain/*.rb` DSL loaders wear. {Summarizer::Catalog} and
  # {Isolation::Services} had byte-identical loaders, each naming the OTHER in a
  # comment as "the posture I take"; a shared base makes that agreement the code
  # rather than a cross-reference two files have to keep honest.
  #
  # A subclass names two things and nothing else: WHERE its file lives and WHO
  # evaluates it.
  class DslCatalog
    include Enumerable

    # Read off the subclass's own `DSL_PATH`, which has to be a public constant
    # anyway -- {CLI::IsolationBackend}s missing-compose-file refusal prints one -- so
    # a per-subclass forwarding method would be indirection and nothing else.
    def self.dsl_path
      raise NotImplementedError, "#{name} must name its DSL file in a DSL_PATH constant" \
        unless const_defined?(:DSL_PATH)

      const_get(:DSL_PATH)
    end

    # A METHOD where {.dsl_path} above demands a CONSTANT, and the asymmetry is
    # the two readers: `DSL_PATH` is public surface a refusal prints
    # ({CLI::IsolationBackend}'s missing-compose-file sentence), so it has to be
    # a constant anyway and a forwarding method would be indirection. A builder
    # has no reader outside {.load}, so the subclass declares it by OVERRIDING,
    # which is also what makes the un-overridden case a named NotImplementedError
    # rather than a `const_defined?` check restated per subclass.
    def self.builder = raise NotImplementedError, "#{name} must name its DSL Builder"

    # An absent file is an EMPTY catalog, never an error: a project that
    # declares nothing is the common case, so it is Null-Object by an empty
    # enumeration rather than a nil check every caller repeats. `root` is
    # REQUIRED: defaulted to the working directory, a chat started in a
    # subdirectory read no catalog at all.
    #
    # A present file runs only once {Project::Trust} says its bytes are
    # trusted, and what runs is the bytes the trust was judged on. A catalog
    # whose own file is absent reads nothing else, so an unreadable sibling
    # cannot refuse it; one gone by the time trust reads is absent too.
    #
    # @param root [String] the project root the DSL file sits under
    # @param paths [Paths] supplies the state home the trust marks live under
    # @return [DslCatalog]
    # @raise [Project::Trust::Untrusted] when the file's bytes are not trusted
    def self.load(root:, paths: Paths.new)
      path = File.join(root, dsl_path)
      return new([]) unless File.file?(path)

      trust = Project::Trust.for(project_dir: ProjectDir.new(root:, paths:), paths:)
      source = trust.sources[path]
      return new([]) if source.nil?

      # `builder` resolved HERE, outside {.read}'s rescue: a subclass that
      # names none raises NotImplementedError, which -- being a ScriptError --
      # would otherwise be caught and misreported as a broken DSL FILE rather
      # than the subclass's own missing declaration.
      evaluator = builder
      trust.require!
      new(read(evaluator, path, source))
    end

    # Both Builders `instance_eval` the user's own file with no sandbox, so a
    # typo raises straight out of Ruby -- a bad constant, a bad keyword
    # argument, unbalanced `do`/`end` -- naming this gem's OWN frames rather
    # than the one file a project author can fix. Translated here, once, so
    # `exe/lain`'s ordinary `rescue Lain::Error` is what a broken `.lain/*.rb`
    # ever reaches, instead of a fourteen-frame backtrace.
    def self.read(evaluator, path, source)
      evaluator.build(source, path)
    # NoMethodError is a NameError, so naming it too would only shadow it.
    rescue ScriptError, ArgumentError, NameError => e
      raise Error, refusal_message(e, path)
    end
    private_class_method :read

    # A SyntaxError's own message already names `path:line` -- Ruby embeds it
    # while parsing, before any backtrace exists -- so that message is used
    # verbatim. Everything else raises from somewhere inside the Builder
    # itself, so the location is read off the first backtrace frame the
    # EVALUATED file left behind, the one instance_eval's own `path`/`lineno`
    # arguments stamped.
    # @param error [Exception] what the evaluated file raised
    # @param path [String] the file evaluated
    # @return [String] the message, led by `path:line` where one is known
    def self.refusal_message(error, path)
      return error.message if error.message.start_with?("#{path}:")

      frame = Array(error.backtrace).find { |line| line.start_with?("#{path}:") }
      frame ? "#{frame[/\A#{Regexp.escape(path)}:\d+/]}: #{error.message}" : "#{path}: #{error.message}"
    end

    # Frozen at both levels: a session-fixed SNAPSHOT, not a mutable registry
    # something can register into after load.
    def initialize(declarations)
      @declarations = declarations.freeze
      freeze
    end

    def each(&block) = @declarations.each(&block)

    def empty? = @declarations.empty?
  end
end
