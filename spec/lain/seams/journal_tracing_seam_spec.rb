# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require "lain/lain" # the compiled Rust extension: Lain.hello, Lain::Ext.init_tracing

# The seam the lead tests: Ruby Journal events and Rust `tracing` spans land in
# ONE ordered NDJSON file, and every line parses independently. The Journal owns
# the fd; Rust `dup`s it (so closing one never closes the other) and writes whole
# lines under its own mutex, the mirror of the Journal's whole-line write. If the
# two disciplines hold, the merged stream parses line by line.
RSpec.describe "Journal x Rust tracing seam", :seam do
  it "merges Ruby events and Rust spans into one parseable NDJSON stream" do
    Dir.mktmpdir("lain-seam-tracing") do |dir|
      path = File.join(dir, "session.ndjson")
      journal = Lain::Journal.open(path)

      # Point the Rust subscriber at the Journal's own fd. init_tracing dups it,
      # so the Journal still owns and will close the original.
      installed = Lain::Ext.init_tracing("info", journal.fileno)

      journal.record("type" => "turn", "digest" => "blake3:aaa")
      # A Rust span+event, emitted synchronously into the same fd.
      Lain.hello("seam")
      journal.record("type" => "turn", "digest" => "blake3:bbb")
      Lain.hello("again")
      journal.record("type" => "usage", "input_tokens" => 42)

      journal.close # flushes and closes the Ruby side only

      contents = File.read(path)

      # THE invariant: every single line is a complete JSON object.
      expect(contents).to be_valid_ndjson

      records = contents.each_line.reject { |line| line.chomp.empty? }.map { |line| JSON.parse(line) }

      # Ruby events are present and carry our fields.
      digests = records.filter_map { |r| r["digest"] }
      expect(digests).to include("blake3:aaa", "blake3:bbb")

      # The Rust spans are here too, interleaved as their own JSON lines --
      # asserted flat. This example is the only in-process caller of
      # `init_tracing`, so it wins the one global install; a rival installer
      # landing in the suite later would route these spans elsewhere and leave
      # this file Rust-free, and that has to fail loudly here rather than skip
      # into a green run over a file no Rust line wrote.
      expect(installed).to be(true)
      rust_lines = records.select { |r| r.values_at("subject", "message").compact.any? }
      expect(rust_lines).not_to be_empty
    end
  end

  # The same seam, minus the escape hatch. `init_tracing` installs a GLOBAL
  # subscriber and only the first caller in a process wins, so a second example
  # asserting on Rust-written bytes IN THIS PROCESS reads `installed == false`
  # and skips the very thing it exists to check -- a green run over a file no
  # Rust line ever touched. A fresh process is what makes the install
  # unconditional, so the assertions below can be flat rather than guarded.
  def seam_script
    <<~RUBY
      require "json"

      journal = Lain::Journal.open(ARGV.fetch(0))
      installed = Lain::Ext.init_tracing("info", journal.fileno)

      journal.record("type" => "turn", "digest" => "blake3:ccc")
      Lain.hello("ansi")
      journal.record("type" => "usage", "input_tokens" => 7)
      Lain.hello("again")
      journal.close

      puts JSON.generate("installed" => installed)
    RUBY
  end

  # Spawned via `RbConfig.ruby`, never a bare "ruby" -- the shell's default is
  # 3.2.3 and could not load this build's extension at all. A non-zero exit
  # raises rather than skips: a subprocess that could not run is a broken spec,
  # not an absent capability.
  def run_seam_in_subprocess(path)
    lib = File.expand_path("../../../lib", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", lib,
      "-r", File.expand_path("../../bootsnap_setup", __dir__),
      "-r", "lain",
      "-e", seam_script, path
    )
    raise "subprocess failed (status #{status.exitstatus}): #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "lets no ANSI escape reach the Journal from a subscriber the writing process installed" do
    Dir.mktmpdir("lain-seam-ansi") do |dir|
      path = File.join(dir, "session.ndjson")
      installed = run_seam_in_subprocess(path).fetch("installed")

      contents = File.read(path)
      # Parsed the way every real reader parses (Journal.parse skips a foreign
      # line rather than raising), so a torn line cannot mask itself as an
      # exception before `be_valid_ndjson` gets to name it.
      records = contents.each_line.filter_map { |line| Lain::Journal.parse(line) }

      expect(installed).to be(true)
      # Non-vacuity: the file below is one a Rust span actually wrote into.
      expect(records.select { |r| r.values_at("subject", "message").compact.any? }).not_to be_empty
      # A tripwire, and worth being honest about its reach: on today's JSON
      # path it cannot fire even with `ansi` re-enabled, because the Json
      # formatter never consults the flag and serde_json would escape a stray
      # ESC to  regardless. The guards that actually hold the property are
      # the dropped `ansi` feature (ext/lain/Cargo.toml), the `nu-ansi-term` ban
      # (deny.toml) and `.with_ansi(false)`. What this line catches is the day
      # someone reaches for a non-JSON formatter -- measured, not assumed: that
      # build put 24 ESC bytes into this file, mid-stream, between two good
      # Journal lines.
      expect(contents).not_to include("\e")
      expect(contents).to be_valid_ndjson
    end
  end
end
