# frozen_string_literal: true

module SpecNulls
  # Where a spec that wires no epic home sends epic_write: a call refuses by
  # name rather than writing into somebody's real state home.
  module NoEpicHomes
    def self.for(_slug) = raise(Lain::Error, "this spec wired no epic home")
  end

  # The mount a chat in no epic is handed, built as {Lain::CLI::EpicMount.for}
  # builds one, for a spec that constructs a toolset or a driver directly.
  #
  # @return [Lain::CLI::EpicMount::NoEpic]
  def self.unmounted_epic = Lain::CLI::EpicMount::NoEpic.new(homes: NoEpicHomes)
end
