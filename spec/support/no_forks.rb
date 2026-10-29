# frozen_string_literal: true

# The fork scan of a spec that never draws a fork line: lain://tree finds no child files.
module NoForks
  def no_forks = -> { {} }
end

RSpec.configure { |config| config.include(NoForks) }
