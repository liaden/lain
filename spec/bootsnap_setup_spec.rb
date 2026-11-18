# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "spec/bootsnap_setup.rb" do
  let(:repo) { File.expand_path("..", __dir__) }
  let(:cache) { Dir.mktmpdir("lain-bootsnap-spec-cache-") }
  let(:baseline_cache) { Dir.mktmpdir("lain-bootsnap-spec-baseline-") }
  let(:scratch) { Dir.mktmpdir("lain-bootsnap-spec-src-") }

  after do
    FileUtils.remove_entry(cache, true)
    FileUtils.remove_entry(baseline_cache, true)
    FileUtils.remove_entry(scratch, true)
  end

  def boot_requiring(path, cache_dir: cache, env: {})
    out, status = Open3.capture2e(
      { "LAIN_BOOTSNAP_CACHE" => cache_dir }.merge(env), RbConfig.ruby, "-r", File.join(repo, "spec/bootsnap_setup.rb"),
      "-e", "require ARGV.first if ARGV.first; puts :ran", *path
    )
    raise "child failed: #{out}" unless status.success?

    out
  end

  def count_in(dir) = Dir.glob(File.join(dir, "bootsnap/compile-cache-iseq/**/*")).count { File.file?(_1) }

  # Booting bootsnap itself caches gem sources, so a count means something only against a boot that requires nothing.
  def cached_beyond_boot
    boot_requiring(nil, cache_dir: baseline_cache)
    count_in(cache) - count_in(baseline_cache)
  end

  def write_source(dir)
    File.join(dir, "probe_source.rb").tap { File.write(_1, "puts :probe_loaded\n") }
  end

  it "compiles a source outside the repo without a cache entry" do
    out = boot_requiring(write_source(scratch))

    expect([out.include?("probe_loaded"), cached_beyond_boot]).to eq([true, 0])
  end

  it "still caches a source under the repo" do
    boot_requiring(File.join(repo, "lib/lain/chores.rb"))

    expect(cached_beyond_boot).to eq(1)
  end

  it "still caches a stdlib source the boot itself does not load" do
    boot_requiring("shellwords")

    expect(cached_beyond_boot).to be >= 1
  end

  it "caches a source under a gem path that is not under the ruby prefix" do
    gem_home = File.join(scratch, "gems")
    FileUtils.mkdir_p(File.join(gem_home, "gems/probe-1/lib"))
    source = write_source(File.join(gem_home, "gems/probe-1/lib"))
    boot_requiring(source, env: { "GEM_PATH" => [gem_home, *Gem.path].join(File::PATH_SEPARATOR) })

    expect(cached_beyond_boot).to eq(1)
  end

  it "compiles a source in a sibling directory sharing the repo's name prefix without a cache entry" do
    sibling = "#{repo}-sibling"
    FileUtils.mkdir_p(sibling)
    boot_requiring(write_source(sibling))

    expect(cached_beyond_boot).to eq(0)
  ensure
    FileUtils.remove_entry(sibling, true)
  end

  it "compiles a source under the repo's tmp without a cache entry" do
    Dir.mktmpdir("lain-bootsnap-spec-", File.join(repo, "tmp")) do |dir|
      boot_requiring(write_source(dir))
    end

    expect(cached_beyond_boot).to eq(0)
  end
end
