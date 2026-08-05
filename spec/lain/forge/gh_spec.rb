# frozen_string_literal: true

require "mixlib/shellout"

# Forge::Gh is the tier's one door out to GitHub, and the whole of its design is
# that the door is narrow: four verbs, each spelling its own argv array, none of
# them able to accept a command string. The parity group pins the contract it
# shares with the replaying executor; everything below pins what is true only of
# the live one -- the exact argv on the wire, the structured reading of gh's
# output, and the bounded UNKNOWN poll.
#
# No example here touches the network. Every one runs against an injected
# shell_out_factory.
RSpec.describe Lain::Forge::Gh do
  subject(:gh) { described_class.new(shell_out_factory: factory, cwd: "/tmp/checkout") }

  let(:factory) { GhParity.factory }

  it_behaves_like "a gh executor" do
    let(:executor) { gh }
  end

  # A shell whose stdout/stderr/exit are dictated per example.
  def gh_answering(exitstatus: 0, stdout: "", stderr: "")
    described_class.new(shell_out_factory: GhParity::FakeGh.new do
      GhParity::FakeGhShellOut.new(exitstatus, stdout, stderr)
    end)
  end

  describe "the wire" do
    it "spells pr_create as an argv array, never a shell string" do
      gh.pr_create(base: "main", head: "epic/demo/a1", title: "t", body: "b")

      expect(factory.argvs.last).to eq(["gh", "pr", "create", "--base", "main", "--head", "epic/demo/a1",
                                        "--title", "t", "--body", "b"])
    end

    it "spells pr_merge with an explicit merge method and no --auto by default" do
      gh.pr_merge(number: 7)

      expect(factory.argvs.last).to eq(["gh", "pr", "merge", "7", "--merge"])
    end

    it "adds --auto only when asked" do
      gh.pr_merge(number: 7, auto: true)

      expect(factory.argvs.last).to eq(["gh", "pr", "merge", "7", "--merge", "--auto"])
    end

    it "spells pr_view's fields as one comma-joined --json argument" do
      gh.pr_view(ref: "7", fields: %i[number url])

      expect(factory.argvs.last).to eq(["gh", "pr", "view", "7", "--json", "number,url"])
    end

    # `--state open`, not `all`: the only caller asks "is there a live pull
    # request from this head", and a pull request a human CLOSED answering yes
    # made a resumed landing skip its pr_create and go on to merge something
    # somebody had shut. See the verb's own comment for why the merged case
    # loses nothing.
    it "lists only the OPEN pull requests for a head ref" do
      gh.pr_list(head: "epic/demo/a1")

      expect(factory.argvs.last).to eq(["gh", "pr", "list", "--head", "epic/demo/a1", "--state", "open",
                                        "--json", "number"])
    end

    # `gh api` with the endpoint's owner and repo left as gh's own placeholders,
    # so the repository still comes from the cwd exactly as it does for the four
    # verbs above -- and the payload on STDIN, where no amount of quoting is
    # involved. A review body is a human's prose; on an argv it would be one
    # more string somebody eventually builds.
    it "spells submit_review as a gh api POST against the cwd's repository" do
      gh.submit_review(number: 7, review: { "body" => "b" })

      expect(factory.argvs.last).to eq(["gh", "api", "--method", "POST",
                                        "repos/{owner}/{repo}/pulls/7/reviews", "--input", "-"])
    end

    it "sends the payload as canonical JSON on stdin, with keys in sorted order" do
      gh.submit_review(number: 7, review: { body: "b", commit_id: "abc", event: "COMMENT" })

      expect(factory.options.last[:input]).to eq(%({"body":"b","commit_id":"abc","event":"COMMENT"}))
    end

    # The ONE caller value in this file that reaches a URL path rather than its
    # own argv element. `Integer()` alone would stop the traversal below, but two
    # of its coercions are silent reinterpretations of a pull request number, and
    # a review posted to the wrong pull request cannot be taken back.
    describe "the pull request number, which is interpolated into the API path" do
      it "refuses a number carrying a path traversal, before any subprocess" do
        expect { gh.submit_review(number: "7/../../secret", review: {}) }
          .to raise_error(ArgumentError, /submit_review needs a pull request number/)
        expect(factory.argvs).to be_empty
      end

      it "refuses a hex spelling rather than silently addressing pull request 16" do
        expect { gh.submit_review(number: "0x10", review: {}) }.to raise_error(ArgumentError, /0x10/)
      end

      it "refuses a float rather than silently truncating it" do
        expect { gh.submit_review(number: 7.9, review: {}) }.to raise_error(ArgumentError, /7\.9/)
      end

      # `^`/`$` match at a NEWLINE, so a `^\d+$` guard would accept this and hand
      # it on to Integer(), which raises its own message about its own name. Only
      # THIS class's wording proves the guard is what refused it.
      it "refuses a number with a newline in it, which an unanchored match would pass" do
        expect { gh.submit_review(number: "7\n../../secret", review: {}) }
          .to raise_error(ArgumentError, /submit_review needs a pull request number/)
      end

      it "names the verb, where Kernel#Integer's own message names neither gh nor it" do
        expect { gh.submit_review(number: "later", review: {}) }
          .to raise_error(ArgumentError, /submit_review/)
      end

      it "takes a number the caller spelled as a String" do
        gh.submit_review(number: "7", review: { "body" => "b" })

        expect(factory.argvs.last).to include("repos/{owner}/{repo}/pulls/7/reviews")
      end
    end

    # The four verbs that have nothing to send must not acquire a stdin pipe
    # because a fifth one does: `input:` opens one, writes and closes it, and a
    # subprocess whose stdin behaviour changed is not the subprocess these
    # examples were written against.
    it "opens no stdin pipe for a verb with no body to send" do
      gh.pr_merge(number: 7)

      expect(factory.options.last).not_to have_key(:input)
    end

    it "runs every verb in the injected cwd, under a bound" do
      gh.pr_merge(number: 7)

      expect(factory.options.last).to include(cwd: "/tmp/checkout")
      expect(factory.options.last[:timeout]).to be_a(Numeric)
    end

    it "refuses a pr_view with no fields, which gh itself cannot answer" do
      expect { gh.pr_view(ref: "7", fields: []) }.to raise_error(ArgumentError, /at least one/)
    end
  end

  describe "reading what gh answered" do
    it "recovers the pull request number from the URL gh prints" do
      answer = gh_answering(stdout: "https://github.com/acme/widgets/pull/91\n")
               .pr_create(base: "main", head: "h", title: "t", body: "b")

      expect(answer).to be_ok
      expect(answer.value).to eq(91)
    end

    it "answers a structured value when gh prints something with no number in it" do
      answer = gh_answering(stdout: "Creating pull request...\n")
               .pr_create(base: "main", head: "h", title: "t", body: "b")

      expect(answer).not_to be_ok
      expect(answer.detail["reason"]).to eq("unreadable")
    end

    it "returns every matching pull request as a structured value" do
      answer = gh_answering(stdout: %([{"number":91}])).pr_list(head: "epic/demo/a1")

      expect(answer).to be_ok
      expect(answer.value).to eq([{ "number" => 91 }])
    end

    it "answers a structured value on a document it cannot parse, never a JSON::ParserError" do
      answer = gh_answering(stdout: "not json at all").pr_view(ref: "7", fields: %w[number])

      expect(answer).not_to be_ok
      expect(answer.detail["reason"]).to eq("unparseable")
    end

    it "carries the exit status and stderr of a nonzero gh" do
      answer = gh_answering(exitstatus: 2, stderr: "GraphQL: Resource not accessible\n")
               .pr_view(ref: "7", fields: %w[number])

      expect(answer).not_to be_ok
      expect(answer.detail).to include("exit_status" => 2, "reason" => "refused")
      expect(answer.detail["stderr"]).to include("Resource not accessible")
    end

    it "answers a structured value rather than leaking mixlib's timeout" do
      slow = described_class.new(shell_out_factory: GhParity::FakeGh.new do
        raise Mixlib::ShellOut::CommandTimeout, "command timed out after 60s"
      end)

      answer = slow.pr_merge(number: 7)

      expect(answer).not_to be_ok
      expect(answer.detail["reason"]).to eq("timeout")
    end
  end

  # gh refuses a second pull request for a head ref that already has one and
  # names the existing one. That refusal is the world reporting the effect
  # ALREADY IN PLACE, which is an observed success -- never a force, never a
  # locally remembered "we did this already".
  describe "a pull request that already exists" do
    it "reads gh's refusal as an observed success carrying the existing number" do
      stderr = "a pull request for branch \"epic/demo/a1\" into branch \"main\" already exists: " \
               "https://github.com/acme/widgets/pull/55"
      answer = gh_answering(exitstatus: 1, stderr:).pr_create(base: "main", head: "epic/demo/a1", title: "t", body: "b")

      expect(answer).to be_ok
      expect(answer).to be_observed
      expect(answer.value).to eq(55)
    end

    it "falls through to an ordinary refusal when the message carries no number" do
      answer = gh_answering(exitstatus: 1, stderr: "a pull request already exists")
               .pr_create(base: "main", head: "h", title: "t", body: "b")

      expect(answer).not_to be_ok
      expect(answer).not_to be_observed
    end
  end

  describe "the bounded UNKNOWN merge-state poll" do
    # GitHub computes mergeability lazily, and the query is what SCHEDULES the
    # computation -- so the first answer is routinely UNKNOWN and the fix is to
    # ask again, not to treat it as a verdict.
    def gh_polling(states, sleeps)
      replies = states.map { |state| GhParity::FakeGhShellOut.new(0, %({"mergeStateStatus":"#{state}"}), "") }
      final = replies.last
      poll = described_class::Poll.new(bound: 3, interval: 7, sleeper: ->(seconds) { sleeps << seconds })
      described_class.new(poll:, shell_out_factory: GhParity::FakeGh.new { replies.shift || final })
    end

    it "answers CLEAN after three polls when gh says UNKNOWN twice first" do
      sleeps = []
      answer = gh_polling(%w[UNKNOWN UNKNOWN CLEAN], sleeps).merge_state(number: 7)

      expect(answer).to be_ok
      expect(answer.value).to eq("CLEAN")
      expect(sleeps).to eq([7, 7])
    end

    it "answers UNKNOWN once the bound runs out, without raising" do
      sleeps = []
      answer = gh_polling(%w[UNKNOWN UNKNOWN UNKNOWN], sleeps).merge_state(number: 7)

      expect(answer).to be_ok
      expect(answer.value).to eq("UNKNOWN")
      expect(sleeps.size).to eq(2)
    end

    it "stops at the first settled state, asking gh no more than it must" do
      sleeps = []
      polling = gh_polling(%w[DIRTY UNKNOWN CLEAN], sleeps)

      expect(polling.merge_state(number: 7).value).to eq("DIRTY")
      expect(sleeps).to be_empty
    end

    it "stops polling when gh itself fails" do
      sleeps = []
      failing = described_class.new(
        poll: described_class::Poll.new(bound: 3, interval: 1, sleeper: ->(seconds) { sleeps << seconds }),
        shell_out_factory: GhParity::FakeGh.new { GhParity::FakeGhShellOut.new(1, "", "boom") }
      )

      expect(failing.merge_state(number: 7)).not_to be_ok
      expect(sleeps).to be_empty
    end

    # The escalation trigger this card names: an installed gh too old to answer
    # the field must be diagnosable, not a nil compared against "CLEAN".
    it "names the missing field when gh answers a document without mergeStateStatus" do
      answer = gh_answering(stdout: %({"number":7})).merge_state(number: 7)

      expect(answer).not_to be_ok
      expect(answer.detail["reason"]).to eq("missing_field")
      expect(answer.detail["message"]).to include("mergeStateStatus")
    end
  end
end
