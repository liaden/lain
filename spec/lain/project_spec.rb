# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Project do
  # Scenario: cwd must lie under root
  describe "when cwd does not lie under root" do
    it "raises, and the message names both paths" do
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |elsewhere|
          resolved_root = File.realpath(root)
          resolved_elsewhere = File.realpath(elsewhere)

          expect { described_class.new(root:, cwd: elsewhere, kind: :project, detected_by: :git) }
            .to raise_error(ArgumentError, /#{Regexp.escape(resolved_root)}.*#{Regexp.escape(resolved_elsewhere)}/)
        end
      end
    end
  end

  # Scenario: a Project is deeply frozen and shareable
  describe "as a deeply frozen value object" do
    it "is Ractor.shareable? -- no reachable mutable state" do
      Dir.mktmpdir do |dir|
        project = described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :git)
        expect(project).to be_deeply_frozen
      end
    end

    it "freezes every String field" do
      Dir.mktmpdir do |dir|
        project = described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :git)
        expect(project.root).to be_frozen
        expect(project.cwd).to be_frozen
      end
    end
  end

  # Scenario: root and cwd are compared after symlink resolution
  describe "when cwd is a symlink resolving to a real subdirectory of root" do
    it "is accepted, and #cwd reports the resolved path" do
      Dir.mktmpdir do |root|
        sub = File.join(root, "sub")
        FileUtils.mkdir(sub)

        Dir.mktmpdir do |link_home|
          link = File.join(link_home, "cwd-link")
          File.symlink(sub, link)

          project = described_class.new(root:, cwd: link, kind: :project, detected_by: :git)
          expect(project.cwd).to eq(File.realpath(sub))
        end
      end
    end
  end

  # Scenario: kind is a closed set
  describe "when kind is outside the closed set" do
    it "raises and names :project and :home" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(root: dir, cwd: dir, kind: :scratch, detected_by: :git) }
          .to raise_error(ArgumentError, /:project.*:home/)
      end
    end
  end

  # Scenario: detected_by is a closed set
  describe "when detected_by is outside the closed set" do
    it "raises and names the five known rungs" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :guess) }
          .to raise_error(ArgumentError, /:flag.*:config.*:lain_dir.*:git.*:none/)
      end
    end
  end

  # Fix round -- SF-1 (panel): `cwd.start_with?("#{root}/")` builds a bogus
  # "//" at the filesystem root, refusing every cwd under "/". The
  # trailing-slash idiom itself has to stay, though -- it is what refuses a
  # same-prefix SIBLING (`/tmp` vs `/tmp-other`) rather than a real child.
  describe "when root is the filesystem root" do
    it "accepts an ordinary cwd under it, rather than refusing on a doubled slash" do
      Dir.mktmpdir do |dir|
        project = described_class.new(root: "/", cwd: dir, kind: :project, detected_by: :git)
        expect(project.root).to eq("/")
        expect(project.cwd).to eq(File.realpath(dir))
      end
    end
  end

  describe "when cwd merely shares root's name as a PREFIX (not a real child)" do
    it "still refuses -- the trailing-slash anchor this fix keeps" do
      Dir.mktmpdir do |base|
        root = File.join(base, "proj")
        sibling = File.join(base, "proj-other")
        FileUtils.mkdir(root)
        FileUtils.mkdir(sibling)

        expect { described_class.new(root:, cwd: sibling, kind: :project, detected_by: :git) }
          .to raise_error(ArgumentError, /must lie under root/)
      end
    end
  end

  # Fix round -- SF-2 (panel, mutation-proven): a hand-copied "must be one of
  # :project, :home" literal can drift out of sync with the real KINDS/
  # DETECTED_BY the inclusion check enforces (the panel's mutant added
  # :library to KINDS and the OLD hardcoded message stayed green and wrong).
  # Asserting against `described_class::KINDS.inspect`/`DETECTED_BY.inspect`
  # ties the expectation to the SAME live constant the check enforces, so a
  # future member added to one and not reflected in the other's message
  # fails this example on its own, without needing to be named up front the
  # way the `:scratch`/`:guess` examples above do.
  describe "the closed-set refusal message" do
    it "is built from the live KINDS constant, not a hand-copied literal" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(root: dir, cwd: dir, kind: :scratch, detected_by: :git) }
          .to raise_error(ArgumentError, /#{Regexp.escape(described_class::KINDS.inspect)}/)
      end
    end

    it "is built from the live DETECTED_BY constant, not a hand-copied literal" do
      Dir.mktmpdir do |dir|
        expect { described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :guess) }
          .to raise_error(ArgumentError, /#{Regexp.escape(described_class::DETECTED_BY.inspect)}/)
      end
    end
  end

  # Fix round -- SF-3 (panel): `root`'s own symlink resolution, #to_s and
  # #inspect were all exercised by nothing -- three mutants (drop realpath on
  # root, blank #to_s, drop `include Inspectable`) survived the suite.
  describe "when root itself is a symlink resolving to a real directory" do
    it "is accepted, and #root reports the resolved path" do
      Dir.mktmpdir do |real_root|
        Dir.mktmpdir do |link_home|
          link = File.join(link_home, "root-link")
          File.symlink(real_root, link)

          project = described_class.new(root: link, cwd: real_root, kind: :project, detected_by: :git)
          expect(project.root).to eq(File.realpath(real_root))
        end
      end
    end
  end

  describe "#to_s" do
    it "names kind, root, cwd and detected_by" do
      Dir.mktmpdir do |dir|
        project = described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :git)
        expect(project.to_s).to include("project", project.root, project.cwd, "git")
      end
    end
  end

  describe "#inspect" do
    it "wraps #to_s in the class-tagged Inspectable form" do
      Dir.mktmpdir do |dir|
        project = described_class.new(root: dir, cwd: dir, kind: :project, detected_by: :git)
        expect(project.inspect).to eq("#<#{described_class} #{project}>")
      end
    end
  end

  # Fix round -- SF-4 (panel ruling): a missing/unreadable root or cwd used to
  # let a raw `Errno::ENOENT`/`Errno::EACCES` escape -- exactly the failure
  # {Epic::Home::UnreadableHome} exists to prevent for `exe/lain`, which
  # rescues `Lain::Error` only. The refusal names WHICH role failed (root vs
  # cwd resolved separately, so this is free) and the path given.
  describe "when root does not exist" do
    it "raises a named Lain::Error naming the root role and the path, not a raw SystemCallError" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "does-not-exist")

        expect { described_class.new(root: missing, cwd: dir, kind: :project, detected_by: :git) }
          .to raise_error(Lain::Project::Unresolvable) { |e|
            expect(e).to be_a(Lain::Error)
            expect(e.message).to include("root", missing)
          }
      end
    end
  end

  describe "when cwd does not exist" do
    it "raises a named Lain::Error naming the cwd role and the path, not a raw SystemCallError" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "does-not-exist")

        expect { described_class.new(root: dir, cwd: missing, kind: :project, detected_by: :git) }
          .to raise_error(Lain::Project::Unresolvable) { |e|
            expect(e).to be_a(Lain::Error)
            expect(e.message).to include("cwd", missing)
          }
      end
    end
  end
end
