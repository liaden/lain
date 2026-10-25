# frozen_string_literal: true

module Lain
  # A loopback process the human runs beside a chat, through which a model
  # request may reach a cloud upstream. It holds its own secret set and its
  # own credentials, built in its own process, so a chat that is compromised
  # can neither read the key nor talk the gateway out of its inspection.
  module Gateway
    # Keyed by the exact base, so a spelling the table lacks is refused
    # rather than normalised into one it holds.
    UPSTREAMS = {
      "https://ollama.com" => {
        auth_header: "Authorization", key_env: "OLLAMA_API_KEY", credential: "Bearer %s",
        paths: ["/api/chat"].freeze, headers: {}.freeze
      }.freeze,
      # The client's headers are not forwarded, and the Messages API refuses a request without a version.
      "https://api.anthropic.com" => {
        auth_header: "x-api-key", key_env: "ANTHROPIC_API_KEY", credential: "%s",
        paths: ["/v1/messages"].freeze, headers: { "anthropic-version" => "2023-06-01" }.freeze
      }.freeze
    }.freeze
  end
end
