# frozen_string_literal: true

isolation verify: %w[bin/verify], verify_timeout: 1800

approval do
  allow "bash", command: "bin/verify"
end
