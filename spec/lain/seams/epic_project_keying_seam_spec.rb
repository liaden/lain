# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# A session record lands in one of two directories, and every reader folds both.
#
#   * a CHAT files its journal under the resolved PROJECT ROOT
#     ({Lain::CLI::Chronicle} keys it on `project_hash(root)`), so `--root P`
#     from anywhere files the session where `lain sessions` run in P looks;
#   * the epic WRITERS (`submit`, `land`, `queue`, `finish`, the driver) keep
#     filing under the WORKING DIRECTORY, through {Lain::Paths#sessions_dir}'s
#     `project_hash(Dir.pwd)` default -- nothing was migrated;
#   * EVERY reader of a session directory folds
#     {Lain::Paths#session_dirs}: the root's directory first, then the working
#     directory's, once when they are the same. So a chat started below the
#     root and `lain epic status` run from anywhere in the tree agree on what
#     was recorded, and a session filed under the old working-directory key
#     stays visible.
#
# The epic CONTAINER -- where the documents live -- is keyed on the resolved
# PROJECT ROOT as before ({Lain::Project::Resolver.default_project}).
#
# == Why this file exists, and why it is a seam
#
# The project resolver once changed what `@root` MEANS and two readers silently
# stopped agreeing with the four that took the `sessions_dir` default: from a
# subdirectory, `lain epic submit` wrote its verdict where `lain epic status`
# would not look. THE WHOLE SUITE STAYED GREEN THROUGHOUT. Every epic spec
# injects `paths:` and `root:` together, so the keyings cannot disagree inside
# a fixture: A FIXTURE THAT SUPPLIES BOTH HALVES OF A RELATIONSHIP CANNOT TEST
# THE RELATIONSHIP. That is why nothing below injects `paths:` or a root the
# object could have resolved itself. `HOME` and `XDG_STATE_HOME` move into the
# fixture -- that is environment, not injection -- and every object is built
# the way `exe/lain` builds it.
RSpec.describe "the epic tier's project keying", :seam do
  # A real project: a `.lain/` marker for the resolver to stop on, and a
  # repo-mode epics home so the container is a path inside the project rather
  # than an XDG hash. Entered from a SUBDIRECTORY, which is the only place the
  # two axes can be told apart at all.
  def in_subdirectory_of_a_project
    Dir.mktmpdir("epic-keying") do |dir|
      base = File.realpath(dir)
      root = File.join(base, "repo")
      sub = File.join(root, "services", "ingest")
      FileUtils.mkdir_p(sub)
      with_env("HOME" => base, "XDG_STATE_HOME" => File.join(base, "state")) do
        write_repo_epic(root, "alpha")
        Dir.chdir(sub) { yield(root, sub) }
      end
    end
  end

  def write_repo_epic(root, slug)
    write_config(root, "epics home: :repo\n")
    path = File.join(root, ".lain", "epics", slug, "epic.md")
    FileUtils.mkdir_p(File.dirname(path))
    graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a1", title: "the a1 issue")])
    File.write(path, Lain::Epic::Document.to_markdown(graph))
  end

  # Every object `exe/lain` builds for an epic verb, built the way it builds
  # them: no root, no paths. {Lain::CLI::EpicQueue} takes neither and never has
  # -- on this axis that makes it consistent with the rest rather than the odd
  # one out.
  def verbs
    { "lain epic status" => Lain::CLI::Epic.new,
      "lain epic submit" => Lain::CLI::EpicSubmit.new(input: nil, output: nil),
      "lain epic land" => Lain::CLI::EpicLand.new,
      "lain epic queue" => Lain::CLI::EpicQueue.new }
  end

  # The directory each verb ACTUALLY folds, recorded off the real
  # {Lain::CLI::SessionJournals} construction rather than recomputed here -- a
  # spec that rebuilds the path proves only that it can do the same arithmetic
  # twice. `records_for` is `status`'s own journal entry point; the other three
  # each name theirs `journals`.
  def journal_dirs
    dirs = {}
    allow(Lain::CLI::SessionJournals).to receive(:new).and_wrap_original do |original, **kwargs|
      dirs[@asking] = Array(kwargs[:dirs])
      original.call(**kwargs)
    end
    verbs.each do |name, verb|
      @asking = name
      name.end_with?("status") ? verb.send(:records_for, "alpha") : verb.send(:journals).to_a
    end
    dirs
  end

  describe "the journal directories -- the same pair, whichever verb asks" do
    it "agrees across every epic verb, from a subdirectory of the project" do
      in_subdirectory_of_a_project do
        dirs = journal_dirs

        expect(dirs.values.uniq.length).to eq(1), lambda {
          listing = dirs.map { |name, dir| "  #{name} -> #{dir}" }.join("\n")
          "the epic tier folds more than one set of session directories:\n#{listing}"
        }
      end
    end

    it "folds the root's directory, then the working directory's" do
      in_subdirectory_of_a_project do |root, sub|
        paths = Lain::Paths.new

        expect(journal_dirs.values.first)
          .to eq([paths.sessions_dir(project: paths.project_hash(root)),
                  paths.sessions_dir(project: paths.project_hash(sub))])
      end
    end

    it "folds a single directory when the working directory is the root" do
      in_subdirectory_of_a_project do |root, _sub|
        Dir.chdir(root) { expect(journal_dirs.values.first.length).to eq(1) }
      end
    end

    it "is where a chat files its journal, and where a root-bearing EpicMount reads back" do
      in_subdirectory_of_a_project do |root, _sub|
        seen = nil
        allow(Lain::CLI::SessionJournals).to receive(:new).and_wrap_original do |original, **kwargs|
          seen = Array(kwargs[:dirs])
          original.call(**kwargs)
        end
        mount_for(root).send(:prior_claims)
        chat_dir = File.dirname(Lain::CLI::Chronicle.for(enabled: true, root:).journal_path)

        expect(seen).to include(chat_dir)
      end
    end
  end

  describe "a review chat launched below the root with --root" do
    def claim = { "type" => Lain::Epic::ReviewOpened::JOURNAL_TYPE, "epic_slug" => "alpha", "generation" => 7 }

    def launch_chat_recording_a_claim(root)
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      wiring = instance_double(Lain::CLI::Wiring, conductor: instance_spy(Lain::CLI::Conductor), exit_status: 0)
      allow(wiring).to receive(:run)
      allow(Lain::CLI::Wiring).to receive(:new) do |**wired|
        wired.fetch(:chronicle).durable_journal.record(claim)
        wiring
      end
      LainCLI.start(["chat", "--root", root, "--journal"], debug: true)
    end

    it "has its claim seen from the root and from the subdirectory" do
      in_subdirectory_of_a_project do |root, sub|
        Dir.chdir(sub) { launch_chat_recording_a_claim(root) }

        seen = [root, sub].map do |from|
          Dir.chdir(from) { Lain::CLI::EpicMount.prior_claims(Lain::Paths.new, root:).map { |record| record["generation"] } }
        end

        expect(seen).to eq([[7], [7]])
      end
    end
  end

  describe "the epic container -- keyed on the resolved project root" do
    # The other axis, asserted independently: same fixture, same subdirectory,
    # opposite answer. Together the two are what make "two keyings, each
    # internally uniform" a fact rather than a claim in a comment.
    it "is the root rather than the cwd, and the same one for every verb" do
      in_subdirectory_of_a_project do |root, sub|
        roots = verbs.transform_values { |verb| verb.instance_variable_get(:@root) }.compact

        expect(roots.values.uniq).to eq([root])
        expect(roots.values).not_to include(sub)
      end
    end

    it "is the container the chat's own project resolves" do
      in_subdirectory_of_a_project do |root, _sub|
        container = Lain::Epic::Home.container(config: Lain::Config.load(root:), paths: Lain::Paths.new, root:)

        expect(Lain::Project::Resolver.default_project.root).to eq(root)
        expect(container).to eq(File.join(root, ".lain", "epics"))
        expect(Lain::CLI::Epic.new.status).to include("alpha")
      end
    end
  end

  # A real mount over the project root, built through its own constructor rather
  # than `allocate` -- `root:` is handed in deliberately here, since what the
  # example above is about is that the journal directory does NOT follow it.
  def mount_for(root)
    Lain::CLI::EpicMount.new(slug: "alpha", journal: Lain::Journal.new(io: StringIO.new), root:,
                             told: ->(_text) {}, paths: Lain::Paths.new, config: Lain::Config.load(root:))
  end
end
