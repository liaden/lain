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
    pinned = Regexp.escape(File.read(File.join(repo, ".ruby-version")).strip.delete_prefix("ruby-"))

    expect([File.executable?(script),
            body]).to match([true, /mise env.*#{pinned}.*LD_LIBRARY_PATH.*rake compile.*rake pspec/m])
  end

  it "ships an executable bin/dogfood-setup that links .lain and prints the trust command" do
    script = File.join(repo, "bin/dogfood-setup")
    body = File.read(script)

    expect([File.executable?(script), body]).to match([true, %r{ln -s.*dogfood/lain.*lain trust}m])
  end

  it "explains in docs/devs/dogfood.md why .lain stays ignored" do
    expect(File.read(File.join(repo, "docs/devs/dogfood.md"))).to match(/\.lain.*ignored/m)
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

    it "links .lain, excludes it and prints the trust command in a checkout with a .git directory", :seam do
      # The scrub guard reads the constant at the call site.
      system(env.merge(SeedRepo::SCRUB), "git", "init", "-q", tree, unsetenv_others: true, exception: true)
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

  describe "the conventions slots rendered over the dogfood tree" do
    def render_over_dogfood(skill)
      Dir.mktmpdir do |root|
        File.symlink(File.join(repo, "dogfood/lain"), File.join(root, ".lain"))
        Lain::Skill::Library.load(root:,
                                  locals: { epic_home: "/state/lain/epics/test",
                                            gate_window: 900,
                                            provider_width: "runs 3 requests at once, so spawn " \
                                                            "at most 3 researchers at a time",
                                            researcher_limits: "60 iterations and a 16384-byte answer" })
                            .renderer.render(skill)
      end
    end

    it "gives execute-plan this repo's commit, suite and comment traps and the Ruby panel" do
      rendered = render_over_dogfood("execute-plan")

      expect(rendered).to include("leaf first", "same commit", "stashes unstaged tracked changes", "untracked",
                                  "suite.lock", "LAIN_SPEC_WORKERS", "WHY", "Linus Torvalds", "Aaron Patterson")
    end

    %w[research-epic plan-epic create-epic-issues iterate-epic].each do |skill|
      it "keeps #{skill}'s conventions deferring to this repo's CLAUDE.md and the design plan" do
        rendered = render_over_dogfood(skill)

        expect(rendered).to include("CLAUDE.md", "design plan", "commit-grouping")
      end
    end

    it "gives create-plan the Ruby panel and the planning conventions" do
      rendered = render_over_dogfood("create-plan")

      expect(rendered).to include("Sandi Metz", "planning/", "commit-mode", "same commit", "$stdout")
    end
  end

  describe "the skills in the dogfood tree" do
    it "lists implement-careful with a model while the shipped implement has none" do
      Dir.mktmpdir do |root|
        File.symlink(File.join(repo, "dogfood/lain"), File.join(root, ".lain"))
        catalog = Lain::Skill::Catalog.load(root:)

        expect([catalog.fetch(:"implement-careful").model, catalog.fetch(:implement).model.to_s])
          .to eq(["opus", ""])
      end
    end
  end

  it "names the real skill and slot paths in the configuration doc" do
    readme = File.read(File.join(repo, "docs/users/configuration.md"))

    expect(readme).to include(".lain/skills/<name>/skill.md", ".lain/slots/skill/<skill>/<hole>.md")
  end
end
