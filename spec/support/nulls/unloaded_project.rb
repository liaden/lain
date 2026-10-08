# frozen_string_literal: true

module SpecNulls
  # The state home and project config a spec hands a toolset build that never
  # submits to an epic gate: the real default paths, and a config with no
  # `.lain/config.rb` behind it.
  #
  # @return [Hash{Symbol => Object}] `paths:` and `config:`, to splat
  def self.unloaded_project
    { paths: Lain::Paths.new, config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg)) }
  end
end
