# frozen_string_literal: true

# The header sections a real launch writes, built from the same values a
# launch resolves, so a spec that scribes a header carries provenance, a run
# profile and arms instead of omitting them. The harness is a fixed string
# because the real one shells out to git.
module SessionSections
  module_function

  # @param overrides [Hash] sections to replace, as {Lain::SessionRecord::Sections.new} takes them
  # @return [Lain::SessionRecord::Sections]
  def complete(**overrides)
    provenance = Lain::SessionRecord::Provenance.current(toolset: Lain::Toolset.new([]), root: "/spec/root",
                                                         cwd: "/spec/root", home: "/spec/home", effort: nil,
                                                         policy: "spec-policy", harness: "spec-harness")
    Lain::SessionRecord::Sections.new(
      profile: Lain::CLI::RunProfile.from_options({ provider: "anthropic" }).to_header,
      arms: Lain::CLI::Arms::DEFAULT.to_header, provenance: provenance.to_header, **overrides
    )
  end

  # @return [Lain::CLI::RunProfile] a profile with nothing typed, for a door that compares against the header
  def untyped = Lain::CLI::RunProfile.from_options({})
end
