# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "mixlib/shellout"
require "tmpdir"

# One repository carrying BOTH readings of a bare number: a `feature` branch to
# review as a branch, and the same commits published at `refs/pull/4821/head`
# so the pull request source finds them in the object database. The two
# readings answer the SAME changeset on purpose -- which is what stops an
# example from telling them apart by their rendering, and forces it to look at
# what the command actually did (which gh call it made, what it journaled).
#
# Built once per process and copied after that: {SeedRepo}'s reasoning at the
# scale of a whole changeset.
module ReviewCliFixture
  # The pull request number, and so the `refs/pull/N/head` the source reads.
  # The card's own example, so the ambiguity rule is checked at the spelling it
  # is written against.
  NUMBER = 4821

  # The same scrub the subjects use, so building the template is hermetic under
  # an ambient GIT_*-polluted env (a pre-commit hook sets one) exactly as they
  # are.
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  class << self
    # Process-wide, and safe without a lock for the reason the whole suite is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    #
    # @return [String] a directory to copy, never to mutate
    def template = @template ||= build # rubocop:disable ThreadSafety/ClassInstanceVariable

    private

    def build
      dir = Dir.mktmpdir("lain-review-cli-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      FileUtils.cp_r("#{SeedRepo.at("a.rb" => "a\nb\nc\n")}/.", dir)
      # `main` by NAME: the command's default base is the branch a landing
      # targets, and `git init`'s default branch name is the developer's own.
      git(dir, "branch", "-M", "main")
      git(dir, "checkout", "-q", "-b", "feature")
      commit(dir, "first: touch a", "a.rb" => "a\nCHANGED\nc\n")
      commit(dir, "second: add b", "b.rb" => "new\n")
      # What GitHub serves for a pull request. Written into the template rather
      # than fetched per example, so the pull request path is prefetched and
      # answers from the object database without a network anywhere near it.
      git(dir, "update-ref", "refs/pull/#{NUMBER}/head", "feature")
      # LEFT on `feature`, deliberately: with `main` checked out, HEAD and main
      # are the same commit, and every example about the default base passes
      # just as well against a default of "HEAD". A mutant proving exactly that
      # is what put this line here.
      dir
    end

    def commit(dir, message, files)
      files.each { |path, body| File.write(File.join(dir, path), body) }
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", message)
    end

    def git(dir, *)
      Mixlib::ShellOut.new("git", "-C", dir, *, environment: SCRUB).run_command.error!
    end
  end
end

# git is real throughout -- it is the subject's own object database and the
# oracle for every assertion here -- and `gh` is the ONE thing faked, because
# the alternative is a network call. The seam is the injected
# `shell_out_factory` every git-driving object in this tree already takes.
RSpec.describe Lain::CLI::Review, :seam do
  let(:calls) { [] }

  around do |example|
    Dir.mktmpdir("lain-review-cli") do |root|
      @root = File.realpath(root)
      @repo = File.join(@root, "repo")
      FileUtils.cp_r(ReviewCliFixture.template, @repo)
      @state = File.join(@root, "state")
      example.run
    end
  end

  def number = ReviewCliFixture::NUMBER

  def git_in(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: ReviewCliFixture::SCRUB)
                    .run_command.tap(&:error!).stdout
  end

  def run_git(*) = git_in(@repo, *)

  def oid(ref) = git_in(refs_repo, "rev-parse", ref).strip

  # A blob whose address begins with the pull request number, in the object
  # database. `SHA1("blob <n>\0<body>")` is git's own recipe, so a counter finds
  # a 4-hex-digit prefix in ~65k tries -- under a tenth of a second here.
  def object_whose_sha_starts_with_the_number
    body = (1..).lazy.map { |n| "#{n}\n" }.find do |candidate|
      Digest::SHA1.hexdigest("blob #{candidate.bytesize}\0#{candidate}").start_with?(number.to_s)
    end
    path = File.join(@root, "loose-blob")
    File.write(path, body)
    run_git("hash-object", "-w", path).strip
  end

  # Where the pull request's refs live, which is the repository under review
  # unless an example moved the head out of it.
  def refs_repo = @refs_repo || @repo

  # gh's stdout for `pr view --json`, in GitHub's own field names.
  def view_document
    { "baseRefName" => "main", "baseRefOid" => oid("main"), "headRefOid" => oid("feature") }
  end

  # The three messages a source reads off a shell out, plus the one it sends.
  def answered(stdout: "", stderr: "", exitstatus: 0)
    Data.define(:stdout, :stderr, :exitstatus) { def run_command = self }
        .new(stdout:, stderr:, exitstatus:)
  end

  # `pr diff` has no default: an example that has not arranged one is an example
  # that expects it never to be asked, so an unexpected call fails loudly rather
  # than answering ok.
  def gh_reply(argv)
    return answered(stdout: JSON.generate(view_document)) if argv[1..2] == %w[pr view]
    return @pr_diff if argv[1..2] == %w[pr diff] && @pr_diff

    raise "the fake gh was asked for #{argv.inspect}, which this example did not arrange"
  end

  def factory
    lambda do |*argv, **options|
      calls << argv
      argv.first == "gh" ? gh_reply(argv) : Mixlib::ShellOut.new(*argv, **options)
    end
  end

  # XDG injected rather than exported: the round journals a `changeset_opened`,
  # and it must land in a directory this example owns.
  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state })

  def command(**overrides)
    described_class.new(repo_root: @repo, paths:, shell_out_factory: factory, **overrides)
  end

  def gh_calls = calls.select { |argv| argv.first == "gh" }

  # What the round left in the experiment record. `source` is the field that
  # names WHICH source produced the changeset, so it is how an example reads
  # the resolution back without asking the command what it built.
  def opened_records
    lines = Dir.glob(File.join(@state, "**", "*.ndjson")).flat_map { |file| File.readlines(file) }
    Lain::Journal.records(lines, type: Lain::Review::ChangesetOpened::JOURNAL_TYPE).to_a
  end

  def sources_journaled = opened_records.map { |record| record["source"] }

  describe "resolving what the target names" do
    it "reads a bare number as a pull request, asking gh which one and journaling that source" do
      command.present(number.to_s)

      expect(gh_calls.first.take(3)).to eq(%w[gh pr view])
      expect(sources_journaled).to eq(["github_pr"])
    end

    it "reads a branch name as a local branch, spawning no gh at all" do
      command.present("feature")

      expect(gh_calls).to be_empty
      expect(sources_journaled).to eq(["local_branch"])
    end

    it "reads a pull request URL as a pull request too, not as a branch of that name" do
      command.present("https://github.com/owner/repo/pull/#{number}")

      expect(gh_calls.first.take(3)).to eq(%w[gh pr view])
      expect(sources_journaled).to eq(["github_pr"])
    end

    it "refuses a target that resolves to neither, as a Lain::Error naming the target" do
      expect { command.present("no/such/branch") }
        .to raise_error(Lain::Error, %r{no/such/branch})
    end

    it "refuses a bare number that ALSO names a branch, naming both readings and a spelling for each" do
      run_git("branch", number.to_s, "feature")

      expect { command.present(number.to_s) }
        .to raise_error(described_class::Ambiguous,
                        %r{refs/heads/#{number}.*/pull/#{number}}m)
    end

    # The probe asks `refs/heads/`, never the bare name, and these two are what
    # say so. A TAG of that name resolves to a commit and is not a branch; an
    # OBJECT whose sha begins with those digits resolves too, and is not even a
    # ref. A bare `rev-parse --verify 4821` accepts both, so it would call an
    # ordinary pull request ambiguous.
    #
    # The second case was written off in the first cut as needing a brute-forced
    # sha. It needs about a tenth of a second: a blob's address is
    # `SHA1("blob <n>\0<body>")`, so a counter and `git hash-object -w` arrange
    # it exactly. A claim that something is impossible closes a question that is
    # still open, so it is arranged rather than argued about.
    it "reads a bare number as a pull request even when a TAG carries that name" do
      run_git("tag", number.to_s, "feature")

      command.present(number.to_s)

      expect(sources_journaled).to eq(["github_pr"])
    end

    it "reads a bare number as a pull request even when an OBJECT's sha begins with it" do
      sha = object_whose_sha_starts_with_the_number
      # The premise, stated: the bare name really does resolve here, so the
      # example is about the `refs/heads/` prefix and nothing else.
      expect(run_git("rev-parse", "--verify", "--quiet", number.to_s).strip).to eq(sha)

      command.present(number.to_s)

      expect(sources_journaled).to eq(["github_pr"])
    end

    # Thor reserves `help` and `tree` as command names, so `lain review help`
    # prints the help screen -- the exe's `desc` says so, and `lain review open
    # help` is the way through. The LIB has no such reservation, and this is
    # what holds the two apart: nothing here treats a target as a command name.
    it "reviews a branch that happens to be named like a Thor command" do
      run_git("branch", "help", "feature")

      expect(command.present("help")).to include("branch help", "[ ] a.rb")
    end

    it "journals nothing for a target it refused, so a refusal opens no round" do
      run_git("branch", number.to_s, "feature")

      expect { command.present(number.to_s) }.to raise_error(described_class::Ambiguous)
      expect(opened_records).to be_empty
    end
  end

  describe "what it hands back" do
    it "answers a String and writes nothing to stdout" do
      rendered = nil

      expect { rendered = command.present("feature") }.not_to output.to_stdout
      expect(rendered).to be_a(String)
      expect(rendered).to include("[ ] a.rb", "[ ] b.rb")
    end

    # Its own example rather than a second matcher on the one above: each
    # `expect {}.not_to output` runs the block, so one example asserting both
    # would open two rounds and name only one of them if it failed.
    it "writes nothing to stderr either" do
      expect { command.present("feature") }.not_to output.to_stderr
    end

    it "names what is under review, at which scope, between which two revisions" do
      expect(command.present("feature"))
        .to include("branch feature", "cumulative", "#{oid("main")}..#{oid("feature")}")
    end
  end

  describe "the scope the flag picks" do
    it "presents the commit walk when the scope is commits" do
      rendered = command.present("feature", scope: "commits")

      expect(rendered).to include("first: touch a", "second: add b")
    end

    it "presents one flat table by default, naming no commit" do
      rendered = command.present("feature")

      expect(rendered).to include("[ ] a.rb")
      expect(rendered).not_to include("first: touch a")
    end

    it "refuses a scope the vocabulary does not declare, naming what it was given" do
      expect { command.present("feature", scope: "cumulatve") }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end
  end

  describe "the base a branch is reviewed against" do
    it "defaults to the branch a landing targets, not to whatever happens to be checked out" do
      # The fixture's premise, stated rather than assumed: with HEAD standing on
      # main this example would pass against a default of "HEAD" too, which is
      # how it read before a mutant said so.
      expect(oid("HEAD")).not_to eq(oid("main"))

      rendered = command.present("feature")

      expect(rendered).to include("#{oid("main")}..")
      expect(rendered).to include("[ ] a.rb", "[ ] b.rb")
    end

    it "reviews against the ref --base names instead, when it is given one" do
      rendered = command.present("feature", base: oid("feature~1"))

      expect(rendered).to include("[ ] b.rb")
      expect(rendered).not_to include("a.rb")
    end

    it "refuses --base against a pull request, because GitHub names that base itself" do
      expect { command.present(number.to_s, base: "main") }
        .to raise_error(described_class::BaseNotOverridable, /#{number}/)
    end
  end

  # The guard T29 shipped and nothing called. Its ceilings are constructor
  # arguments precisely so a refusal can be driven without building the 800-file
  # changeset it was written against.
  describe "the size past which it refuses to present" do
    def bounded(**ceilings) = command(bounds: Lain::Review::Bounds.new(**ceilings))

    it "refuses a cumulative view past the file ceiling, naming the count, the ceiling and the walk" do
      expect { bounded(max_files: 1).present("feature") }
        .to raise_error(Lain::Review::Bounds::TooLarge, /2 files.*ceiling of 1.*scope: commits/m)
    end

    it "does not offer the commit walk when the walk would refuse as well" do
      expect { bounded(max_files: 0).present("feature") }
        .to raise_error(Lain::Review::Bounds::TooLarge, /no scope that presents this changeset whole/)
    end

    it "guards the commit walk itself when that is the scope asked for" do
      expect { bounded(max_files: 0).present("feature", scope: "commits") }
        .to raise_error(Lain::Review::Bounds::TooLarge, /commit [0-9a-f]{40}.*narrowest scope/m)
    end

    it "refuses BEFORE the round is opened, so a view nobody can read leaves no record of one" do
      expect { bounded(max_files: 1).present("feature") }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(opened_records).to be_empty
    end
  end

  describe "the surface it presents through" do
    # Six messages at the port's own shapes, because `Surface.check!` refuses
    # anything else -- including a `Forwardable`/`SimpleDelegator` adapter.
    def refusing_surface(refusal)
      Class.new do
        define_method(:present) { |_changeset, scope:| "#{refusal} (#{scope})" }
        def annotate(_anchor, _text, kind:) = kind
        def mark(_hunk_key, _state) = nil
        def thread(_anchor) = nil
        def verdict = nil
        def refuse(message) = message
      end.new
    end

    it "hands an injected surface's own refusal back rather than a rendering of its own" do
      rendered = command(surface: refusing_surface("the editor is detached")).present("feature")

      expect(rendered).to include("the editor is detached (cumulative)")
    end

    it "still names the review above an injected surface's refusal" do
      rendered = command(surface: refusing_surface("detached")).present("feature")

      expect(rendered).to include("branch feature")
    end

    it "refuses a surface that does not answer the port, before anything is journaled" do
      expect { command(surface: Object.new).present("feature") }
        .to raise_error(Lain::Review::Surface::Incomplete, /present/)
      expect(opened_records).to be_empty
    end
  end

  # {Source::GithubPr}'s own requirement -- a fallback must be REPORTED rather
  # than silent -- discharged at the first surface with a human in front of it.
  describe "a combined diff GitHub would not serve" do
    # A repository that has never seen the pull request, so the API is asked
    # first and its refusal is what forces the fetch. `init` and a remote, never
    # a `clone`: a local-path clone HARDLINKS the whole object directory and
    # would silently have the head already.
    def repo_without_the_head
      @refs_repo = @repo
      @repo = File.join(@root, "local")
      Mixlib::ShellOut.new("git", "init", "-q", @repo, environment: ReviewCliFixture::SCRUB)
                      .run_command.error!
      run_git("remote", "add", "origin", @refs_repo)
    end

    it "says the diff came from the object database instead, in gh's own words" do
      repo_without_the_head
      @pr_diff = answered(exitstatus: 1,
                          stderr: "could not find pull request diff: HTTP 406: Sorry, the diff " \
                                  "exceeded the maximum number of files (300)")

      rendered = command.present(number.to_s)

      expect(rendered).to include("too_large", "object database")
      expect(rendered).to include("[ ] a.rb", "[ ] b.rb")
    end

    # The OTHER leg, and it is here because a panel mutant that always reported
    # SURVIVED without it: the guard was tested on one side only, so an ordinary
    # pull request rendered this note with an empty reason and nothing failed.
    # Both sources get an example, because both answer the port's fifth message
    # and only one of them can ever have fallen back.
    it "says nothing about a fallback for a pull request the object database already answered" do
      rendered = command.present(number.to_s)

      expect(rendered).not_to include("note:")
      expect(rendered).not_to include("object database")
    end

    it "says nothing about a fallback for a branch, which asks no API at all" do
      rendered = command.present("feature")

      expect(rendered).not_to include("note:")
      expect(rendered).not_to include("object database")
    end
  end
end
