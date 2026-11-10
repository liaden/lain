# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Each launch is a fresh Ruby, because a hit rewrites $LOAD_PATH and the gem specs of the
# process it runs in. The fixture bundle holds only thor, so a launch costs a fifth of a second.
RSpec.describe Lain::Boot::FrozenLoadPath, :seam do
  let(:root) { Dir.mktmpdir("lain-frozen-load-path") }
  let(:project_name) { "project" }
  let(:project) { File.join(root, project_name).tap { FileUtils.mkdir_p(_1) } }
  let(:gemfile) { File.join(project, "Gemfile") }
  let(:gem_home) { File.join(root, "gems") }
  let(:cache_dir) { File.join(root, "cache") }
  let(:source) { File.expand_path("../../../lib/lain/boot/frozen_load_path.rb", __dir__) }

  let(:probe) do
    <<~RUBY
      require ARGV[0]
      hit = Lain::Boot::FrozenLoadPath.setup(gemfile: ARGV[1], cache_dir: ARGV[2])
      require "thor"
      seen = { hit:, bundler: defined?(Bundler::SharedHelpers), env: ENV.to_h,
               thor: $LOADED_FEATURES.grep(%r{/thor-[^/]+/lib/thor[.]rb\\z}), gem_paths: [Gem.paths.home, Gem.paths.path] }
      require "json"
      File.write(ARGV[3], JSON.generate(seen))
    RUBY
  end

  after { FileUtils.remove_entry(root) }

  # The runner's own bundle reaches a child through these names, and would stand in for the fixture's.
  # Without checksums, because a bundler whose installed gem carries none rewrites an unchanged
  # Gemfile.lock on every resolve, which moves the key.
  def child_env(**extra)
    ENV.keys.grep(/\ABUNDLER?_/).to_h { [_1, nil] }
       .merge("RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_LOCKFILE_CHECKSUMS" => "false", "GEM_HOME" => gem_home,
              "GEM_PATH" => [gem_home, *Gem.path].join(File::PATH_SEPARATOR), **extra)
  end

  def launch(cache: cache_dir, **env)
    record = File.join(root, "record")
    out = IO.popen(child_env(**env), [RbConfig.ruby, "-e", probe, source, gemfile, cache, record],
                   chdir: project, err: %i[child out], &:read)
    raise "the launch failed: #{out}" unless $CHILD_STATUS.success?

    JSON.parse(File.read(record), symbolize_names: true)
  end

  # The key a launch in child_env computes, which differs from this runner's.
  def child_key
    IO.popen(child_env, [RbConfig.ruby, "-e", "require ARGV[0]; print Lain::Boot::FrozenLoadPath.send(:key, ARGV[1])",
                         source, gemfile], chdir: project, &:read)
  end

  def cached_files = Dir.glob(File.join(cache_dir, "*.rb"))

  # Bundler writes Gemfile.lock on the first resolve.
  before do
    File.write(gemfile, %(source "https://rubygems.org"\ngem "thor"\n))
    launch(cache: File.join(root, "prime"))
  end

  it "loads the cached load path on a second launch, without Bundler, exporting what Bundler exported" do
    first = launch
    second = launch

    expect([first[:hit], first[:bundler], second[:hit], second[:bundler]]).to eq([false, "constant", true, nil])
    expect(second.values_at(:env, :thor, :gem_paths)).to eq(first.values_at(:env, :thor, :gem_paths))
  end

  it "runs Bundler again and writes a new cache when Gemfile.lock's mtime changes" do
    launch
    later = File.mtime("#{gemfile}.lock") + 10
    File.utime(later, later, "#{gemfile}.lock")

    expect([launch[:bundler], cached_files.size, launch[:hit]]).to eq(["constant", 2, true])
  end

  it "runs Bundler again and writes a new cache when a gem is installed into Gem.dir" do
    launch
    specifications = File.join(gem_home, "specifications")
    FileUtils.mkdir_p(specifications)
    fake = Gem::Specification.new do |spec|
      spec.name = "fake"
      spec.version = "1.0"
      spec.summary = "fake"
    end
    File.write(File.join(specifications, "fake-1.0.gemspec"), fake.to_ruby)

    expect([launch[:bundler], cached_files.size, launch[:hit]]).to eq(["constant", 2, true])
  end

  it "recovers from a cached load path naming a gem directory that no longer exists" do
    thor_dir = File.dirname(launch[:thor].first)
    cached = cached_files.first
    File.write(cached, File.read(cached).gsub(thor_dir, File.join(root, "uninstalled", "lib")))

    recovered = launch

    expect([recovered[:hit], recovered[:bundler], recovered[:thor].size]).to eq([false, "constant", 1])
    expect([File.read(cached).include?("uninstalled"), launch[:hit]]).to eq([false, true])
  end

  it "runs Bundler again when a variable Bundler reads differs, and exports the new value" do
    launch("PATH" => "#{root}/one:#{ENV.fetch("PATH")}")
    other = launch("PATH" => "#{root}/two:#{ENV.fetch("PATH")}")

    seen = [other[:bundler], other[:env][:PATH].include?("#{root}/two"), cached_files.size]

    expect(seen).to eq(["constant", true, 2])
  end

  it "treats an empty cache file as a miss and rewrites it" do
    launch
    File.write(cached_files.first, "")

    expect([launch[:bundler], File.size(cached_files.first).positive?, launch[:hit]]).to eq(["constant", true, true])
  end

  it "treats a cache file cut short as a miss and rewrites it" do
    launch
    text = File.read(cached_files.first)
    File.write(cached_files.first, text[0, text.size / 2])

    expect([launch[:bundler], File.read(cached_files.first), launch[:hit]]).to eq(["constant", text, true])
  end

  it "leaves no scratch file behind when the cache cannot be renamed into place" do
    FileUtils.mkdir_p(File.join(cache_dir, "#{child_key}.rb", "occupied"))

    expect([launch[:bundler], Dir.glob(File.join(cache_dir, "*.rb.*"))]).to eq(["constant", []])
  end

  context "with a checkout path that holds glob characters" do
    let(:project_name) { "p[1]oject" }

    it "runs Bundler again when a gemspec beside the Gemfile changes" do
      gemspec = File.join(project, "extra.gemspec")
      File.write(gemspec, "")
      launch
      later = File.mtime(gemspec) + 10
      File.utime(later, later, gemspec)

      expect(launch[:bundler]).to eq("constant")
    end
  end

  # BUNDLE_PATH is the bundle whose GEM_HOME differs from the one RubyGems booted with.
  context "with a BUNDLE_PATH bundle" do
    let(:vendor) { File.join(root, "vendor") }

    def vendor_thor
      thor = Gem::Specification.find_by_name("thor")
      home = File.join(vendor, "ruby", RbConfig::CONFIG["ruby_version"])
      FileUtils.mkdir_p([File.join(home, "gems"), File.join(home, "specifications")])
      FileUtils.cp_r(thor.full_gem_path, File.join(home, "gems"))
      FileUtils.cp(thor.loaded_from, File.join(home, "specifications"))
      home
    end

    it "hands children the bundle's gem paths on a hit" do
      home = vendor_thor
      first = launch("BUNDLE_PATH" => vendor)
      second = launch("BUNDLE_PATH" => vendor)

      expect([first[:gem_paths][0], second[:hit], second[:gem_paths]]).to eq([home, true, first[:gem_paths]])
    end
  end

  it "still launches through Bundler when the cache cannot be written" do
    blocker = File.join(root, "blocker")
    File.write(blocker, "")

    expect(launch(cache: File.join(blocker, "cache")).values_at(:hit, :bundler)).to eq([false, "constant"])
  end

  it "leaves the load path of a process Bundler already set up alone, even beside its cache file" do
    cache = File.join(cache_dir, "#{described_class.send(:key, gemfile)}.rb")
    FileUtils.mkdir_p(cache_dir)
    File.write(cache, %(raise "the cache was replayed over a running Bundler"))
    before = $LOAD_PATH.dup

    expect([described_class.setup(gemfile:, cache_dir:), $LOAD_PATH]).to eq([false, before])
  end
end
