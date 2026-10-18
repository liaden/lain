# frozen_string_literal: true

require "rubygems/package"
require "stringio"

RSpec.describe Lain::Exec::Docker::Export do
  let(:entry) { Lain::Shell::Executable::ListedStat::Entry }

  # A tar as `docker export` writes one: relative names, a directory's with a
  # trailing slash, and no entry for the root.
  def tar
    io = StringIO.new(+"", "w+b")
    Gem::Package::TarWriter.new(io) { |writer| yield writer, io }
    io.rewind
    io
  end

  def hardlink(io, name, target) = header(io, name:, linkname: target, typeflag: "1")

  def header(io, body: "", **fields)
    io.write(Gem::Package::TarHeader.new(mode: 0o755, size: body.bytesize, prefix: "", **fields).to_s)
    io.write(body.ljust((body.bytesize + 511) / 512 * 512, "\0"))
  end

  # A record's length counts its own digits, so it is found by trying each width.
  def pax(io, **records)
    body = records.map do |key, value|
      line = " #{key}=#{value}\n"
      length = (1..4).map { line.bytesize + _1 }.find { _1.to_s.size + line.bytesize == _1 }
      "#{length}#{line}"
    end.join
    header(io, name: "PaxHeaders.0/x", typeflag: "x", body:)
  end

  describe ".read" do
    it "reads each entry's type, mode, owner and link, rooted, and skips the bodies" do
      entries = described_class.read(tar do |w, io|
        w.mkdir("usr/", 0o755)
        w.add_file_simple("usr/motd", 0o644, 5) { _1.write("hello") }
        w.add_symlink("usr/sh", "/bin/busybox", 0o777)
        hardlink(io, "usr/perl", "usr/perl5.38")
      end)

      expect(entries).to eq(
        "/usr" => entry.new(type: "directory", mode: 0o755, uid: 0, gid: 0, link: nil),
        "/usr/motd" => entry.new(type: "file", mode: 0o644, uid: 0, gid: 0, link: nil),
        "/usr/sh" => entry.new(type: "symlink", mode: 0o777, uid: 0, gid: 0, link: "/bin/busybox"),
        "/usr/perl" => entry.new(type: "hardlink", mode: 0o755, uid: 0, gid: 0, link: "/usr/perl5.38")
      )
    end
  end

  describe "a header it must not misread" do
    it "applies an extended header's path and linkpath to the next entry" do
      long = "usr/local/bin/#{"p" * 130}"
      entries = described_class.read(tar do |_, io|
        pax(io, path: long)
        header(io, name: long[0, 100], typeflag: "0")
        header(io, name: "usr/local/bin/plain", typeflag: "0")
        pax(io, linkpath: "/#{long}")
        header(io, name: "usr/local/bin/short", linkname: long[0, 100], typeflag: "2")
      end)

      expect(entries.keys).to eq(["/#{long}", "/usr/local/bin/plain", "/usr/local/bin/short"])
      expect(entries["/usr/local/bin/short"].link).to eq("/#{long}")
    end

    it "refuses a header that would change names it does not apply" do
      %w[g L K].each do |flag|
        bytes = tar { |_, io| header(io, name: "././@LongLink", typeflag: flag, body: "x") }

        expect { described_class.read(bytes) }.to raise_error(Gem::Package::TarInvalidError, /#{flag}/)
      end
    end

    it "drops an entry whose name is not valid in the filesystem's encoding" do
      entries = described_class.read(tar do |w|
        w.mkdir("bin/", 0o755)
        w.add_file_simple("bin/ok", 0o755, 0) { nil }
        w.add_file_simple((+"bin/caf\xE9").force_encoding(Encoding::BINARY), 0o755, 0) { nil }
      end)

      expect(entries.keys).to eq(["/bin", "/bin/ok"])
    end

    # The cache is shared, so what one exporter's locale would drop another's must not keep.
    it "judges a name as UTF-8 whatever the filesystem's encoding" do
      stub_const("Lain::FILESYSTEM", Encoding::US_ASCII)

      entries = described_class.read(tar { |w| w.add_file_simple("bin/café", 0o755, 0) { nil } })

      expect(entries.keys).to eq(["/bin/café"])
      expect(entries.keys.first.encoding).to eq(Encoding::UTF_8)
    end

    it "refuses a tar that stops before its end-of-archive marker" do
      whole = tar { |w| w.add_file_simple("bin/ok", 0o755, 600) { _1.write("x" * 600) } }.string

      [whole.byteslice(0, whole.bytesize - 512), whole.byteslice(0, 700)].each do |cut|
        expect { described_class.read(StringIO.new(cut)) }.to raise_error(Gem::Package::TarInvalidError, /end/)
      end
      expect(described_class.read(StringIO.new(whole)).keys).to eq(["/bin/ok"])
    end
  end

  describe ".keep" do
    let(:entries) do
      described_class.read(tar do |w|
        w.mkdir("etc/", 0o755)
        w.add_file_simple("etc/motd", 0o644, 0) { nil }
        w.mkdir("usr/", 0o755)
        w.mkdir("usr/bin/", 0o755)
        w.add_file_simple("usr/bin/mawk", 0o755, 0) { nil }
        w.add_symlink("usr/bin/awk", "/etc/alternatives/awk", 0o777)
        w.mkdir("usr/share/", 0o755)
        w.add_file_simple("usr/share/README", 0o644, 0) { nil }
        w.mkdir("etc/alternatives/", 0o755)
        w.add_symlink("etc/alternatives/awk", "/usr/bin/mawk", 0o777)
        w.add_symlink("bin", "usr/bin", 0o777)
      end)
    end

    it "keeps every link hop and ancestor of a PATH directory's children, wherever they sit in the tar" do
      kept = described_class.keep(entries, path: "/bin")

      expect(kept.keys).to include("/bin", "/usr/bin/awk", "/etc/alternatives/awk", "/usr/bin/mawk", "/usr", "/")
      expect(kept.keys).not_to include("/etc/motd", "/usr/share/README")
      expect(Lain::Shell::Executable::ListedStat.new(kept).realpath("/bin/awk")).to eq("/usr/bin/mawk")
    end

    it "passes over a PATH directory the image does not have, and one that is not absolute" do
      kept = described_class.keep(entries, path: "/usr/local/sbin:bin::/usr/bin")

      expect(kept.keys).to eq(["/", "/etc", "/etc/alternatives", "/etc/alternatives/awk", "/usr", "/usr/bin",
                               "/usr/bin/awk", "/usr/bin/mawk"])
    end
  end
end
