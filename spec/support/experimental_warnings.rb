# frozen_string_literal: true

# exe/lain silences Ruby's experimental-feature warnings, so the spec process
# does too: the first IO::Buffer use otherwise prints to whatever $stderr an
# example has captured, and which example gets it depends on the run order.
Warning[:experimental] = false
