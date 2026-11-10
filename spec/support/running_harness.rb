# frozen_string_literal: true

# The running harness is a process-wide memo filled by git on first use. Filling it here
# keeps that git out of whichever unit example happens to record a session first, so a
# `--tag '~seam'` run under LAIN_SEAM_REPORT=1 names no file whatever the seed.
RSpec.configure do |config|
  config.before(:suite) { Lain::SessionRecord::Provenance.running_harness }
end
