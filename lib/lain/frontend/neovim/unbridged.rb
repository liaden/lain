# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The resend bridge's Null: the offer is declined WITHOUT forcing the
      # rebuild block, so :LainResend stays a pure projection -- journaled,
      # diffed, dispatched nowhere -- even for an edit that parses as JSON but
      # would not rebuild into a {Request}. Nil, not a notice: projection-only
      # is this configuration's normal, never an error to report per resend.
      module Unbridged
        module_function

        # Accepts (and ignores) the wired bridge's whole signature -- the
        # `on_attempt:` upfront-notice hook and the rebuild block included -- so
        # the frontend's one call site is identical whichever duck it holds. The
        # hook is never fired: projection-only makes no attempt to announce.
        def offer(**) = nil
      end
    end
  end
end
