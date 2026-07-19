# frozen_string_literal: true

module Lain
  module Isolation
    # The services a project's workers each need an ISOLATED instance of,
    # declared in a `.lain/services.rb` Ruby DSL (the `.lain/` convention, like
    # {Prompt::Slots} and {Skill::Catalog}). Loaded once into a frozen,
    # enumerable collection of declaration value objects; {DbIndex} reads it to
    # decide what to provision per worker, and an empty collection (no file, or
    # no declarations) makes it a code-only lease with nothing to provision --
    # Null-Object by an empty enumeration, not a nil check.
    #
    # The DSL is Rails-like: the file is the user's OWN Ruby, {Builder#instance_eval}'d
    # with no sandbox (the framework serves its user; shape-not-safety, exactly as
    # {Tool::Input} reads). Its surface is deliberate and stable -- `postgres` and
    # `redis`, each taking the same keywords the value object does -- and each call
    # returns its frozen declaration, so a future provisioning/port-discovery hook
    # (B4's compose port discovery) can chain off the returned service without
    # reshaping the loader.
    class Services
      include Enumerable

      # The project-scoped DSL file, on the `.lain/` convention (like `.git/`).
      DSL_PATH = File.join(".lain", "services.rb")

      # Read and evaluate `<root>/.lain/services.rb`. Absent file -> an empty
      # collection (a project simply declares no services), never an error.
      def self.load(root: Dir.pwd)
        path = File.join(root, DSL_PATH)
        File.exist?(path) ? new(Builder.build(File.read(path), path)) : new([])
      end

      def initialize(declarations)
        @declarations = declarations.freeze
        freeze
      end

      def each(&block) = @declarations.each(&block)

      def empty? = @declarations.empty?
    end
  end
end

require_relative "services/postgres"
require_relative "services/redis"
require_relative "services/builder"
