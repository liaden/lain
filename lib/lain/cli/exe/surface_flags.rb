# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # The opt-in surface that answers a PARKED approval beside the human: a
      # meta-agent racing the person the queue is already asking. Grouped into a
      # declarer of its own on {ModelFlags}' rule, because the Thor class has no
      # Metrics/ClassLength headroom for another `method_option`.
      #
      # The secret oracle judges only pendings that would release something
      # sensitive ({Approval::Parked::SecretSurface} filters structurally).
      module SurfaceFlags
        SECRET_ORACLE = "Wire an extra approval surface: a model triages parked reads that WOULD release sensitive " \
                        "regions, racing the human's own surfaces. It is shown the path and the region count, never " \
                        "the file's contents. local asks the local ollama, never a remote provider whatever " \
                        "--provider says; cloud asks a hosted model only through the lain gateway --gateway names"
        SECRET_ORACLE_MODEL = "The secret oracle's model: #{Lain::Provider::Ollama::DEFAULT_MODEL} by default for " \
                              "local, required for cloud. A local tier refuses a cloud model name".freeze
        GATEWAY = "The URL `lain gateway` printed, http://127.0.0.1:<port> with no token; the chat reads the token " \
                  "from the file the gateway left under the state home. Required by --secret-oracle cloud, which " \
                  "proves the gateway at launch and before every question"
        SUPERVISE_EGRESS = "Hold outbound model requests for the human: all parks each one, oracle parks only the " \
                           "secret oracle's, showing who sends it, its endpoint, size and digest, never its " \
                           "body. Not held: the local ollama server's model metadata probe at launch, and the " \
                           "secret oracle's gateway identity probe, which carries only a nonce. With nobody " \
                           "attached, a held request is refused"

        # @param thor [Class] the Thor class to declare on
        # @return [void]
        def self.declare(thor)
          thor.method_option :secret_oracle, type: :string, enum: %w[off local cloud], default: "off",
                                             desc: SECRET_ORACLE
          thor.method_option :secret_oracle_model, type: :string, banner: "NAME", desc: SECRET_ORACLE_MODEL
          thor.method_option :gateway, type: :string, banner: "URL", desc: GATEWAY
          thor.method_option :supervise_egress, type: :string, enum: %w[off oracle all], default: "off",
                                                desc: SUPERVISE_EGRESS
        end
      end
    end
  end
end
