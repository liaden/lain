# frozen_string_literal: true

require "fileutils"
require "json"
require "mixlib/shellout"
require "tmpdir"

# A pull request to review, built ONCE per process and copied after that --
# {SeedRepo}'s reasoning at the scale of a whole changeset, and for a sharper
# reason: this fixture is ~14 git spawns, measured at 96ms against 2.4ms to
# copy it, and the port contract alone runs it 19 times.
#
# A copy IS the repository rather than a reconstruction of one (see SeedRepo),
# and the shas are therefore identical across copies -- which is what lets the
# examples read oids out of their own copy and still describe the same
# changeset.
#
# Two shapes, because the port contract's factory owes a rich changeset and
# nothing else does: `rich` adds a binary file, a non-ASCII path and a merge
# carrying its own resolved file.
module GithubPrFixture
  # The pull request number, and so the `refs/pull/N/head` the source fetches.
  NUMBER = 42

  # The same scrub the subject uses, so building the template is hermetic under
  # an ambient GIT_*-polluted env exactly as it is.
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  class << self
    # @param rich [Boolean] include the binary, unicode and merge shapes
    # @return [String] a directory to copy, never to mutate
    def at(rich:) = templates[rich] ||= build(rich)

    private

    # Process-wide, and safe without a lock for the reason the whole suite is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    def templates = @templates ||= {} # rubocop:disable ThreadSafety/ClassInstanceVariable

    def build(rich)
      dir = Dir.mktmpdir("lain-review-github-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      FileUtils.cp_r("#{SeedRepo.at("shared.rb" => "a\nb\nc\n")}/.", dir)
      diverge(dir)
      enrich(dir) if rich
      publish(dir)
      dir
    end

    # base and feature both advance after the fork, so the merge base is neither
    # tip. `shared.rb` is touched TWICE and `added.rb` is a pure addition,
    # because the port contract's factory owes both: an all-symmetric changeset
    # reads the same reversed, and a per-file `>=` over a file only one commit
    # touched compares a number to itself.
    def diverge(dir)
      git(dir, "checkout", "-q", "-b", "base")
      git(dir, "checkout", "-q", "-b", "feature")
      commit(dir, "feature one\n\nwith a body paragraph.", "shared.rb" => "a\nCHANGED\nc\n")
      commit(dir, "feature two", "added.rb" => "new file\n")
      commit(dir, "feature three", "shared.rb" => "a\nCHANGED\nc\nd\n")
      git(dir, "checkout", "-q", "base")
      commit(dir, "base advances independently", "base_only.rb" => "base\n")
      git(dir, "checkout", "-q", "feature")
    end

    # Each of these is a shape that made some assertion in the port contract
    # vacuous while it was absent: a binary file has no line counts, a merge
    # carries a file no parent has, and a non-ASCII path is where an encoding
    # defect shows.
    def enrich(dir)
      File.binwrite(File.join(dir, "blob.bin"), "\x00\x01\x02\xff".b)
      commit(dir, "add a binary", {})
      commit(dir, "a unicode path", "café.rb" => "unicode\n")
      git(dir, "checkout", "-q", "-b", "side", "base")
      commit(dir, "side one", "side_only.rb" => "side\n")
      git(dir, "checkout", "-q", "feature")
      git(dir, "merge", "-q", "--no-ff", "--no-commit", "side")
      commit(dir, "merge side into feature", "only_in_merge.rb" => "resolved by hand\n")
    end

    # GitHub serves a pull request's head at this ref, and it is what the source
    # fetches -- an ordinary ref, so `update-ref` writes exactly what GitHub
    # would.
    def publish(dir)
      git(dir, "update-ref", "refs/pull/#{NUMBER}/head", git(dir, "rev-parse", "feature").stdout.strip)
    end

    def commit(dir, message, files)
      files.each { |path, body| File.write(File.join(dir, path), body) }
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", message)
    end

    def git(dir, *)
      shell = Mixlib::ShellOut.new("git", "-C", dir, *, environment: SCRUB)
      shell.run_command.error!
      shell
    end
  end
end

# Two THROWAWAY repositories, never the lain repo this runs in: an `origin`
# carrying the pull request, and the local one the source reads. git is real on
# both sides -- it is the subject's own object database and the oracle for every
# diff assertion -- while `gh` is the ONE thing faked, because the alternative is
# a network call. The seam is the same injected `shell_out_factory`
# {Lain::Forge::Gh} uses, so the fake intercepts by reading argv[0] and hands
# every `git` straight through to the real thing.
RSpec.describe Lain::Review::Source::GithubPr, :seam do
  def number = GithubPrFixture::NUMBER

  def url = "https://github.com/owner/repo/pull/#{number}"

  # Only the port contract needs the rich changeset; every other example is
  # faster and more readable without it.
  let(:rich) { false }
  let(:calls) { [] }
  # What the fake gh answers, per verb. A Hash rather than a `let` per verb so
  # an example can arrange one mid-flight.
  let(:replies) { {} }

  around do |example|
    Dir.mktmpdir("lain-review-github") do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  # Hermetic for the same two reasons the subject is: the env scrub keeps an
  # ambient GIT_DIR (a pre-commit hook sets one) from redirecting these calls,
  # and the repo-local config the SeedRepo template carries keeps a developer's
  # `commit.gpgsign` out of the fixture.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def copy_of_the_template(name)
    File.join(@root, name).tap { |dir| FileUtils.cp_r(GithubPrFixture.at(rich:), dir) }
  end

  # What GitHub is serving.
  def origin = @origin ||= copy_of_the_template("origin")

  # A repository that already has the pull request's objects is an ordinary
  # developer's checkout, and a copy of the same template IS one -- a copy
  # rather than an init and a fetch, which is 2ms against 50.
  def local_repo_with_head = @repo = copy_of_the_template("local")

  # And one that has never seen it. Built by `init` plus an explicit refspec
  # rather than by `clone`, because a local-path clone HARDLINKS the whole
  # object directory and would silently have every object already.
  def local_repo_without_head
    @repo = File.join(@root, "local")
    run_git(@root, "init", "-q", @repo)
    run_git(@repo, "remote", "add", "origin", origin)
    run_git(@repo, "fetch", "-q", "--no-tags", "origin", "refs/heads/base:refs/heads/base")
  end

  def head_oid = @head_oid ||= run_git(origin, "rev-parse", "feature").strip

  def base_oid = @base_oid ||= run_git(origin, "rev-parse", "base").strip

  def merge_base = @merge_base ||= run_git(origin, "merge-base", base_oid, head_oid).strip

  # The oracle for every diff assertion, read from the repository that has all
  # the objects. Spelled with the subject's OWN pins, so an example cannot fail
  # merely because the developer set `diff.noprefix`.
  def expected_diff
    run_git(origin, *Lain::Review::Source::LocalBranch::CONFIG_PINS, "diff",
            *Lain::Review::Source::LocalBranch::DIFF_HYGIENE, merge_base, head_oid).b
  end

  # gh's stdout for `pr view --json`, in GitHub's own field names.
  def view_document = { "baseRefName" => "base", "baseRefOid" => base_oid, "headRefOid" => head_oid }

  # The three messages the subject reads off a shell out, plus the one it sends.
  # A fake answering more would be a fake the subject could come to depend on.
  def answered(stdout: "", stderr: "", exitstatus: 0)
    Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }
        .new(stdout:, stderr:, exitstatus:)
  end

  # A subprocess that could not run AT ALL, which is a different thing from one
  # that ran and said no. `run_command` is where mixlib raises either way.
  def raising(error)
    Class.new do
      define_method(:run_command) { raise error }
      def stdout = ""
      def stderr = ""
      def exitstatus = 0
    end.new
  end

  # `pr view` succeeds unless an example arranges otherwise. `pr diff` has no
  # default at all: an example that has not arranged one is an example that
  # expects it never to be called, so an unexpected call fails loudly rather
  # than answering ok.
  def gh_reply(argv)
    verb = argv[1..2]
    return replies.fetch(:view) { answered(stdout: JSON.generate(view_document)) } if verb == %w[pr view]
    return replies[:diff] if verb == %w[pr diff] && replies[:diff]

    raise "the fake gh was asked for #{argv.inspect}, which this example did not arrange"
  end

  # Every `git` runs for real; only `gh` is answered. Both argv arrays are
  # recorded, which is how "no gh subprocess is spawned for the diff" is checked
  # rather than assumed.
  def factory
    lambda do |*argv, **options|
      calls << argv
      argv.first == "gh" ? gh_reply(argv) : Mixlib::ShellOut.new(*argv, **options)
    end
  end

  def build(pull_request: number)
    described_class.new(pull_request:, repo_root: @repo, shell_out_factory: factory)
  end

  def gh_calls = calls.select { |argv| argv.first == "gh" }

  def git_calls = calls.select { |argv| argv.first == "git" }

  def fetch_call = git_calls.find { |argv| argv.include?("fetch") }

  # GitHub's own words when the combined diff is too big to serve, as gh relays
  # them: the API answers HTTP 406 with a `too_large` error and gh prefixes its
  # own sentence. Recorded verbatim rather than paraphrased -- matching it
  # loosely is what degrades into a silent truncation.
  def too_large
    "could not find pull request diff: HTTP 406: Sorry, the diff exceeded the maximum " \
      "number of files (300) (https://api.github.com/repos/owner/repo/pulls/#{number})"
  end

  describe "the pull request it was named" do
    before { local_repo_with_head }

    it "resolves a bare number" do
      expect(build(pull_request: number).head_ref).to eq(head_oid)
    end

    it "resolves the number written as a String, as a CLI hands it over" do
      expect(build(pull_request: number.to_s).head_ref).to eq(head_oid)
    end

    # Same pull request, two spellings. Nothing downstream may be able to tell
    # which one the human typed.
    it "resolves a URL and a bare number to the same changeset" do
      by_url = build(pull_request: url)
      by_number = build(pull_request: number)
      expect([by_url.base_ref, by_url.head_ref]).to eq([by_number.base_ref, by_number.head_ref])
    end

    # gh takes a number, a branch or a URL positionally, and resolves the
    # REPOSITORY from a URL, so the ref is handed over as the human wrote it.
    # Only the refspec needs the bare number.
    it "hands gh the ref verbatim rather than a rewritten one" do
      build(pull_request: url).head_ref
      expect(gh_calls.first).to include(url)
    end

    it "refuses a ref that names no pull request at all" do
      expect { build(pull_request: "main") }.to raise_error(Lain::Review::Source::UnknownRef, /"main"/)
    end

    it "names the accepted spellings when it refuses" do
      expect { build(pull_request: "not-a-pr") }.to raise_error(Lain::Review::Source::UnknownRef, %r{/pull/})
    end
  end

  describe "what gh reports about the pull request" do
    before { local_repo_with_head }

    it "reports the head oid GitHub names, resolved and frozen" do
      source = build
      expect(source.head_ref).to eq(head_oid)
      expect(source.head_ref).to be_frozen
    end

    # GitHub's `baseRefOid` is the base BRANCH's tip, which has moved on its own
    # since the fork. The reviewable old side is the merge base, and that is
    # what a source must report -- the same distinction LocalBranch exists to
    # make, reached through the same object.
    it "reports the merge base as base_ref, not the base branch's tip" do
      source = build
      expect(source.base_ref).to eq(merge_base)
      expect(source.base_ref).not_to eq(base_oid)
    end

    it "asks gh only for the fields it reads" do
      build.head_ref
      expect(gh_calls.first).to eq(["gh", "pr", "view", number.to_s, "--json",
                                    "baseRefName,baseRefOid,headRefOid"])
    end

    # A pull request that does not exist is the caller naming something that is
    # not there, which this port RAISES for -- Gh's own line, read from the
    # other side of it: gh answering "no" is data to a fold, and there is no
    # fold here.
    it "refuses loudly when gh cannot resolve the pull request" do
      replies[:view] = answered(stderr: "could not resolve to a PullRequest", exitstatus: 1)
      expect { build }.to raise_error(Lain::Review::Source::UnknownRef, /PullRequest/)
    end

    it "refuses loudly when gh answers a document it cannot read" do
      replies[:view] = answered(stdout: "not json")
      expect { build }.to raise_error(Lain::Review::Source::UnknownRef, /read/)
    end

    # A document missing the oid would otherwise flow on as an empty ref, and
    # `git rev-parse ""` fails a long way from the cause.
    it "refuses loudly when gh answers no head oid" do
      replies[:view] = answered(stdout: JSON.generate({ "baseRefName" => "base" }))
      expect { build }.to raise_error(Lain::Review::Source::UnknownRef, /headRefOid/)
    end

    it "refuses loudly when gh answers no base branch to fetch" do
      replies[:view] = answered(stdout: JSON.generate({ "baseRefOid" => base_oid, "headRefOid" => head_oid }))
      expect { build }.to raise_error(Lain::Review::Source::UnknownRef, /baseRefName/)
    end
  end

  describe "the local object database, when the head is already fetched" do
    before { local_repo_with_head }

    it "answers the diff without spawning gh for it" do
      source = build
      calls.clear
      expect(source.diff).to eq(expected_diff)
      expect(gh_calls).to be_empty
    end

    it "answers the walk without spawning gh for it" do
      source = build
      calls.clear
      expect(source.commits.map(&:subject)).to eq(["feature one", "feature two", "feature three"])
      expect(gh_calls).to be_empty
    end

    it "fetches nothing, the objects being there already" do
      build.diff
      expect(fetch_call).to be_nil
    end

    it "reports where the diff came from, so a caller can journal it" do
      origin = build.diff_origin
      expect(origin.origin).to eq("object_database")
      expect(origin).not_to be_fell_back
    end
  end

  describe "a head the local repository has never seen" do
    before { local_repo_without_head }

    it "takes GitHub's combined diff rather than fetching to answer it" do
      replies[:diff] = answered(stdout: expected_diff)
      expect(build.diff).to eq(expected_diff)
      expect(fetch_call).to be_nil
    end

    it "reports the combined diff API as the origin" do
      replies[:diff] = answered(stdout: expected_diff)
      expect(build.diff_origin.origin).to eq("combined_diff_api")
    end

    # The walk cannot come from a combined diff, so this is where the fetch has
    # to happen -- and it is `refs/pull/N/head`, the ref GitHub serves, rather
    # than a branch name a fork may not even have.
    it "fetches refs/pull/N/head when it needs the objects" do
      build.commits
      expect(fetch_call).to include("refs/pull/#{number}/head", "origin")
    end

    it "answers the same walk the objects support once fetched" do
      expect(build.commits.map(&:subject)).to eq(["feature one", "feature two", "feature three"])
    end

    # The ORDINARY reviewer path is "list the commits, then show me the diff",
    # and the walk is what fetches. Asking GitHub afterwards would be asking for
    # something this repository now holds -- and it made the same pull request
    # answer a different `diff_origin` purely by message order, which is a read
    # model that is not one.
    it "uses the objects an earlier message fetched, rather than asking GitHub again" do
      source = build
      source.commits
      calls.clear
      expect(source.diff).to eq(expected_diff)
      expect(gh_calls).to be_empty
      expect(source.diff_origin.origin).to eq("object_database")
    end

    it "answers the same origin whichever message is sent first" do
      walked = build
      walked.commits
      expect(walked.diff_origin.origin).to eq(build.diff_origin.origin)
    end

    # A force-push between gh's answer and the fetch leaves the oid GitHub named
    # unreachable, because `refs/pull/N/head` has moved on. Loud is the only
    # acceptable answer: reviewing whatever that ref points at NOW would be a
    # review of a changeset nobody asked for, reported as a success.
    it "refuses loudly when the oid gh named is not among the objects fetched" do
      replies[:view] = answered(stdout: JSON.generate(view_document.merge("headRefOid" => "#{"0" * 39}1")))
      expect { build.commits }.to raise_error(Lain::Review::Source::UnknownRef, /head ref/)
    end

    it "refuses loudly when the fetch itself fails" do
      run_git(@repo, "remote", "set-url", "origin", File.join(@root, "gone"))
      expect { build.commits }.to raise_error(Lain::Review::Source::UnknownRef, /fetching pull request 42/)
    end
  end

  # §3.7 measured a real work changeset at 810 files and GitHub stops serving a
  # combined diff at 300, so this is the ordinary path at work scale rather than
  # an edge case.
  describe "a pull request too large for the combined diff API" do
    before do
      local_repo_without_head
      replies[:diff] = answered(stderr: too_large, exitstatus: 1)
    end

    it "answers the diff from the local object database instead of failing" do
      expect(build.diff).to eq(expected_diff)
    end

    it "fetches the head to do it" do
      build.diff
      expect(fetch_call).to include("refs/pull/#{number}/head")
    end

    # Not silent. A reviewer reading a locally computed diff instead of GitHub's
    # is entitled to know, and so is the journal.
    it "reports the fallback, naming GitHub's own reason" do
      origin = build.diff_origin
      expect(origin).to be_fell_back
      expect(origin.reason).to eq("too_large")
      expect(origin.origin).to eq("object_database")
    end

    it "carries gh's own words, so a reader is not left with our paraphrase" do
      expect(build.diff_origin.message).to include("maximum number of files (300)")
    end

    it "still answers the same walk, from the same objects" do
      source = build
      expect(source.commits.map(&:subject)).to eq(["feature one", "feature two", "feature three"])
      expect(source.base_ref).to eq(merge_base)
    end
  end

  describe "a combined diff gh could not serve for some other reason" do
    before { local_repo_without_head }

    it "falls back for any refusal, since the object database can answer them all" do
      replies[:diff] = answered(stderr: "gh: Not Found (HTTP 404)", exitstatus: 1)
      source = build
      expect(source.diff).to eq(expected_diff)
      expect(source.diff_origin.reason).to eq("refused")
    end

    # The failure this guards is the one octo shipped: gh has answered an error
    # on stderr with a ZERO exit (cli/cli#10712), and an empty stdout taken at
    # face value reads as "this pull request changed nothing" -- a review of an
    # empty changeset, reported as a success. The refusal STRING names the
    # reason; it never decides whether there was one.
    it "falls back when gh writes an error and still exits zero" do
      replies[:diff] = answered(stderr: too_large, exitstatus: 0)
      source = build
      expect(source.diff).to eq(expected_diff)
      expect(source.diff_origin).to be_fell_back
    end

    it "falls back when gh answers nothing at all" do
      replies[:diff] = answered(exitstatus: 1)
      expect(build.diff).to eq(expected_diff)
    end

    it "falls back when gh does not answer within its bound" do
      replies[:diff] = raising(Mixlib::ShellOut::CommandTimeout.new("gh took too long"))
      source = build
      expect(source.diff).to eq(expected_diff)
      expect(source.diff_origin.reason).to eq("timeout")
    end

    # This value exists to be JOURNALLED, and the Journal is NDJSON, where one
    # line that will not generate breaks the parse of the experiment record.
    # stderr is bytes: gh relaying a remote's message, or a locale mangling one,
    # is enough to make them invalid UTF-8.
    it "reports a message that survives JSON generation, whatever bytes gh wrote" do
      replies[:diff] = answered(stderr: +"boom \xff", exitstatus: 1)
      origin = build.diff_origin
      expect(origin.message).to be_valid_encoding
      expect(origin.message.encoding).to eq(Encoding::UTF_8)
      expect { JSON.generate(origin.to_h) }.not_to raise_error
    end

    # The other way a message reaches the value, and it does not come from
    # stderr at all: a timeout carries the exception's own text. The scrub
    # therefore belongs to the VALUE, not only to the reading of a refusal.
    it "reports a journal-safe message when the timeout itself carries bad bytes" do
      replies[:diff] = raising(Mixlib::ShellOut::CommandTimeout.new(+"timed out \xff"))
      origin = build.diff_origin
      expect(origin.message).to be_valid_encoding
      expect { JSON.generate(origin.to_h) }.not_to raise_error
    end
  end

  # gh answering "no" is data; gh not being there is a broken machine, and this
  # port raises for those. What it must not do is hand back
  # `Errno::ENOENT - gh`, which names no cause a newcomer can act on.
  # Each example sets up its own repository, because the two gh call sites need
  # opposite ones and re-initialising the same path would leave the objects of
  # the first behind.
  describe "a machine with no gh on it" do
    it "names gh, and what it is needed for, rather than leaking ENOENT" do
      local_repo_with_head
      replies[:view] = raising(Errno::ENOENT.new("gh"))
      expect { build }.to raise_error(described_class::NoGh, /gh/)
    end

    # BESIDE the port's refusal, never beneath it. One is a fact about the pull
    # request and the other a fact about the machine, and only the second is
    # fixed by installing something -- so sharing a class would erase the
    # distinction at the one place a caller can cheaply read it, and a
    # `rescue UnknownRef` would swallow "the GitHub CLI is not here" as though
    # the pull request had been the problem. A caller wanting a single rescue
    # still has {Lain::Error}, which both descend from.
    it "stands beside the port's refusal rather than beneath it" do
      local_repo_with_head
      replies[:view] = raising(Errno::ENOENT.new("gh"))
      expect { build }.to raise_error(described_class::NoGh) { |error|
        expect(error).to be_a(Lain::Error)
        expect(error).not_to be_a(Lain::Review::Source::UnknownRef)
      }
    end

    it "names gh at the diff call too, rather than leaking ENOENT from there" do
      local_repo_without_head
      source = build
      replies[:diff] = raising(Errno::ENOENT.new("gh"))
      expect { source.diff }.to raise_error(described_class::NoGh)
    end
  end

  describe "a gh that never answers about the pull request itself" do
    before { local_repo_with_head }

    # The constructor documents UnknownRef, and a bounded call that runs out is
    # one of the ways it fails to resolve one.
    it "refuses as the port does when gh runs past its bound" do
      replies[:view] = raising(Mixlib::ShellOut::CommandTimeout.new("gh took too long"))
      expect { build }.to raise_error(Lain::Review::Source::UnknownRef, /took too long/)
    end
  end

  describe "the subprocess seam" do
    before do
      local_repo_without_head
      replies[:diff] = answered(stderr: too_large, exitstatus: 1)
    end

    it "spells gh and git as argv arrays, so nothing reaches a shell" do
      build.commits
      expect(calls).not_to be_empty
      expect(calls.map(&:first).uniq).to contain_exactly("gh", "git")
      expect(calls.flatten).not_to include("sh", "bash", "zsh", "-lc")
    end

    # Every `-c` is git's OWN config flag carrying a key=value, never a shell's
    # "run this string" -- asserting the shape beats banning the token.
    it "passes git's config pins as key=value" do
      build.diff
      values = git_calls.flat_map { |argv| argv.each_cons(2).filter_map { |flag, value| value if flag == "-c" } }
      expect(values).to all(match(/\A[\w.]+=\S*\z/))
    end
  end

  # The rich changeset, for the reasons the group's own header gives: a pure
  # addition, a file two commits touch, a merge carrying its own file, a binary,
  # and a non-ASCII path.
  #
  describe "the port contract, over the object database" do
    let(:rich) { true }

    it_behaves_like "a review changeset source", source: lambda {
      local_repo_with_head
      build
    }
  end

  # And over GitHub's bytes, which is the path whose producer nobody here has
  # observed -- so it is exactly the one that must be held to the contract
  # rather than trusted. The group's diff↔walk cross-check is what catches a
  # diff of the wrong revision range, or a truncated one, because the walk comes
  # from the object database and cannot agree with either.
  #
  # The factory asks for the diff FIRST, and that is not incidental: the walk is
  # what fetches, and once the objects are here the source rightly stops asking
  # GitHub. Memoising GitHub's answer before the walk runs is what keeps this
  # group over the API path rather than over the local one.
  describe "the port contract, over the combined diff API" do
    let(:rich) { true }

    it_behaves_like "a review changeset source", source: lambda {
      local_repo_without_head
      replies[:diff] = answered(stdout: expected_diff)
      build.tap(&:diff)
    }
  end
end
