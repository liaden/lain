# frozen_string_literal: true

require "json"
require "tmpdir"

require "lain/lain" # the compiled Rust extension: Lain.hello, Lain::Ext.init_tracing

# The seam the lead tests: Ruby Journal events and Rust `tracing` spans land in
# ONE ordered NDJSON file, and every line parses independently. The Journal owns
# the fd; Rust `dup`s it (so closing one never closes the other) and writes whole
# lines under its own mutex, the mirror of the Journal's whole-line write. If the
# two disciplines hold, the merged stream parses line by line.
RSpec.describe "Journal x Rust tracing seam" do
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

      # When this process installed the subscriber, the Rust spans are here too,
      # interleaved as their own JSON lines. (A prior install in the same process
      # would route them elsewhere; the line-by-line invariant still holds.)
      if installed
        rust_lines = records.select { |r| r.values_at("subject", "message").compact.any? }
        expect(rust_lines).not_to be_empty
      else
        RSpec.configuration.reporter.message(
          "tracing subscriber already installed this process; skipping Rust-line assertion"
        )
      end
    end
  end
end
