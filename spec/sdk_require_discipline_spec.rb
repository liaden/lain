# frozen_string_literal: true

# The `anthropic` SDK is a TEST-ONLY dependency, and it is loaded lazily: the
# oracle providers (spec/support/provider_oracles/) require it inside
# #initialize rather than at file scope, because spec/support loads in every
# `rake pspec` worker and the gem is 33.6MB. Measured: 3 of 8 workers construct
# an oracle and pay for it; the other 5 never load it at all.
#
# The cost of that is an ORDER DEPENDENCY, and this spec is its guard.
#
# A spec file that names an SDK constant BEFORE any oracle is constructed sees
# an unloaded gem, and fails two different ways depending on how it spells it:
#
#   Anthropic::Errors::RateLimitError.new(...)   -> NameError, loud but flaky:
#       it only fires when a worker happens to run that example before any
#       other example built an oracle. Serial runs order it luckily and stay
#       green; `rake pspec` reordered it and reddened 2 of 6 runs.
#
#   instance_double("Anthropic::BedrockMantleClient")  -> SILENT. RSpec
#       verifies a doubled constant only if it is DEFINED; undefined, it
#       degrades to a non-verifying double that accepts any message. The spec
#       passes while having verified nothing -- strictly worse than the crash.
#
# Both are fixed by one line, `require "anthropic"`, in the file that names the
# constant. Only the workers owning that file pay, so the saving survives. This
# spec exists so that line is enforced rather than remembered.
# The pattern, kept out of the RSpec block for Lint/ConstantDefinitionInBlock.
module SDKRequireDiscipline
  # Top-level `Anthropic::` -- the SDK. Deliberately NOT our own
  # `Lain::Provider::Anthropic`, `Provider::AnthropicReference`,
  # `AnthropicEncoding` or the `AnthropicSSE` helper, none of which need the
  # gem. The lookbehind rejects any qualified name, so only a bare (or
  # explicitly top-level `::`) Anthropic counts.
  CONSTANT = /(?<![:\w])(?:::)?Anthropic::(?:Errors|Client|BedrockMantleClient|Resources|Models|Internal)\b/
end

RSpec.describe "the anthropic SDK's require discipline" do
  def sdk_reference?(line)
    stripped = line.strip
    return false if stripped.start_with?("#")

    stripped.match?(SDKRequireDiscipline::CONSTANT)
  end

  # Every spec file, including this one's own tree -- a guard that skipped a
  # directory would be a guard with a hole in it.
  def spec_files = Dir.glob(File.expand_path("**/*_spec.rb", __dir__))

  it "names at least one SDK constant somewhere, or this guard is vacuous" do
    offenders = spec_files.select { |file| File.readlines(file).any? { |line| sdk_reference?(line) } }

    expect(offenders).not_to be_empty
  end

  it "requires the gem in every spec file that names an SDK constant" do
    missing = spec_files.filter_map do |file|
      body = File.read(file)
      next unless body.each_line.any? { |line| sdk_reference?(line) }
      next if body.match?(/^\s*require ["']anthropic["']/)

      file.sub("#{File.expand_path("..", __dir__)}/", "")
    end

    expect(missing).to be_empty, <<~MESSAGE
      These spec files name an `Anthropic::` SDK constant but never require the gem:

      #{missing.map { |file| "  #{file}" }.join("\n")}

      The oracle providers load it lazily (see this file's header), so the
      constant resolves only if some earlier example already built one -- which
      is luck, not a guarantee. Add `require "anthropic"` at the top of each
      file listed. Only the worker that owns the file pays for it.
    MESSAGE
  end
end
