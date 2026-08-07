# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# The epic tier answers "which project am I in?" on TWO axes, and they are keyed
# DIFFERENTLY on purpose. Nothing states that anywhere else, and until T5 nothing
# could tell: both answers resolved to the working directory, so the two
# spellings agreed by accident.
#
#   * the epic CONTAINER -- where the documents live -- is keyed on the resolved
#     PROJECT ROOT ({Lain::Project::Resolver.default_project}), so a chat and every
#     `lain epic ...` invocation see one set of epics from anywhere in the tree;
#   * the epic JOURNAL DIRECTORY -- where verdicts, intents and review claims are
#     recorded -- is keyed on the WORKING DIRECTORY, through
#     {Lain::Paths#sessions_dir}'s `project_hash(Dir.pwd)` default.
#
# The second reads as odd until you notice what the alternative costs. Making the
# journal directory follow the root means changing where `sessions_dir` points,
# which relocates every resumable session on the machine and orphans the ones
# that exist -- `--resume`, `watch`, `sessions` and `--fork` all read that
# directory. That is a migration, not a keying change, and it is ticketed
# separately. A card should not half-do a migration on its way past.
#
# == Why this file exists, and why it is a seam
#
# T5 threaded a resolved project root through the chat and the epic subcommands.
# It did not edit either of the two journal-directory lines -- it changed what
# `@root` MEANS, and two sites keyed on `project_hash(@root)`
# ({Lain::CLI::Epic::Journals}, {Lain::CLI::EpicMount#prior_claims}) silently
# stopped agreeing with the four that take the `sessions_dir` default. From a
# subdirectory, `lain epic submit` wrote its verdict where `lain epic status`
# would not look. Both lines are back on the default now, and this is what says
# so.
#
# THE WHOLE SUITE STAYED GREEN THROUGHOUT. Every epic spec injects `paths:` and
# `root:` together, so the two keyings cannot disagree inside a fixture: A
# FIXTURE THAT SUPPLIES BOTH HALVES OF A RELATIONSHIP CANNOT TEST THE
# RELATIONSHIP. That is the same family as this chunk's other vacuity findings,
# and it is why nothing below injects `paths:` or a root the object could have
# resolved itself. `HOME` and `XDG_STATE_HOME` move into the fixture -- that is
# environment, not injection -- and every object is built the way `exe/lain`
# builds it.
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
      write_repo_epic(root, "alpha")
      with_env("HOME" => base, "XDG_STATE_HOME" => File.join(base, "state")) do
        Dir.chdir(sub) { yield(root, sub) }
      end
    end
  end

  def write_repo_epic(root, slug)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(File.join(root, ".lain", "config.toml"), %([epics]\nhome = "repo"\n))
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
      "lain epic land" => Lain::CLI::EpicLand.new(github: instance_double(Lain::Forge::Gh)),
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
      dirs[@asking] = kwargs[:dir]
      original.call(**kwargs)
    end
    verbs.each do |name, verb|
      @asking = name
      name.end_with?("status") ? verb.send(:records_for, "alpha") : verb.send(:journals).to_a
    end
    dirs
  end

  describe "the journal directory -- ONE directory, whichever verb asks" do
    it "agrees across every epic verb, from a subdirectory of the project" do
      in_subdirectory_of_a_project do
        dirs = journal_dirs

        expect(dirs.values.uniq.length).to eq(1), lambda {
          listing = dirs.map { |name, dir| "  #{name} -> #{dir}" }.join("\n")
          "the epic tier folds more than one session directory:\n#{listing}"
        }
      end
    end

    # It follows the WORKING DIRECTORY, which is the half a reader will doubt.
    # Stated positively, because four objects agreeing on the WRONG directory
    # would satisfy the example above perfectly well.
    it "is keyed on the working directory, not on the resolved project root" do
      in_subdirectory_of_a_project do |root, sub|
        paths = Lain::Paths.new
        dir = journal_dirs.values.first

        expect(dir).to eq(paths.sessions_dir(project: paths.project_hash(sub)))
        expect(dir).not_to eq(paths.sessions_dir(project: paths.project_hash(root)))
      end
    end

    # The chat writes into that same directory ({Lain::CLI::Chronicle} opens
    # `Journal.default_path`), and {Lain::CLI::EpicMount} reads review claims
    # back out of it. A chat whose claims land where its own mount cannot see
    # them replays nothing across a restart -- and the mount is handed the
    # PROJECT ROOT, so this is also the assertion that the journal axis ignores
    # the root it is given.
    it "is where the chat writes, and where a root-bearing EpicMount reads back" do
      in_subdirectory_of_a_project do |root, _sub|
        dir = journal_dirs.values.first
        seen = nil
        allow(Lain::CLI::SessionJournals).to receive(:new).and_wrap_original do |original, **kwargs|
          seen = kwargs[:dir]
          original.call(**kwargs)
        end
        mount_for(root).send(:prior_claims)

        expect(File.dirname(Lain::Journal.default_path(paths: Lain::Paths.new))).to eq(dir)
        expect(seen).to eq(dir)
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
                             paths: Lain::Paths.new, config: Lain::Config.load(root:))
  end
end
