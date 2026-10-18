# frozen_string_literal: true

RSpec.describe Lain::Shell::Executable::ListedStat do
  def entry(type, mode: 0o755, link: nil)
    described_class::Entry.new(type:, mode:, uid: 0, gid: 0, link:)
  end

  let(:entries) do
    {
      "/usr" => entry("directory"),
      "/usr/bin" => entry("directory", mode: 0o777),
      "/bin" => entry("symlink", link: "usr/bin"),
      "/usr/bin/ls" => entry("file"),
      "/usr/bin/mawk" => entry("file"),
      "/usr/bin/perl5.38.2" => entry("hardlink"),
      "/etc" => entry("directory"),
      "/etc/alternatives" => entry("directory"),
      "/etc/alternatives/awk" => entry("symlink", link: "/usr/bin/mawk"),
      "/usr/bin/awk" => entry("symlink", link: "/etc/alternatives/awk"),
      "/etc/motd" => entry("file", mode: 0o644),
      "/a" => entry("symlink", link: "/b"),
      "/b" => entry("symlink", link: "/a")
    }
  end
  let(:stat) { described_class.new(entries) }

  context "with a link whose target climbs through dot-dot" do
    let(:climbing) do
      described_class.new(
        "/bin" => entry("directory"), "/bin/busybox" => entry("file"), "/usr" => entry("directory"),
        "/usr/local" => entry("directory"), "/usr/local/bin" => entry("directory"),
        "/usr/local/bin/uname" => entry("symlink", link: "../../../bin/busybox")
      )
    end

    it "answers lstat for the path the kernel would reach" do
      expect(climbing.lstat("/usr/local/bin/../../../bin/busybox")).to eq(entry("file"))
    end

    it "resolves the program on a PATH that holds the link" do
      resolver = Lain::Shell::Executable::Resolver.new(root: "/srv/project", fresh: Lain::Shell::Executable::Resolver::NeverFresh,
                                                       stat: climbing, host_env: { "PATH" => "/usr/local/bin" })

      executable = resolver.for(Lain::WorkerEnv.new(cwd: "/", env: {})).call(Lain::Shell::Term.of(%w[uname])).sole

      expect(executable).to have_attributes(resolved: "/usr/local/bin/uname", realpath: "/bin/busybox", klass: :system)
    end
  end

  it "answers lstat for a path ending in dot-dot as the directory it names" do
    expect(stat.lstat("/usr/bin/..")).to eq(entries.fetch("/usr"))
  end

  it "answers lstat and readlink through a symlinked parent" do
    expect([stat.lstat("/bin/ls"), stat.readlink("/bin/awk")]).to eq([entry("file"), "/etc/alternatives/awk"])
  end

  it "resolves a link chain" do
    expect(stat.realpath("/usr/bin/awk")).to eq("/usr/bin/mawk")
  end

  it "resolves a directory symlink" do
    expect(stat.realpath("/bin/ls")).to eq("/usr/bin/ls")
  end

  it "resolves a dot-dot after a link" do
    expect(stat.realpath("/bin/../bin/ls")).to eq("/usr/bin/ls")
  end

  it "reports a missing path as absent" do
    expect([stat.executable?("/usr/local/sbin/ls"), stat.directory?("/usr/local/sbin")]).to eq([false, false])
  end

  it "raises ENOENT for lstat, readlink and realpath of a missing path" do
    errors = %i[lstat readlink realpath].map do |m|
      stat.public_send(m, "/usr/local/sbin")
    rescue Errno::ENOENT => e
      e.class
    end
    expect(errors).to all(eq(Errno::ENOENT))
  end

  it "follows a symlink for executable? and honours the mode" do
    expect([stat.executable?("/bin/ls"), stat.executable?("/etc/motd")]).to eq([true, false])
  end

  it "does not count a directory as executable" do
    expect(stat.executable?("/usr/bin")).to be(false)
  end

  it "treats a hard link as a file with its own mode" do
    expect(stat.executable?("/usr/bin/perl5.38.2")).to be(true)
  end

  it "follows a symlink for directory?" do
    expect(stat.directory?("/bin")).to be(true)
  end

  it "makes nothing writable" do
    expect(stat.writable?("/usr/bin")).to be(false)
  end

  it "stops a loop with ELOOP" do
    expect { stat.realpath("/a") }.to raise_error(Errno::ELOOP)
  end

  it "answers lstat as the link itself" do
    expect([stat.lstat("/bin").symlink?, stat.lstat("/usr/bin").symlink?]).to eq([true, false])
  end

  it "answers readlink as written" do
    expect(stat.readlink("/bin")).to eq("usr/bin")
  end

  it "raises EINVAL reading a non-link" do
    expect { stat.readlink("/etc/motd") }.to raise_error(Errno::EINVAL)
  end

  it "returns the path as given when real cannot resolve it" do
    expect([stat.real("/bin/ls"), stat.real("/nope")]).to eq(["/usr/bin/ls", "/nope"])
  end

  it "lists the sorted children of a directory" do
    expect(stat.children("/usr/bin")).to eq(%w[awk ls mawk perl5.38.2])
  end

  it "lists children through a directory symlink" do
    expect(stat.children("/bin")).to eq(stat.children("/usr/bin"))
  end

  it "lists the top-level names under the root" do
    expect(stat.children("/")).to eq(%w[a b bin etc usr])
  end

  describe "a chain of links" do
    def chain(length)
      links = (1..length).to_h { |i| ["/l#{i}", entry("symlink", link: i == length ? "/usr/bin/ls" : "/l#{i + 1}")] }
      described_class.new(entries.merge(links))
    end

    it "resolves at exactly the kernel limit" do
      limit = Lain::Shell::Executable::Resolver::Bound::MAX_LINKS
      expect(chain(limit).realpath("/l1")).to eq("/usr/bin/ls")
    end

    it "raises ELOOP one past the limit" do
      limit = Lain::Shell::Executable::Resolver::Bound::MAX_LINKS
      expect { chain(limit + 1).realpath("/l1") }.to raise_error(Errno::ELOOP)
    end
  end
end
