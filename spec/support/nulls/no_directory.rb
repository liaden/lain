# frozen_string_literal: true

module SpecNulls
  # A {Lain::Tools::AskHuman::Directory} nothing registered with, so no caller
  # writes `if directory`. It refuses every answer in the same words a
  # withdrawn set earns, because with nothing registered every name is one
  # nobody holds -- a silent success would be a lie about a promise nothing
  # resolved.
  module NoDirectory
    def self.register(_asker) = Lain::Tools::AskHuman::Directory::Unheld
    def self.reply(answer, digest) = Lain::Tools::AskHuman::Directory::Unheld.reply(answer, digest)
    def self.awaiting?(_digest) = false
    def self.forget(registration) = registration
    def self.size = 0
    def self.unanswerable(digest) = Lain::Tools::AskHuman::Directory.unanswerable(digest)
  end
end
