# frozen_string_literal: true

module Lain
  # What the disk says about a path -- where it lands, whether it is a link, a file or a
  # directory, what a directory holds -- asked of one object instead of File and Dir.
  #
  # The approval stack judges a path where it lands, so its answer depends on the disk at the
  # moment it asks. {LIVE} is that disk, and what every reading site uses unless handed another.
  # {Recorded} answers from what a session journaled instead, so a replay re-decides a call
  # against the state it was decided in rather than against today's tree.
  module FileFacts
    LIVE = Live.new
  end
end
