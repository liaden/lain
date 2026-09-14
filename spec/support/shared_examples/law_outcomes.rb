# frozen_string_literal: true

# Reading a battery's laws as a negative. A spec that shows an operation is NOT
# some structure runs the battery and requires the named law to be `:fails` --
# and a law that RAISED was never evaluated, so it can neither confirm nor deny
# anything. Each law therefore answers `:holds`, `:fails`, or the exception it
# raised, kept apart so a refutation cannot be confirmed by a NoMethodError.
#
# One reading, beside the batteries it reads: written out per spec, the copies
# had already drifted (one kept the exception, one only its class).
module AlgebraLaws
  def self.outcomes(battery)
    battery.to_h.transform_values do |law|
      law.call ? :holds : :fails
    rescue StandardError => e
      e
    end
  end
end
