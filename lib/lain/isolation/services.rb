# frozen_string_literal: true

module Lain
  module Isolation
    # The services a project's workers each need an ISOLATED instance of,
    # declared in a `.lain/services.rb` Ruby DSL (the `.lain/` convention, like
    # {Prompt::Slots} and {Skill::Catalog}). {DslCatalog} owns the loading half
    # -- one frozen, enumerable, session-fixed collection of declaration value
    # objects, and an absent file that means an EMPTY one rather than an error.
    # {DbIndex} reads it to decide what to provision per worker, so an empty
    # collection is a code-only lease with nothing to provision: Null-Object by
    # an empty enumeration, not a nil check.
    #
    # The DSL is Rails-like: the file is the user's OWN Ruby, {Builder#instance_eval}'d
    # with no sandbox (the framework serves its user; shape-not-safety, exactly as
    # {Tool::Input} reads). Its surface is deliberate and stable -- `postgres` and
    # `redis`, each taking the same keywords the value object does -- and each call
    # returns its frozen declaration, so a future provisioning/port-discovery hook
    # (B4's compose port discovery) can chain off the returned service without
    # reshaping the loader.
    class Services < DslCatalog
      # The project-scoped DSL file, on the `.lain/` convention (like `.git/`).
      # Public because {CLI::IsolationBackend}'s NoComposeFile refusal names it
      # back to the user.
      DSL_PATH = ProjectDir.join("services.rb")

      # Resolved at CALL time: {Builder} loads after this class body (see the
      # note at the foot of this file), so a constant read here would NameError.
      def self.builder = Builder
    end
  end
end

# All four are nested INSIDE the class above, so they load after its body (the
# children-after-the-class-body order effect/handler.rb uses) -- which is why
# {Services.builder} names {Builder} in a method rather than a constant.
require_relative "services/postgres"
require_relative "services/redis"
require_relative "services/compose"
require_relative "services/builder"
