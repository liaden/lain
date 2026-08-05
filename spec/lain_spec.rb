# frozen_string_literal: true

RSpec.describe Lain do
  it "has a version number" do
    expect(Lain::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  # Proves the magnus FFI boundary is wired and `rake compile` produced a loadable
  # extension. Until the Timeline lands in Rust, this is the only thing crossing it.
  describe ".hello" do
    it "round-trips a string through the Rust extension" do
      expect(described_class.hello("lain")).to eq("Hello from Rust, lain!")
    end
  end
end

# The first-run failure, and the only way to see it: `lain` is already loaded in
# THIS process, so nothing in-process can exercise the rescue. A subprocess with
# a load path holding lain's Ruby but NOT its compiled artifact reproduces a
# fresh clone exactly -- which is where it was reported from, on macOS,
# 2026-08-05, against `./exe/lain` and `bundle exec exe/lain --help` alike.
#
# The artifact is gitignored (`*.so`, 47MB), so this is the state every clone,
# every `git worktree` and every new machine starts in. Ruby's own message for
# it is `cannot load such file -- lain/lain`, which names an internal path and
# suggests nothing.
RSpec.describe "lain.rb without the compiled extension", :seam do
  # A load path that is lain's `lib/` minus the artifact. Symlinked per entry
  # rather than copied: the real `lib/` holds a 47MB `.so` and copying it for
  # each run is the whole cost of this example.
  def lib_without_extension
    real = File.expand_path("../lib", __dir__)
    Dir.mktmpdir("lain-no-ext") { |dir| yield mirrored(real, dir) }
  end

  # `lain/` is rebuilt entry by entry so the artifact can be left out; every
  # other child of `lib/` is one symlink, since only that directory holds one.
  def mirrored(real, dir)
    link_children(real, dir) { |entry| entry != "lain" }
    FileUtils.mkdir_p(File.join(dir, "lain"))
    link_children(File.join(real, "lain"), File.join(dir, "lain")) { |entry| !entry.match?(/\.(so|bundle|dll)\z/) }
    dir
  end

  def link_children(from, to, &keep)
    Dir.children(from).select(&keep).each { |entry| FileUtils.ln_s(File.join(from, entry), File.join(to, entry)) }
  end

  def require_lain_from(dir)
    IO.popen({ "RUBYOPT" => nil, "BUNDLER_SETUP" => nil },
             [RbConfig.ruby, "-I#{dir}", "-e", 'require "lain"'],
             err: %i[child out], &:read)
  end

  it "says the extension is unbuilt and how to build it, not `cannot load such file`" do
    output = lib_without_extension { |dir| require_lain_from(dir) }

    expect(output).to include("compiled Rust extension is not built")
      .and include("rake compile")
    expect($CHILD_STATUS).not_to be_success
  end

  # The counter-example that keeps the rescue honest: swallowing Ruby's own
  # message would lose the path that says WHICH require failed, and a second
  # unbuilt extension later would then be indistinguishable from this one.
  it "keeps Ruby's own LoadError message rather than replacing it" do
    output = lib_without_extension { |dir| require_lain_from(dir) }

    expect(output).to include("cannot load such file -- lain/lain")
  end
end
