# frozen_string_literal: true

module SpecNulls
  # A real {Lain::CLI::Wiring::Askers} wired to nothing: its arrivals reach a
  # queue nobody drains and its Q events reach an observer that forgets them.
  # For the direct-construction seams the specs drive, and never a production
  # state -- a child enrolled here parks a human question nobody can see. The
  # exe always passes the run's own.
  #
  # A factory rather than a shared instance, because an Askers owns a live
  # queue and a directory: two specs sharing one would route the second's
  # answer to the first's asker.
  module UnwiredAskers
    def self.build
      Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new)
    end
  end
end
