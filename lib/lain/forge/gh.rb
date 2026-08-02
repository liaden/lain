# frozen_string_literal: true

require "json"
require "mixlib/shellout"

module Lain
  module Forge
    # The tier's one door out to GitHub, and it is a narrow one: four verbs, each
    # spelling its own **argv array** through an injected `shell_out_factory` --
    # the seam {Isolation::Worktree} and seven siblings already use. There is no
    # verb that takes a command string, and there is no `sh -c` anywhere in this
    # file, so nothing a model wrote can reach a shell through here. That is what
    # "tier 2 by construction" means: not a check that a string is safe, but a
    # surface with no place to put one.
    #
    # == Every failure is a value
    #
    # gh refusing, gh printing something unreadable, gh running past its bound --
    # each answers a not-ok {Answer} carrying why, never a raised
    # `JSON::ParserError` or a leaked `Mixlib::ShellOut::CommandTimeout`. A
    # landing folds on these answers and journals them ({Journaled}), so a
    # refusal has to be a value the fold can carry; an exception would be a
    # second control path the journal never sees.
    #
    # A subprocess that cannot run AT ALL (no `gh` on PATH) still raises, and
    # that is the honest difference: gh answering "no" is data, gh not existing
    # is a broken machine. {Journaled} records the attempt as not-ok and lets it
    # through.
    #
    # == Observed, never forced
    #
    # {#pr_create} reads gh's "already exists" refusal as an OBSERVED success
    # when it can recover the existing number -- the `Handback#preserve` /
    # `Salvage#already_committed?` doctrine that idempotency is asked of the
    # remote rather than remembered locally. Nothing here ever forces.
    #
    # Written against **gh 2.96.0**, which answers every field used below.
    class Gh
      # GitHub's own word for "mergeability not computed yet". It is not a
      # verdict: querying is what SCHEDULES the computation, which is why
      # {#merge_state} polls rather than believing the first answer.
      UNKNOWN = "UNKNOWN"

      # The `--json` field {#merge_state} reads. A document that does not carry
      # it is NAMED rather than compared against nil (see {#missing_field}).
      MERGE_STATE_FIELD = "mergeStateStatus"

      # The gh this file was written and verified against: `gh pr view --json`
      # there lists every field read below. Recorded as a fact, not as a floor --
      # nothing here refuses an older gh, and {#missing_field} deliberately does
      # not blame one.
      VERIFIED_GH = "2.96.0"

      # gh refuses a non-interactive `pr merge` without a merge method, so one
      # has to be pinned.
      #
      # A merge commit rather than a squash or a rebase, and the reason is
      # ARCHAEOLOGY, not a mechanism anything reads today: promotion (T18) pushes
      # an ANCHORED sha, the journal names that sha, and `--merge` is the only
      # one of gh's three methods that leaves it reachable in the repository
      # afterwards. Squash and rebase-merge both rewrite it, so a journal line
      # naming a sha that no longer exists is all a later reader gets.
      #
      # To be clear about what this does NOT do: {Reconcile} does not read main.
      # `promoted?` asks about the epic branch ref and its sha, and `merged?`
      # asks a pull request's state -- neither changes with the merge method. The
      # choice buys a readable history, not a working fold.
      #
      # THE OTHER WAY THIS FAILS: a repository configured squash-only (or
      # rebase-only) refuses every `--merge`. That degrades correctly -- a
      # structured refusal carrying GitHub's own message about the setting, never
      # an exception -- but the landing then simply never completes, and nothing
      # in that message names this constant. A landing that stalls on every merge
      # with a repo-policy refusal is pointing HERE.
      MERGE_METHOD = "--merge"

      # A wedged `gh` must not stall the bench that is driving it, so every call
      # is bounded -- {Grader::TestHarness::DEFAULT_TIMEOUT}'s reasoning at the
      # scale of one API round trip.
      DEFAULT_TIMEOUT = 60

      # The number in a pull request URL, which is how gh reports both a created
      # pull request (on stdout) and an already-existing one (in its refusal).
      PR_NUMBER = %r{/pull/(\d+)}

      # gh's wording for a head ref that already has a pull request. Matched
      # NARROWLY and only alongside a recoverable number, because this string is
      # not a documented interface (see {#already_open}).
      ALREADY_EXISTS = /already exists/i

      # Bounded polling with a wait between attempts.
      #
      # Extracted because "how many times, and how long between" is a policy of
      # its own, separate from what gh answers -- and it is the ONE place the
      # injected sleeper is used, so a spec builds a Poll whose sleeper records
      # instead of sleeping and no example ever waits a real second
      # ({CLI::Watch}'s sleeper seam, same shape).
      class Poll
        DEFAULT_BOUND = 5
        DEFAULT_INTERVAL = 2
        DEFAULT_SLEEPER = ->(seconds) { sleep(seconds) }

        def initialize(bound: DEFAULT_BOUND, interval: DEFAULT_INTERVAL, sleeper: DEFAULT_SLEEPER)
          raise ArgumentError, "a poll must run at least once, got bound #{bound.inspect}" unless bound.to_i.positive?

          @bound = bound.to_i
          @interval = interval
          @sleeper = sleeper
          freeze
        end

        # Run `attempt` until `settled` accepts its result or the bound runs out,
        # waiting between attempts.
        #
        # `inject` over the REMAINING attempts, seeded with the first one, is
        # what keeps this free of a `break`: once a result settles it is simply
        # carried forward and the block is never called again.
        #
        # @param settled [#call] answers true for a result worth stopping on
        # @return the first settled result, or the last one taken
        def take(settled:, &attempt)
          (2..@bound).inject(yield) do |taken, _|
            settled.call(taken) ? taken : wait_then(&attempt)
          end
        end

        private

        # The wait is BETWEEN attempts and never before the first: GitHub
        # computes mergeability lazily and it is the query that schedules the
        # computation, so sleeping first would only delay the request that starts
        # the work.
        def wait_then(&attempt)
          @sleeper.call(@interval)
          yield
        end
      end

      # What one verb answered.
      #
      # `detail` is the whole journalable payload and `value` is a READER over
      # it, not a second member -- which is what makes a replay exact: {Recorded}
      # rebuilds an Answer from a journaled {Outcome}'s detail and cannot
      # disagree with the live one about what the call returned. A separate
      # member would have to be re-derived, and re-derivation is where two
      # readings of one record drift apart.
      Answer = Data.define(:ok, :observed, :detail) do
        # rubocop:disable Naming/MethodParameterName -- `ok` is {Outcome}'s
        # journaled field name, which this value is folded into verbatim; a
        # longer parameter would have to be renamed back on the way to the wire.
        def initialize(ok:, observed: false, detail: {})
          Guards::Answer.check!(ok:, observed:)

          super(ok:, observed:, detail: Canonical.normalize(detail.to_h))
        end
        # rubocop:enable Naming/MethodParameterName

        def ok? = ok

        def observed? = observed

        # @return [Object, nil] what the caller asked for -- a pull request
        #   number, a parsed document, a merge state -- and nil when the call
        #   did not produce one.
        def value = detail["value"]
      end

      # This class's construction contract, in the house validate-then-freeze
      # convention. Named {Guards} like {Forge::Guards} and shadowing it inside
      # this lexical scope, which is harmless because nothing here reaches for
      # the record guards -- {Journaled} owns that.
      module Guards
        # Both flags are FOLDED on downstream and both go on the wire through
        # {Outcome}, whose own guard refuses a non-boolean for the same reason:
        # a missing field reads as `false`, and `false` here is a verdict nobody
        # reached.
        #
        # The PAIR is checked too, not just each flag alone. `observed` means the
        # effect was found already in place and confirmed, which entails success,
        # so `ok: false, observed: true` is a verdict nobody can mean. Left
        # representable it would be reachable two ways: a future verb building
        # one by hand, and -- the real one -- {Recorded#replay}, which copies both
        # flags straight out of a journaled {Outcome}, so a truncated or
        # hand-edited journal would replay a contradiction as though somebody had
        # decided it.
        class Answer < Guard
          attribute :ok
          attribute :observed
          validates :ok, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
          validates :observed, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
          validate :observed_entails_ok

          private

          def observed_entails_ok
            return unless observed == true && ok == false

            errors.add(:observed, "means the effect was found already in place, which is a success -- " \
                                  "it cannot stand on a not-ok answer")
          end
        end
      end

      # @param cwd [String] where gh runs, which is how it resolves WHICH repo it
      #   is talking to -- a landing runs inside a leased worktree
      # @param timeout [Numeric] seconds one gh call may take
      # @param poll [Poll] the UNKNOWN retry policy, and the home of the sleeper
      # @param shell_out_factory [#call] builds the subprocess runner, injected
      #   exactly as {Isolation::Worktree} and {Tools::Bash} do
      def initialize(cwd: Dir.pwd, timeout: DEFAULT_TIMEOUT, poll: Poll.new,
                     shell_out_factory: Mixlib::ShellOut.public_method(:new))
        @cwd = cwd.to_s
        @timeout = timeout
        @poll = poll
        @shell_out_factory = shell_out_factory
        freeze
      end

      # @return [Answer] `value` is the new pull request's number
      def pr_create(base:, head:, title:, body:)
        argv = ["pr", "create", "--base", base.to_s, "--head", head.to_s,
                "--title", title.to_s, "--body", body.to_s]
        invoke(argv, on_refusal: method(:already_open)) { |shell| created(argv, shell) }
      end

      # @return [Answer] `value` is the number merged
      def pr_merge(number:, auto: false)
        argv = ["pr", "merge", number.to_s, MERGE_METHOD, *(auto ? ["--auto"] : [])]
        invoke(argv) { |_shell| Answer.new(ok: true, detail: { "value" => number, "argv" => argv }) }
      end

      # @return [Answer] `value` is every OPEN pull request from `head`
      #
      # `--state open`, and the narrowing is a decision rather than a default.
      # The one caller is {Reconcile::World#pr_for}, whose duck is documented as
      # "the PR **opened** from that head ref", and both of ITS callers ask the
      # same question: is there a live pull request here, so that opening
      # another would be a duplicate. `--state all` answered that question with
      # a pull request a human deliberately CLOSED -- a resumed landing then
      # read the close as "pr_create already completed", skipped the step, and
      # went on to merge a pull request somebody had shut. That is false
      # idempotency, which is the failure this whole tier exists to prevent.
      #
      # Nothing loses the merged case: `merged?` asks {#pr_view} through
      # `pr_state(number)`, which reads every state, so the fold never needs
      # this verb to see a merged pull request. What DOES narrow is the window
      # where an unsettled pr_create's pull request was already merged by
      # something outside this serial protocol -- it now reads as needing a
      # retry, and `gh pr create` from a head with no commits ahead of base
      # refuses loudly. A refusal is the right end for that.
      def pr_list(head:)
        argv = ["pr", "list", "--head", head.to_s, "--state", "open", "--json", "number"]
        invoke(argv) { |shell| parsed(argv, shell) }
      end

      # @param fields [Array<String, Symbol>] gh `--json` field names
      # @return [Answer] `value` is the parsed document
      def pr_view(ref:, fields:)
        names = Array(fields).map(&:to_s)
        raise ArgumentError, "pr_view needs at least one --json field, got #{fields.inspect}" if names.empty?

        argv = ["pr", "view", ref.to_s, "--json", names.join(",")]
        invoke(argv) { |shell| parsed(argv, shell) }
      end

      # @return [Answer] `value` is GitHub's own state string, {UNKNOWN}
      #   included when the bound runs out -- the honest answer, since nothing
      #   here can tell a slow computation from a stuck one.
      def merge_state(number:)
        @poll.take(settled: method(:computed?)) { current_merge_state(number) }
      end

      private

      # The one place a subprocess happens. A zero exit yields to the verb's own
      # reading; anything else takes the refusal path, which a verb may override
      # when it can read more out of the failure than "it failed".
      def invoke(argv, on_refusal: method(:refusal))
        shell = @shell_out_factory.call("gh", *argv, cwd: @cwd, timeout: @timeout)
        shell.run_command
        shell.exitstatus.zero? ? yield(shell) : on_refusal.call(argv, shell)
      rescue Mixlib::ShellOut::CommandTimeout => e
        failure(argv, "timeout", e.message)
      end

      # gh answers the new pull request's URL on stdout, so the number is the
      # URL's last segment. Output with no number in it is a gh whose shape this
      # executor does not know, and it is NAMED rather than passed along as a
      # success carrying nil.
      def created(argv, shell)
        number = number_in(shell.stdout)
        if number.nil?
          return failure(argv, "unreadable", "gh answered #{shell.stdout.strip.inspect}, " \
                                             "which carries no pull request number")
        end

        Answer.new(ok: true, detail: { "value" => number, "url" => shell.stdout.strip, "argv" => argv })
      end

      # gh refuses a second pull request for a head ref that already has one, and
      # names the existing one when it does. That refusal is the world reporting
      # the effect ALREADY IN PLACE, which is an observed success rather than a
      # failure -- so a resumed landing carries on instead of retrying a push
      # that already landed.
      #
      # Narrow on purpose: it fires only when the message BOTH says the pull
      # request exists and carries a number to recover. gh's wording is not a
      # documented interface, so anything else falls through to the ordinary
      # refusal and a caller that needs certainty asks the world
      # ({Reconcile}'s `pr_for(head:)`), which is the doctrine anyway.
      def already_open(argv, shell)
        number = number_in(shell.stderr)
        return refusal(argv, shell) if number.nil? || !shell.stderr.match?(ALREADY_EXISTS)

        Answer.new(ok: true, observed: true,
                   detail: { "value" => number, "argv" => argv, "stderr" => shell.stderr.strip })
      end

      def number_in(text) = text.to_s[PR_NUMBER, 1]&.to_i

      def parsed(argv, shell)
        Answer.new(ok: true, detail: { "value" => JSON.parse(shell.stdout), "argv" => argv })
      rescue JSON::ParserError => e
        failure(argv, "unparseable", "gh answered a document this executor cannot read: #{e.message}")
      end

      def refusal(argv, shell)
        Answer.new(ok: false, detail: { "reason" => "refused", "argv" => argv, "exit_status" => shell.exitstatus,
                                        "stdout" => shell.stdout.to_s.strip, "stderr" => shell.stderr.to_s.strip })
      end

      # A failure this executor reached on its own, rather than one gh reported.
      # `reason` is the machine-readable class and `message` the prose; `stderr`
      # stays reserved for bytes gh actually wrote, so a reader never mistakes
      # our own diagnosis for the remote's.
      def failure(argv, reason, message)
        Answer.new(ok: false, detail: { "reason" => reason, "argv" => argv, "message" => message.to_s })
      end

      # Anything that is not GitHub still thinking settles the poll -- a real
      # state, and equally a FAILURE, which carries no value at all: asking a
      # failing gh four more times is four more failures, and the caller needs
      # the first one.
      def computed?(answer) = answer.value != UNKNOWN

      def current_merge_state(number)
        answer = pr_view(ref: number.to_s, fields: [MERGE_STATE_FIELD])
        answer.ok? ? state_in(answer, number) : answer
      end

      def state_in(answer, number)
        document = answer.value
        state = document.is_a?(Hash) ? document[MERGE_STATE_FIELD] : nil
        return missing_field(number, document) if state.nil?

        Answer.new(ok: true, detail: { "value" => state, "number" => number })
      end

      # A document with no readable state must be DIAGNOSABLE. Compared against
      # nil it would read as a state that is not {UNKNOWN}, so the poll would
      # settle instantly and a landing would proceed on a mergeability nobody
      # ever established.
      #
      # The message names the FIELD and the document actually received, and
      # blames nothing. `mergeStateStatus` has been a `--json` field for many gh
      # majors, so on any plausible install the likelier causes are a token whose
      # scopes do not reach mergeability, or a document that answered some other
      # query -- and an operator sent to upgrade gh gets nowhere. The document is
      # what tells them apart.
      def missing_field(number, document)
        failure(["pr", "view", number.to_s], "missing_field",
                "gh answered no readable #{MERGE_STATE_FIELD} for pull request #{number} -- got " \
                "#{document.inspect}")
      end
    end
  end
end

# This file is the gh/ subtree's index. Recorded nests inside the class above and
# names its Answer, so it loads AFTER the class body -- {Isolation::Worktree}'s
# Handback placement, same reason.
require_relative "gh/recorded"
