# frozen_string_literal: true

module Lain
  module Forge
    class Gh
      # The one REST path this executor builds, and the guard on the only caller
      # value that ever reaches one.
      #
      # An object rather than two private methods on {Gh}, and the responsibility
      # is real: every other verb hands a caller's value over as its OWN argv
      # element, where it cannot be anything but a single argument however it is
      # spelled. {Gh#submit_review} interpolates, because `gh api` takes the
      # endpoint as one string -- so this is the only place in the tier where
      # "what may go in" is a question at all, and the check belongs beside the
      # interpolation rather than a screen away from it.
      #
      # `{owner}` and `{repo}` are left as gh's OWN placeholders, substituted
      # from the repository of the directory gh runs in. So the repo is still
      # resolved by `cwd`, exactly as it is for the four verbs that name no
      # endpoint, and no caller has to know which repository it is talking to.
      module Endpoint
        # Digits and nothing else, which is stricter than `Integer()` on purpose.
        #
        # `Integer("0x10")` is 16 and `Integer(7.9)` is 7. Both SILENTLY address
        # a pull request the caller did not name, and a review posted to the
        # wrong pull request is not an error anything downstream can undo -- a
        # batched review POST is not idempotent, so there is no un-posting it.
        #
        # Not anchored with `^`/`$`, which match at a NEWLINE: `"7\n../../secret"`
        # would pass those and put a traversal in the path.
        NUMBER_ONLY = /\A\d+\z/

        # @param number [Integer, String] the pull request
        # @return [String] `repos/{owner}/{repo}/pulls/<n>/reviews`
        # @raise [ArgumentError] naming the verb and the value, for a number that
        #   is not simply a number
        def self.reviews(number) = "repos/{owner}/{repo}/pulls/#{number!(number)}/reviews"

        # The message names the VERB, which `Kernel#Integer`'s own wording does
        # not: a bare `invalid value for Integer(): "0x10"` in a landing's output
        # names neither gh nor this class, and gives an operator nowhere to
        # start. {Source::GithubPr::Remote} reaches the same conclusion from the
        # other end, matching digits out of a ref before calling `Integer(text, 10)`.
        #
        # @param number [Integer, String]
        # @return [Integer]
        def self.number!(number)
          text = number.to_s
          unless text.match?(NUMBER_ONLY)
            raise ArgumentError, "submit_review needs a pull request number, got #{number.inspect} -- " \
                                 "this one is interpolated into the API path, so it must be digits alone"
          end

          Integer(text, 10)
        end
      end
    end
  end
end
