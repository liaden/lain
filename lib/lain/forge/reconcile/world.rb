# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Forge
    class Reconcile
      # Observes the remote and GitHub state needed to reconcile Forge intents.
      class World
        def initialize(heads:, github:)
          @heads = heads
          @github = github
        end

        def self.live(repo_root:, github:, remote: "origin", shell_out_factory: Mixlib::ShellOut.public_method(:new))
          new(heads: Promotion::Remote.new(repo_root:, remote:, shell_out_factory:), github:)
        end

        def ref_exists?(ref) = remote_heads.key?(ref)

        def sha_of(ref) = remote_heads[ref]

        def pr_for(head:)
          pull_requests = listed(head)
          return nil if pull_requests.empty?
          return pull_requests.first if pull_requests.one?

          raise Unobservable, "cannot observe pull request for #{head}: GitHub returned #{pull_requests.size} matches"
        end

        def pr_state(number)
          document = observed(@github.pr_view(ref: number, fields: ["state"]), "pull request #{number}")
          unless document.is_a?(Hash)
            raise Unobservable, "cannot observe pull request #{number}: GitHub returned a non-object response"
          end

          state = document["state"]
          return state unless state.nil?

          raise Unobservable, "cannot observe pull request #{number}: GitHub returned no state"
        end

        private

        def listed(head)
          result = observed(@github.pr_list(head:), "pull requests for #{head}")
          return result if result.is_a?(Array) && result.all?(Hash)

          raise Unobservable, "cannot observe pull requests for #{head}: GitHub returned a non-list response"
        end

        def remote_heads
          @remote_heads ||= @heads.heads
        rescue Error => e
          raise Unobservable, "cannot observe remote refs: #{e.message}"
        end

        def observed(answer, address)
          return answer.value if answer.respond_to?(:ok?) && answer.ok?

          detail = answer.respond_to?(:detail) ? answer.detail.inspect : answer.inspect
          raise Unobservable, "cannot observe #{address}: #{detail}"
        end
      end
    end
  end
end
