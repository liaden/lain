# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Confine::Elf do
  around do |example|
    Dir.mktmpdir("lain-elf") do |dir|
      @dir = dir
      example.run
    end
  end

  # An ELF64 header and 1 program header, which names a loader when its type is PT_INTERP.
  def elf(name, segment: 1, order: "<", data: 1, phoff: 64, phentsize: 56, phnum: 1)
    fields = [2, 62, 1, 0, phoff, 0, 0, 64, phentsize, phnum, 0, 0, 0]
             .pack("SSLQQQLSSSSSS".chars.map { "#{_1}#{order}" }.join)
    header = ["\x7FELF".b, [2, data, 1].pack("C3"), "\0" * 9, fields, [segment].pack("L#{order}"), "\0" * 52].join
    File.join(@dir, name).tap { File.binwrite(_1, header) }
  end

  describe ".static?" do
    it "is true of an executable that names no loader, little-endian or big" do
      expect([described_class.static?(elf("le")), described_class.static?(elf("be", order: ">", data: 2))])
        .to eq([true, true])
    end

    it "is false of one that names a loader, and of the box's own dynamic true" do
      expect([described_class.static?(elf("dynamic", segment: 3)),
              described_class.static?(File.realpath("/usr/bin/true"))]).to eq([false, false])
    end

    it "is false of a script, a missing file and a directory" do
      script = File.join(@dir, "lint").tap { File.write(_1, "#!/bin/sh\n") }

      expect([script, File.join(@dir, "gone"), @dir].map { described_class.static?(_1) }).to eq([false, false, false])
    end

    it "is false, and raises nothing, where the program headers would start past any offset a seek can reach" do
      expect([elf("top", phoff: (2**64) - 1), elf("half", phoff: 2**63)].map { described_class.static?(_1) })
        .to eq([false, false])
    end

    it "is false where an entry is not the 56 bytes the kernel requires, however many it claims" do
      expect([elf("empty", phentsize: 0, phnum: 65_535), elf("short", phentsize: 4, phnum: 3)]
               .map { described_class.static?(_1) }).to eq([false, false])
    end

    it "is false where the program headers it claims run past the end of the file" do
      expect(described_class.static?(elf("long", phnum: 2))).to be(false)
    end
  end
end
