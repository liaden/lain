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

  after { FileUtils.remove_entry(root) }

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
      expect(text).to include("/meta run ")
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

    # Unfencing repairs the harness path too: meta-harness.md asks for a fenced
    # block, and a written-through fence made the script unparseable.
    describe "a fenced body" do
      let(:body) { "```ruby\nPlannerExecutor = Object.new\n```\n" }

      it "writes the script without the fence, and it parses" do
        meta.call(prompt, env)
        contents = File.read(scripts.first)

        expect(contents).not_to include("```")
        expect(contents).to include("PlannerExecutor = Object.new")
        _out, status = Open3.capture2e(RbConfig.ruby, "-c", scripts.first)
        expect(status).to be_success
      end
    end

    describe "a prompt that slugifies to nothing" do
      it "falls back to the harness's own name" do
        meta.call("!!!", env)

        expect(scripts.map { |path| File.basename(path) }).to eq(["harness.rb"])
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
        expect(text).to include("no harness for you")
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

  # A4: the SAME generate-then-review discipline, aimed at a summarizer
  # declaration instead of a harness script. The declaration is data for
  # {Lain::Summarizer::Builder} to load after a human has read it -- never a
  # script, and never reachable from the run verb.
  describe "/meta summarizer <prompt> writes a reviewable declaration" do
    let(:prompt) { "collapse coverage reports" }
    let(:body) do
      <<~RUBY
        summarizer "coverage" do
          def suitable?(result) = result.tool_name == "bash"

          def compact(result) = result.text.lines.first.to_s
        end
      RUBY
    end

    def declarations = Dir[File.join(root, ".lain", "summarizers", "*.rb")]

    it "spawns the read-only meta_summarizer role with :inherit context and the caller's prompt" do
      meta.call("summarizer #{prompt}", env)

      expect(role_spawn).to have_received(:call).with(:meta_summarizer, :inherit, prompt)
    end

    it "writes exactly one .lain/summarizers/<slug>.rb under the project root" do
      meta.call("summarizer #{prompt}", env)

      expect(declarations.size).to eq(1)
    end

    it "NEVER executes what it wrote: it opens no tmux window and writes no runnable script" do
      meta.call("summarizer #{prompt}", env)

      expect(tmux_surface).not_to have_received(:window)
      expect(scripts).to be_empty
    end

    it "returns the path and tells the human to review it -- and never touches stdout" do
      text = nil
      expect { text = meta.call("summarizer #{prompt}", env) }.not_to output.to_stdout

      expect(text).to include(declarations.first)
      expect(text).to match(/review/i)
    end

    describe "the written declaration" do
      before { meta.call("summarizer #{prompt}", env) }

      let(:path) { declarations.first }
      let(:contents) { File.read(path) }

      it "carries the GENERATED review header" do
        expect(contents).to include("GENERATED by /meta")
        expect(contents).to include("REVIEW")
      end

      it "names its origin prompt and the session's head digest" do
        expect(contents).to include(prompt)
        expect(contents).to include(head)
      end

      # `.lain/summarizers/` is a directory NOTHING reads -- the catalog loads
      # the single file `.lain/summarizers.rb`. Ruby's own `foo.rb` + `foo/`
      # convention says the opposite, so the file has to say it outright.
      it "says outright that nothing loads the directory it was written to" do
        expect(contents).to include("NOTHING loads this directory")
        expect(contents).to include(".lain/summarizers.rb")
      end

      # The AC's "exactly one Summarizer::Base subclass", asserted in the terms
      # A2 can actually consume: the DSL verb builds one anonymous Base subclass
      # per declaration, so loading the file through the real Builder is what
      # says "exactly one", and it says it about a file A2 can load.
      it "defines exactly one Summarizer::Base subclass, loadable by the real Builder" do
        built = Lain::Summarizer::Builder.build(contents, path)

        expect(built.size).to eq(1)
        expect(built.first).to be_a(Lain::Summarizer::Base)
        expect(built.first.class.superclass).to eq(Lain::Summarizer::Base)
      end

      it "is itself syntactically valid ruby" do
        _out, status = Open3.capture2e(RbConfig.ruby, "-c", path)

        expect(status).to be_success
      end
    end

    # The shipped role template asks for "one fenced `ruby` code block", and
    # models answer with one. Written through, the fence makes every generated
    # file a SyntaxError -- which for a declaration means the Builder cannot
    # load it at all, i.e. the verb's whole value. Promoted from the review's
    # probe-generated-loadability.rb.
    describe "a fenced body, which is what the shipped template asks the role for" do
      let(:declaration) do
        <<~RUBY
          summarizer "coverage" do
            def suitable?(result) = result.tool_name == "bash"

            def compact(result) = result.text.lines.first.to_s
          end
        RUBY
      end

      {
        "a bare fence" => ->(decl) { "```\n#{decl}```\n" },
        "a ruby-tagged fence" => ->(decl) { "```ruby\n#{decl}```\n" },
        "a fence wrapped in prose" => ->(decl) { "Here you go:\n\n```ruby\n#{decl}```\n\nWire it in." }
      }.each do |shape, wrap|
        describe shape do
          let(:body) { wrap.call(declaration) }

          it "writes a file the real Builder loads into exactly one summarizer" do
            meta.call("summarizer #{prompt}", env)
            path = declarations.first

            built = Lain::Summarizer::Builder.build(File.read(path), path)

            expect(built.size).to eq(1)
            expect(built.first.class.superclass).to eq(Lain::Summarizer::Base)
          end

          it "keeps neither the fence nor the prose around it" do
            meta.call("summarizer #{prompt}", env)
            contents = File.read(declarations.first)

            expect(contents).not_to include("```")
            expect(contents).not_to include("Wire it in.")
            _out, status = Open3.capture2e(RbConfig.ruby, "-c", declarations.first)
            expect(status).to be_success
          end
        end
      end
    end

    # The fallback slug belongs to the artifact: a summarizer prompt that
    # reduces to nothing must not land on the harness's name.
    describe "a prompt that slugifies to nothing" do
      it "falls back to the summarizer's own name, never the harness's" do
        meta.call("summarizer !!!", env)

        expect(declarations.map { |path| File.basename(path) }).to eq(["summarizer.rb"])
      end
    end

    # The escalation line: a summarizer is loaded by the catalog after review,
    # never launched. It lands outside `.lain/meta/`, so the run verb cannot
    # resolve it even when the human types its slug back.
    it "is not reachable from the run verb" do
      meta.call("summarizer #{prompt}", env)

      text = meta.call("run collapse-coverage-reports", env)

      expect(tmux_surface).not_to have_received(:window)
      expect(text).to match(/has not been generated|no.*script/i)
    end

    describe "an empty prompt" do
      it "refuses with usage instead of spawning a role or writing a file" do
        text = meta.call("summarizer", env)

        expect(role_spawn).not_to have_received(:call)
        expect(text).to start_with("/meta")
        expect(declarations).to be_empty
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
        expect(text).to include("ghost")
        expect(text).to match(/no.*script|not found|has not been generated/i)
      end
    end

    describe "a traversal slug (path escapes the artifact home)" do
      it "refuses on the charset, never resolving a file outside .lain/meta" do
        outside = File.join(root, "outside.rb")
        File.write(outside, "# a real .rb OUTSIDE .lain/meta\n")

        text = meta.call("run ../outside", env)

        expect(tmux_surface).not_to have_received(:window)
        expect(text).to include("not a valid script name")
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

  # The same honesty guarantee for the summarizer role: the example the model is
  # shown must itself be a declaration A2's Builder loads, or /meta summarizer
  # ships a lie.
  describe "the shipped meta-summarizer template skeleton" do
    let(:template) { Lain::Prompt::Slots.shipped_role_templates.fetch("meta-summarizer") }
    let(:skeleton) { template[/```ruby\n(.*?)\n```/m, 1] }

    it "embeds a ruby skeleton declaration" do
      expect(skeleton).not_to be_nil
    end

    it "builds into exactly one summarizer through the real Builder" do
      built = Lain::Summarizer::Builder.build(skeleton, "meta-summarizer.md")

      expect(built.size).to eq(1)
      expect(built.first).to be_a(Lain::Summarizer::Base)
    end

    # Not just loadable: the skeleton's own predicate must accept the shape of
    # output it claims to handle, and its compact must shorten it. A skeleton
    # that never fires is an example that teaches nothing.
    it "shows a skeleton whose summarizer answers the output it claims" do
      summarizer = Lain::Summarizer::Builder.build(skeleton, "meta-summarizer.md").first
      text = <<~REPORT
        Coverage report generated for RSpec to /cov. 84.21% covered at 12.3 hits/line
        lib/lain/agent.rb    91.4%
        lib/lain/store.rb    62.5%
      REPORT
      result = Lain::Summarizer::Result.new(tool_name: "bash", text:)

      expect(summarizer.suitable?(result)).to be(true)
      expect(summarizer.compact(result).length).to be < text.length
    end
  end
end
