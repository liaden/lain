# frozen_string_literal: true

RSpec.describe Lain::Shell::Path do
  around { |example| Dir.mktmpdir("path_spec") { |dir| (@root = dir) && example.run } }

  def bin(name)
    Dir.mkdir(File.join(@root, name))
    File.join(@root, name)
  end

  def program_in(dir, executable:)
    file = File.join(dir, "notify-feed")
    File.write(file, "#!/bin/sh\n")
    File.chmod(executable ? 0o755 : 0o644, file)
    file
  end

  describe ".find" do
    it "answers the first executable, skipping a copy that is not executable" do
      first = bin("a")
      second = bin("b")
      program_in(first, executable: false)
      expected = program_in(second, executable: true)

      expect(described_class.find("notify-feed", path: [first, second].join(File::PATH_SEPARATOR))).to eq(expected)
    end

    it "does not treat an empty entry as the cwd" do
      cwd = bin("cwd")
      program_in(cwd, executable: true)

      Dir.chdir(cwd) do
        expect(described_class.find("notify-feed", path: "/usr/bin::/nonexistent-dir")).to be_nil
      end
    end

    it "does not count a directory of that name as a program" do
      dir = bin("d")
      Dir.mkdir(File.join(dir, "docker"))

      expect(described_class.find("docker", path: dir)).to be_nil
    end

    it "asks the injected filesystem" do
      fs = class_double(File, file?: true, executable?: true)

      expect(described_class.find("docker", path: "/x", filesystem: fs)).to eq("/x/docker")
    end
  end

  describe ".entries" do
    it "drops empty entries" do
      expect(described_class.entries("/usr/bin::/bin:")).to eq(%w[/usr/bin /bin])
    end

    it "is empty for an empty PATH" do
      expect(described_class.entries("")).to eq([])
    end
  end
end
