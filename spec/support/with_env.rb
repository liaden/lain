# frozen_string_literal: true

# Scoped ENV mutation for the examples that still need it (provider keys read
# at construction, XDG paths in retargeted bodies): set, yield, ALWAYS restore
# -- distinguishing "was unset" from "was empty" so restoration is exact.
# Prefer the injection seams (Lain::Paths.new(env:), Chronicle.for(paths:))
# where they exist; this helper is for the collaborators that read ENV
# directly and owe an injection seam later.
module WithEnv
  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV.fetch(k, :__unset__)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v == :__unset__ ? ENV.delete(k) : (ENV[k] = v) }
  end
end

RSpec.configure { |config| config.include WithEnv }
