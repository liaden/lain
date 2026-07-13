# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

require "lain/bench/session"
require "lain/canonical"

# CE-3: `Canonical`'s second invariant -- prompt-cache stability -- has never
# had a test. This is that test: render the same committed fixture once IN
# this process and once in a FRESH ruby process, and assert the canonical
# Request bytes and prefix_digests come out identical. A silent invalidator
# (`Time.now`, an unsorted key, any per-process value) would pass every other
# spec in the suite -- they all run in ONE process, where an accidental
# constant looks deterministic. Only a second process exposes it.
#
# The subprocess is spawned via `RbConfig.ruby`, never a bare "ruby" -- the
# shell's default ruby is 3.2.3 (see CLAUDE.md), and version skew would
# present exactly like the nondeterminism leak this spec exists to catch.
RSpec.describe "the byte-identical prelude invariant across processes (CE-3)" do
  def fixture_path
    File.expand_path("../../fixtures/sessions/variance/one.ndjson", __dir__)
  end

  # The render path under test: load the committed fixture's Recording and
  # render its Context over its own recorded Timeline/Toolset/Workspace --
  # exactly what a bench replay does, with no test-only shortcut.
  def render_script
    <<~RUBY
      require "json"

      recording = Lain::Bench::Session.load(ARGV.fetch(0))
      request = recording.context.render(
        timeline: recording.timeline, toolset: recording.toolset, workspace: recording.workspace
      )

      puts JSON.generate(
        "bytes" => Lain::Canonical.dump(request.cache_payload),
        "digest" => request.digest,
        "prefix_digests" => request.prefix_digests
      )
    RUBY
  end

  # Spawns a FRESH ruby process (via RbConfig.ruby -- see the file comment)
  # that requires nothing but the lib/ path this process already trusts, and
  # renders the same fixture the same way. Returns the parsed JSON the
  # subprocess printed.
  def render_in_subprocess(path)
    lib = File.expand_path("../../../lib", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", lib, "-r", "lain/bench/session", "-r", "lain/canonical",
      "-e", render_script, path
    )
    raise "subprocess failed (status #{status.exitstatus}): #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  it "renders byte-identical canonical bytes and equal prefix_digests in a fresh process" do
    recording = Lain::Bench::Session.load(fixture_path)
    request = recording.context.render(
      timeline: recording.timeline, toolset: recording.toolset, workspace: recording.workspace
    )

    subprocess = render_in_subprocess(fixture_path)

    expect(subprocess["digest"]).to eq(request.digest)
    expect(subprocess["bytes"]).to eq(Lain::Canonical.dump(request.cache_payload))
    expect(subprocess["prefix_digests"]).to eq(request.prefix_digests)
  end
end
