# frozen_string_literal: true

RSpec.describe "the dogfood config tree" do
  let(:repo) { File.expand_path("../..", __dir__) }
  let(:path) { File.join(repo, "dogfood/lain/config.rb") }
  let(:built) { Lain::Config::Builder.evaluate(File.read(path), path:) }

  it "names bin/verify as the verifier with room for a full suite" do
    expect([built.isolation.verify, built.isolation.verify_timeout >= 900]).to eq([["bin/verify"], true])
  end

  it "passes no environment names through and allows bin/verify in bash" do
    expect([built.env_pass, built.approval.allow])
      .to eq([[], [{ "tool" => "bash", "input" => { "command" => "bin/verify" } }]])
  end

  it "ships an executable bin/verify that runs the toolchain, compile, then pspec" do
    script = File.join(repo, "bin/verify")
    body = File.read(script)

    expect([File.executable?(script),
            body]).to match([true, /mise env.*4\.0\.6.*LD_LIBRARY_PATH.*rake compile.*rake pspec/m])
  end

  it "ships an executable bin/dogfood-setup that links .lain and prints the trust command" do
    script = File.join(repo, "bin/dogfood-setup")
    body = File.read(script)

    expect([File.executable?(script), body]).to match([true, %r{ln -s.*dogfood/lain.*lain trust}m])
  end

  it "explains in docs/dogfood.md why .lain stays ignored" do
    expect(File.read(File.join(repo, "docs/dogfood.md"))).to match(/\.lain.*ignored/m)
  end

  describe "bin/dogfood-setup run in a copy of the tree" do
    let(:tree) { Dir.mktmpdir("dogfood-setup") }
    let(:env) { ENV.to_h.reject { |name, _| name.start_with?("GIT_") }.merge("GIT_CONFIG_GLOBAL" => "/dev/null") }

    before do
      FileUtils.mkdir_p([File.join(tree, "bin"), File.join(tree, "dogfood/lain")])
      FileUtils.cp(File.join(repo, "bin/dogfood-setup"), File.join(tree, "bin"))
    end

    after { FileUtils.rm_rf(tree) }

    def setup_script = Open3.capture3(env, File.join(tree, "bin/dogfood-setup"), unsetenv_others: true)

    it "links .lain, excludes it and prints the trust command in a checkout with a .git directory" do
      system(env, "git", "init", "-q", tree, exception: true)
      out, _err, status = setup_script
      exclude = File.read(File.join(tree, ".git/info/exclude"))

      expect([status.exitstatus, File.readlink(File.join(tree, ".lain")), exclude, out])
        .to match([0, "dogfood/lain", %r{^/\.lain$}, /lain trust/])
    end

    it "exits 1 and keeps what is there when .lain already exists" do
      FileUtils.mkdir_p(File.join(tree, ".lain"))
      _out, _err, status = setup_script

      expect([status.exitstatus, File.symlink?(File.join(tree, ".lain"))]).to eq([1, false])
    end

    it "links nothing and exits 0 when .git is a file, naming the main checkout" do
      File.write(File.join(tree, ".git"), "gitdir: /elsewhere/.git/worktrees/x\n")
      out, _err, status = setup_script

      expect([status.exitstatus, File.exist?(File.join(tree, ".lain")), out]).to match([0, false, /main checkout/])
    end
  end
end
