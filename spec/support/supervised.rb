# frozen_string_literal: true

# A supervisor needs a reactor, a `#run` and a `#stop`, and the stop has to be in an `ensure`:
# a failed expectation or any raise left a parked supervisor task behind, which hangs the
# reactor and reports nothing instead of failing the example. `#stop` is idempotent, so a body that
# stops the supervisor itself costs the ensure nothing.
module Supervised
  def supervised(supervisor = Lain::Supervisor.new)
    Sync do |task|
      supervisor.run(task)
      yield supervisor, task
    ensure
      supervisor.stop
    end
  end
end

RSpec.configure { |config| config.include Supervised }
