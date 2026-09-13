# frozen_string_literal: true

module Lain
  module Isolation
    # The services a project's workers each need an ISOLATED instance of,
    # declared in a `.lain/services.rb` Ruby DSL. {DslCatalog} owns the loading
    # half -- one frozen, enumerable, session-fixed collection of declaration
    # value objects, and an absent file that means an EMPTY one rather than an
    # error. An empty collection is a lease with nothing to provision:
    # Null-Object by an empty enumeration, not a nil check.
    #
    # The file is the user's OWN Ruby, `instance_eval`'d with no sandbox --
    # shape, not safety, exactly as {Tool::Input} reads. Each DSL call returns
    # its frozen declaration, so a provisioning or port-discovery hook can chain
    # off the returned service without reshaping the loader.
    class Services < DslCatalog
      # Public because {CLI::IsolationBackend}'s missing-compose-file refusal
      # names it back to the user.
      DSL_PATH = ProjectDir.services

      # Resolved at CALL time: {Builder} loads after this class body, so a
      # constant read here would NameError.
      def self.builder = Builder
    end
  end
end

# All three are nested INSIDE the class above, so they load after its body --
# which is why {Services.builder} names {Builder} in a method, not a constant.
require_relative "services/postgres"
require_relative "services/compose"
require_relative "services/builder"
