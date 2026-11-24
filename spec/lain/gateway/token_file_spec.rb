# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Gateway::TokenFile do
  let(:dir) { Dir.mktmpdir("token-file") }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state") }) }
  let(:token) { "0123456789abcdef0123456789abcdef" }
  let(:file) { described_class.for(4000, paths:) }

  after { FileUtils.rm_rf(dir) }

  # mkdir_p follows the umask; the reader refuses a group-writable directory.
  around do |example|
    old = File.umask(0o022)
    example.run
  ensure
    File.umask(old)
  end

  def mode(path) = File.lstat(path).mode & 0o777

  # Every file this spec writes is ours, so the reader is made someone else.
  def as_another_user
    stranger = Process.uid + 1
    allow(Process).to receive(:uid).and_return(stranger)
  end

  def refusal
    yield
    nil
  rescue described_class::Unusable => e
    e
  end

  it "is named for its port under the state home's gateway directory" do
    expect(file.path).to eq(File.join(dir, "state", "lain", "gateway", "4000.token"))
  end

  def gateway_dir = File.dirname(file.path)

  # A gateway directory that is a link to a looser one elsewhere.
  def link_gateway_dir
    loose = File.join(dir, "loose")
    Dir.mkdir(loose)
    File.chmod(0o777, loose)
    FileUtils.mkdir_p(File.dirname(gateway_dir))
    File.symlink(loose, gateway_dir)
    loose
  end

  describe "#write" do
    # The directory exists already, as it does after a gateway's first start;
    # under this umask a fresh one would be untraversable.
    it "makes a 0600 file under a tight umask, which its own reader accepts" do
      FileUtils.mkdir_p(gateway_dir, mode: 0o700)
      old = File.umask(0o277)
      begin
        file.write(token)
      ensure
        File.umask(old)
      end

      expect([mode(file.path), file.read]).to eq([0o600, token])
    end

    it "tightens a directory it finds at 0755 to 0700" do
      FileUtils.mkdir_p(gateway_dir)
      File.chmod(0o755, gateway_dir)

      file.write(token)

      expect(mode(gateway_dir)).to eq(0o700)
    end

    it "refuses a gateway directory that is a symlink, writing nothing through it" do
      loose = link_gateway_dir

      expect(refusal { file.write(token) }.message).to include(file.path, "symlink")
      expect(Dir.children(loose)).to be_empty
    end

    it "refuses a gateway directory others may write to" do
      FileUtils.mkdir_p(gateway_dir)
      File.chmod(0o777, gateway_dir)

      expect(refusal { file.write(token) }.message).to include(file.path, "writable by others")
    end

    it "names the path rather than a raw system error when it cannot write" do
      FileUtils.mkdir_p(File.join(dir, "state"))
      File.write(File.join(dir, "state", "lain"), "a file where the directory goes")

      expect(refusal { file.write(token) }.message).to include(file.path, "cannot be written")
    end

    it "removes this port's leftover temporary files, and no other port's" do
      FileUtils.mkdir_p(gateway_dir)
      mine = File.join(gateway_dir, ".4000.token.0123456789abcdef")
      other = File.join(gateway_dir, ".4001.token.0123456789abcdef")
      [mine, other].each { File.write(_1, "half") }

      file.write(token)

      expect([File.exist?(mine), File.exist?(other)]).to eq([false, true])
    end

    it "writes the token to a 0600 file in a 0700 directory" do
      file.write(token)

      expect([File.read(file.path), mode(file.path), mode(File.dirname(file.path))]).to eq([token, 0o600, 0o700])
    end

    it "replaces a stale file whole, leaving no temporary file beside it" do
      file.write("f" * 32)
      file.write(token)

      expect(File.read(file.path)).to eq(token)
      expect(Dir.children(File.dirname(file.path))).to eq(["4000.token"])
    end

    it "refuses a symlink at its path, naming the path, and writes nothing through it" do
      target = File.join(dir, "elsewhere")
      FileUtils.mkdir_p(File.dirname(file.path))
      File.symlink(target, file.path)

      expect(refusal { file.write(token) }.message).to include(file.path).and(include("not a regular file"))
      expect(File.exist?(target)).to be(false)
    end

    it "refuses a directory at its path" do
      FileUtils.mkdir_p(file.path)

      expect(refusal { file.write(token) }.message).to include(file.path)
    end

    it "refuses a file at its path that another user owns" do
      FileUtils.mkdir_p(File.dirname(file.path))
      File.write(file.path, "theirs")
      as_another_user

      expect(refusal { file.write(token) }.message).to include(file.path, "owned by another user")
    end
  end

  describe "#remove" do
    it "removes the file it wrote" do
      file.write(token)
      file.remove(token)

      expect(File.exist?(file.path)).to be(false)
    end

    it "leaves a file holding another gateway's token" do
      file.write("f" * 32)
      file.remove(token)

      expect(File.read(file.path)).to eq("f" * 32)
    end

    it "is quiet when the file is already gone" do
      expect { file.remove(token) }.not_to raise_error
    end
  end

  describe "#read" do
    it "refuses a symlinked gateway directory, though the file in it is good" do
      loose = link_gateway_dir
      File.write(File.join(loose, "4000.token"), token)
      File.chmod(0o600, File.join(loose, "4000.token"))

      expect(refusal { file.read }.message).to include(file.path, "symlink")
    end

    it "refuses a gateway directory others may write to, where the file could be swapped" do
      file.write(token)
      File.chmod(0o777, gateway_dir)

      expect(refusal { file.read }.message).to include(file.path, "writable by others")
    end

    it "refuses a FIFO without waiting on it" do
      FileUtils.mkdir_p(gateway_dir)
      File.chmod(0o700, gateway_dir)
      File.mkfifo(file.path)

      expect(refusal { file.read }.message).to include(file.path, "not a regular file")
    end

    it "refuses a file it cannot read, naming the path rather than a raw system error" do
      file.write(token)
      File.chmod(0o000, file.path)

      expect(refusal { file.read }.message).to include(file.path)
    ensure
      File.chmod(0o600, file.path)
    end

    it "answers the token a gateway wrote" do
      file.write(token)

      expect(file.read).to eq(token)
    end

    it "refuses a missing file, asking whether the gateway runs on that port" do
      expect(refusal { file.read }.message)
        .to eq("no gateway token at #{file.path}; is `lain gateway` running on that port?")
    end

    it "refuses a file other users may read, naming the path and never the token" do
      file.write(token)
      File.chmod(0o644, file.path)

      message = refusal { file.read }.message
      expect(message).to include(file.path, "0600")
      expect(message).not_to include(token)
    end

    it "refuses a symlink, though it points at a good file" do
      real = File.join(dir, "real.token")
      File.write(real, token)
      File.chmod(0o600, real)
      FileUtils.mkdir_p(File.dirname(file.path))
      File.symlink(real, file.path)

      expect(refusal { file.read }.message).to include(file.path, "not a regular file")
    end

    it "refuses a file another user owns" do
      file.write(token)
      as_another_user

      expect(refusal { file.read }.message).to include(file.path, "owned by another user")
    end

    it "refuses an empty file" do
      file.write(token)
      File.write(file.path, "")

      expect(refusal { file.read }.message).to include(file.path, "empty")
    end
  end
end
