# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"

# T23: /meta generates a customized harness script from a prompt and, ONLY on an
# explicit `/meta run <slug>`, launches it in a tmux window. Generation writes a
# reviewable file and NEVER executes generated code -- the generate/run split is
# the safety line, so these specs pin that a bare /meta opens no window and runs
# no ruby, and that only the run verb reaches TmuxSurface.
RSpec.describe Lain::CLI::Command::Meta do
  subject(:meta) { described_class.new(root:) }

  let(:root) { Dir.mktmpdir("lain-meta") }

  after { FileUtils.remove_entry(root) }

  let(:head) { "blake3:#{"ab12" * 16}" }
  let(:timeline) { instance_double(Lain::Timeline, head_digest: head) }
  let(:agent) { instance_double(Lain::Agent, timeline:) }
  let(:body) { "PlannerExecutor = Object.new\n" }
  let(:role_spawn) do
    spawn = instance_double(Lain::Skill::RoleSpawn)
    allow(spawn).to receive(:call).and_return(Lain::Tool::Result.ok(body))
    spawn
  end
  let(:placement) do
    Lain::CLI::TmuxSurface::Placement.new(kind: :window, target: "meta-x", degraded: false, reason: nil)
  end
  let(:tmux_surface) do
    surface = instance_double(Lain::CLI::TmuxSurface)
    allow(surface).to receive(:window).and_return(placement)
    surface
  end
  let(:env) { instance_double(Lain::CLI::Command::Env, role_spawn:, agent:, tmux_surface:) }

  def scripts = Dir[File.join(root, ".lain", "meta", "*.rb")]

  it "registers as /meta with a one-line usage" do
    expect(meta.name).to eq("meta")
    expect(meta.usage).to start_with("/meta")
  end

  describe "generate, review, launch -- never auto-run" do
    let(:prompt) { "try a planner-executor split on this task" }

    it "spawns the meta_harness role with :inherit context and the caller's prompt" do
      meta.call(prompt, env)

      expect(role_spawn).to have_received(:call).with(:meta_harness, :inherit, prompt)
    end

    it "writes exactly one .lain/meta/<slug>.rb script under the project root" do
      meta.call(prompt, env)

      expect(scripts.size).to eq(1)
    end

    it "prints the path and a summary naming the /meta run launch verb -- and never touches stdout" do
      text = nil
      expect { text = meta.call(prompt, env) }.not_to output.to_stdout

      expect(text).to include(scripts.first)
      expect(text).to match(%r{/meta run })
    end

    it "NEVER executes generated code: it opens no tmux window and runs no ruby" do
      meta.call(prompt, env)

      expect(tmux_surface).not_to have_received(:window)
    end

    describe "the generated script is honest" do
      before { meta.call(prompt, env) }

      let(:contents) { File.read(scripts.first) }

      it "requires lain" do
        expect(contents).to include('require "lain"')
      end

      it "carries a header naming its origin prompt and the head digest it was generated at" do
        expect(contents).to include(prompt)
        expect(contents).to include(head)
      end

      it "embeds the role's assembled body verbatim" do
        expect(contents).to include(body.strip)
      end

      it "is itself syntactically valid ruby" do
        _out, status = Open3.capture2e(RbConfig.ruby, "-c", scripts.first)
        expect(status).to be_success
      end
    end

    describe "a multi-line origin prompt" do
      let(:prompt) { "line one\nline two" }

      it "keeps the whole prompt in the header without breaking script syntax" do
        meta.call(prompt, env)
        contents = File.read(scripts.first)

        expect(contents).to include("line one")
        expect(contents).to include("line two")
        _out, status = Open3.capture2e(RbConfig.ruby, "-c", scripts.first)
        expect(status).to be_success
      end
    end

    describe "when the role spawn fails" do
      let(:role_spawn) do
        spawn = instance_double(Lain::Skill::RoleSpawn)
        allow(spawn).to receive(:call).and_return(Lain::Tool::Result.error("no harness for you"))
        spawn
      end

      it "reports the failure and writes no script" do
        text = meta.call(prompt, env)

        expect(scripts).to be_empty
        expect(text).to match(/no harness for you/)
      end
    end

    describe "an empty prompt" do
      it "refuses with usage instead of spawning a role" do
        text = meta.call("", env)

        expect(role_spawn).not_to have_received(:call)
        expect(text).to start_with("/meta")
        expect(scripts).to be_empty
      end
    end
  end

  describe "/meta run <slug> launches -- and only run launches" do
    let(:slug) { "planner-executor" }
    let(:script_path) { File.join(root, ".lain", "meta", "#{slug}.rb") }

    before do
      FileUtils.mkdir_p(File.dirname(script_path))
      File.write(script_path, "# a previously generated harness\n")
    end

    it "opens a new tmux window running the generated script, rooted at the project" do
      meta.call("run #{slug}", env)

      expect(tmux_surface).to have_received(:window)
        .with(command: a_string_including(script_path), name: "meta-#{slug}", cwd: root)
    end

    it "does not regenerate: run launches an existing script, it never re-spawns the role" do
      meta.call("run #{slug}", env)

      expect(role_spawn).not_to have_received(:call)
    end

    it "returns text naming the launched window -- and never touches stdout" do
      text = nil
      expect { text = meta.call("run #{slug}", env) }.not_to output.to_stdout

      expect(text).to include(slug)
    end

    describe "a slug that names no generated script" do
      it "refuses honestly instead of launching anything" do
        text = meta.call("run ghost", env)

        expect(tmux_surface).not_to have_received(:window)
        expect(text).to match(/ghost/)
        expect(text).to match(/no.*script|not found|has not been generated/i)
      end
    end

    describe "a traversal slug (path escapes the artifact home)" do
      it "refuses on the charset, never resolving a file outside .lain/meta" do
        outside = File.join(root, "outside.rb")
        File.write(outside, "# a real .rb OUTSIDE .lain/meta\n")

        text = meta.call("run ../outside", env)

        expect(tmux_surface).not_to have_received(:window)
        expect(text).to match(/not a valid script name/)
      end
    end

    describe "tmux unavailable at launch time" do
      it "degrades to the runnable command instead of failing" do
        allow(tmux_surface).to receive(:window)
          .and_raise(Lain::CLI::TmuxSurface::TmuxUnavailable, "tmux not found on PATH")

        text = meta.call("run #{slug}", env)

        expect(text).to include(script_path)
        expect(text).to include("tmux not found on PATH")
      end
    end
  end

  # The honesty guarantee, checked against the SHIPPED skeleton the role is told
  # to follow (we cannot run a real provider here): the example the model sees
  # must itself be a valid, loadable lain script, or /meta ships a lie.
  describe "the shipped meta-harness template skeleton" do
    let(:template) { Lain::Prompt::Slots.shipped_role_templates.fetch("meta-harness") }
    let(:skeleton) { template[/```ruby\n(.*?)\n```/m, 1] }

    it "embeds a ruby skeleton script" do
      expect(skeleton).not_to be_nil
    end

    it "requires lain" do
      expect(skeleton).to include('require "lain"')
    end

    it "passes ruby -c (syntax)" do
      out, status = Open3.capture2e(RbConfig.ruby, "-c", "-e", skeleton)

      expect(status).to be_success, out
    end

    it "names only constants that resolve under require 'lain' (a load check, separately)" do
      constants = skeleton.scan(/Lain(?:::[A-Z][A-Za-z0-9_]*)+/).uniq

      expect(constants).not_to be_empty
      aggregate_failures do
        constants.each do |const|
          expect { Object.const_get(const) }.not_to raise_error
        end
      end
    end
  end
end
