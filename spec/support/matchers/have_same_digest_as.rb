# frozen_string_literal: true

# Content-addressed equality by name, not by `==`: two values name the same
# digest without necessarily being the same class (a Turn and a raw digest
# String both answer `#digest`-shaped questions at different call sites). This
# is the ~354-site `a.digest == b.digest` idiom, with a failure message that
# names the actual hex prefixes rather than "expected true, got false".
RSpec::Matchers.define :have_same_digest_as do |expected|
  match do |actual|
    @actual_digest = actual.digest
    @expected_digest = expected.digest
    @actual_digest == @expected_digest
  end

  failure_message do |actual|
    "expected #{actual.class}##{short(@actual_digest)} to have the same digest as " \
      "#{expected.class}##{short(@expected_digest)}, but they differ"
  end

  failure_message_when_negated do |actual|
    "expected #{actual.class}##{short(@actual_digest)} not to have the same digest as " \
      "#{expected.class}##{short(@expected_digest)}, but both digest to #{short(@actual_digest)}"
  end

  # Hex prefix only -- long enough to eyeball a real divergence, short enough
  # to read in a one-line failure (mirrors the `digest[0, 19]` convention in
  # Turn#to_s / Request#to_s / Memory::Item#to_s).
  def short(digest)
    digest.to_s[0, 19]
  end
end
