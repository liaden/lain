# frozen_string_literal: true

# .lain/config.rb for a Ruby project. Run `lain trust` after editing it.

approval timeout: 900 do
  allow "bash", command: "bundle exec rspec"
  deny_tool "web_fetch"
end

sensitivity gated: %w[secrets.yml]

shell exclude: %w[curl]

tests preset: :rspec

isolation verify: %w[bundle exec rake spec], verify_timeout: 900,
          check: %w[bundle exec rspec], lint: %w[bundle exec rubocop], lint_files: ["**/*.rb"]
