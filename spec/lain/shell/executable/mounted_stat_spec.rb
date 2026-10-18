# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Shell::Executable::MountedStat do
  def entry(type, mode: 0o755, link: nil)
    Lain::Shell::Executable::ListedStat::Entry.new(type:, mode:, uid: 0, gid: 0, link:)
  end

  let(:root) { File.realpath(Dir.mktmpdir("mounted-stat")) }
  let(:image) do
    Lain::Shell::Executable::ListedStat.new(
      "/usr" => entry("directory"), "/usr/bin" => entry("directory"),
      "/usr/bin/ruby" => entry("file"), "/usr/bin/ls" => entry("file"),
      "/usr/bin/rb" => entry("symlink", link: "ruby")
    )
  end
  let(:stat) { described_class.new(mounts: [root], image:) }

  before do
    FileUtils.mkdir_p("#{root}/bin")
    File.write("#{root}/bin/tool", "")
    File.chmod(0o755, "#{root}/bin/tool")
    File.symlink("/usr/bin/ruby", "#{root}/bin/ruby")
  end

  after { FileUtils.remove_entry(root) }

  it "reads the host for a mounted path" do
    expect([stat.executable?("#{root}/bin/tool"), stat.directory?("#{root}/bin")]).to eq([true, true])
  end

  it "reads the image for any other path" do
    expect([stat.executable?("/usr/bin/ls"), stat.writable?("/usr/bin/ls")]).to eq([true, false])
  end

  it "does not take a sibling of a mount for a mounted path" do
    FileUtils.mkdir_p("#{root}/bin2")
    File.write("#{root}/bin2/x", "")
    File.chmod(0o755, "#{root}/bin2/x")
    expect(described_class.new(mounts: ["#{root}/bin"], image:).executable?("#{root}/bin2/x")).to be(false)
  end

  context "when the image lacks the directories above a mount" do
    let(:stat) { described_class.new(mounts: ["#{root}/sub"], image:) }

    before { FileUtils.mkdir_p("#{root}/sub") }

    it "shows an ancestor as a directory to lstat" do
      expect(stat.lstat(root)).to be_directory
    end

    it "shows an ancestor as a directory to directory?" do
      expect(stat.directory?(root)).to be(true)
    end

    it "lists the next component toward the mount" do
      expect(stat.children(File.dirname(root))).to include(File.basename(root))
    end

    it "lists only the next component, merged with the image's own" do
      expect(described_class.new(mounts: ["/usr/bin/deep/er"], image:).children("/usr")).to eq(%w[bin])
    end

    it "adds the component toward a mount to the image's names" do
      expect(described_class.new(mounts: ["/usr/lib/x"], image:).children("/usr")).to eq(%w[bin lib])
    end
  end

  it "answers lstat from the image for a path that leaves the mount through dot-dot" do
    climbing = "#{root}#{"/.." * root.count("/")}/usr/bin/ls"

    expect(stat.lstat(climbing)).to eq(image.lstat("/usr/bin/ls"))
  end

  it "answers lstat from the image for a path under a host link out of the mount" do
    File.symlink("/usr/bin", "#{root}/up")

    expect(stat.lstat("#{root}/up/ls")).to eq(image.lstat("/usr/bin/ls"))
  end

  it "answers readlink from the image for a link under a host link out of the mount" do
    File.symlink("/usr/bin", "#{root}/up")

    expect(stat.readlink("#{root}/up/rb")).to eq("ruby")
  end

  it "lands a link out of the mount in the image" do
    expect(stat.realpath("#{root}/bin/ruby")).to eq("/usr/bin/ruby")
  end

  it "finds a file only the image has through a host link" do
    expect(stat.executable?("#{root}/bin/ruby")).to be(true)
  end

  it "answers lstat and readlink from the host for a mounted link" do
    expect([stat.lstat("#{root}/bin/ruby").symlink?, stat.readlink("#{root}/bin/ruby")]).to eq([true, "/usr/bin/ruby"])
  end

  it "lists a mounted directory from the host" do
    expect(stat.children("#{root}/bin")).to eq(%w[ruby tool])
  end

  it "reports a missing path as itself from real" do
    expect(stat.real("/nowhere/x")).to eq("/nowhere/x")
  end

  it "raises ENOENT from lstat on a missing image path" do
    expect { stat.lstat("/usr/local/sbin") }.to raise_error(Errno::ENOENT)
  end
end
