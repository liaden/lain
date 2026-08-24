# frozen_string_literal: true

# Gating for the :ollama_cloud tag -- an example that spends somebody's quota
# against a real Ollama Cloud subscription, over the real network, with a real
# key.
#
# It is NOT :ollama (spec/support/ollama_tag.rb). That tag's own header states
# the distinction: ":ollama examples cost no money" and it probes LOCALHOST for
# reachability. This one costs quota against somebody's paid plan and needs a
# key, which is spec/support/tags.rb's :api_integration posture -- so the
# gating idiom is copied from there: an opt-in env var AND a key present, both
# required, neither sufficient alone.
#
#     LAIN_OLLAMA_CLOUD=1 OLLAMA_API_KEY=... bundle exec rspec spec/integration/provider/ollama_cloud_spec.rb
#
# There is no reachability pre-check here, unlike :ollama's OllamaTestServer.
# :ollama probes because a stopped LOCAL server is an everyday environment gap
# worth a friendly skip; there is no equivalent "is ollama.com up" question --
# the one live consumer (T12) makes real requests and asserts on what comes
# back, so a synthetic probe here would just be a second billed request in
# front of the first.
module OllamaCloudTag
  # Takes its input as an argument, defaulting to ENV, for the same reason
  # VcrRecording's methods do (see vcr_configuration.rb): it lets a spec probe
  # "opt-in without a key" and "a key without opt-in" without mutating
  # process-wide ENV, which a parallel worker could still be reading.
  def self.enabled?(env: ENV)
    env["LAIN_OLLAMA_CLOUD"] == "1" && !env["OLLAMA_API_KEY"].to_s.empty?
  end
end

OLLAMA_CLOUD_ENABLED = OllamaCloudTag.enabled?

RSpec.configure do |config|
  # :ollama_cloud examples reach the real network for their duration only, then
  # isolation is restored even on raise -- the same permission :api_integration
  # and :ollama take, through the same object (ExampleNetwork, referenced only
  # inside this block: see vcr_configuration.rb for why a support file may name
  # a constant another support file defines without a load-order dependency).
  config.around(:each, :ollama_cloud) do |example|
    ExampleNetwork.permit(example.metadata) { example.run }
  end

  unless OLLAMA_CLOUD_ENABLED
    config.filter_run_excluding(:ollama_cloud)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :ollama_cloud specs. Set LAIN_OLLAMA_CLOUD=1 and OLLAMA_API_KEY to run them."
      )
    end
  end
end

# The offline-default guards for this tag are untagged real specs in
# spec/network_posture_spec.rb, mirroring :ollama's own -- see that file's
# header for why they live there rather than here.
