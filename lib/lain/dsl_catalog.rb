# frozen_string_literal: true

module Lain
  # The shape both `.lain/*.rb` DSL loaders wear. {Summarizer::Catalog} and
  # {Isolation::Services} had byte-identical loaders -- same exist-guard, same
  # `Builder.build(source, path)` dispatch, same frozen enumeration, same
  # empty-is-not-an-error posture -- and each named the OTHER in a comment as
  # "the posture I take". A shared base makes that agreement the code instead of
  # a cross-reference two files have to keep honest, and a third project DSL now
  # costs three lines.
  #
  # A subclass names two things and nothing else: WHERE its file lives and WHO
  # evaluates it.
  class DslCatalog
    include Enumerable

    # The DSL file, relative to a project root -- {ProjectDir.join} names it.
    # Read off the subclass's own `DSL_PATH`, which has to be a public constant
    # anyway ({CLI::IsolationBackend}'s NoComposeFile refusal prints one), so a
    # per-subclass forwarding method would be indirection and nothing else.
    def self.dsl_path
      raise NotImplementedError, "#{name} must name its DSL file in a DSL_PATH constant" \
        unless const_defined?(:DSL_PATH)

      const_get(:DSL_PATH)
    end

    # The evaluator, answering `.build(source, path)`. A class METHOD rather than
    # an argument to some `dsl ...` declaration because each Builder loads AFTER
    # its catalog's class body (the children-after-the-class-body order both
    # units use, per CLAUDE.md's Requires), so the constant can only resolve at
    # call time.
    def self.builder = raise NotImplementedError, "#{name} must name its DSL Builder"

    # Read and evaluate `<root>/<dsl_path>`. An absent file is an EMPTY catalog,
    # never an error: a project that declares nothing is the common case, so it
    # is Null-Object by an empty enumeration rather than a nil check every caller
    # repeats.
    #
    # `root` is explicit and never read at require time, so a spec -- and a bench
    # arm -- loads a catalog from a throwaway tree.
    def self.load(root: Dir.pwd)
      path = File.join(root, dsl_path)
      new(File.exist?(path) ? builder.build(File.read(path), path) : [])
    end

    # Frozen at both levels: the collection is a session-fixed SNAPSHOT, not a
    # mutable registry something can register into after load.
    def initialize(declarations)
      @declarations = declarations.freeze
      freeze
    end

    def each(&block) = @declarations.each(&block)

    def empty? = @declarations.empty?
  end
end
