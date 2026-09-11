# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# Where a test may be written, held at the tool phase: a `write_file` is checked
# against its whole content and an `edit_file` against the path rules, over a
# copy of the `layout_mini` fixture, which declares the rspec layout over app/.
RSpec.describe Lain::Middleware::GuardTestLayout do
  let(:journal) { [] }
  let(:layout) { Lain::Config.test_layout(root:) }
  let(:run) { Lain::Middleware::GuardTestLayout::Run.new(layout:, root:) }
  let(:guard) { described_class.new(run:, journal:) }

  around do |example|
    Dir.mktmpdir("lain-layout-guard") do |dir|
      @root = File.realpath(dir)
      FileUtils.cp_r("spec/fixtures/projects/layout_mini/.", @root)
      # The fixture commits no test tree, and write_file creates no directory.
      FileUtils.mkdir_p(File.join(@root, "spec", "unit", "models"))
      example.run
    end
  end

  attr_reader :root

  def describing(constant) = "RSpec.describe #{constant} do\n  it { expect(1).to eq(1) }\nend\n"

  def session = Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: root))

  def write_call(path, content, id: "tu_w")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: "write_file", input: { "path" => path, "content" => content })
  end

  def edit_call(path)
    Lain::Effect::ToolCall.new(tool_use_id: "tu_e", name: "edit_file",
                               input: { "path" => path, "old_string" => "a", "new_string" => "b" })
  end

  # The real write_file behind the guard, so "nothing was written" is a fact
  # about the disk rather than about a double.
  def through(middleware, effect, context: session)
    Sync do
      middleware.call({ effect:, context: }) do |inner|
        invocation = Lain::Tool::Invocation.new(tool_use_id: effect.tool_use_id, context: inner.fetch(:context))
        inner.merge(result: Lain::Tools::WriteFile.new.call(effect.input, invocation))
      end
    end.fetch(:result)
  end

  def records(type) = journal.select { |record| record.to_journal["type"] == type }

  describe "a write_file the layout refuses" do
    let(:sibling) { "spec/unit/models/order_extra_spec.rb" }

    it "refuses a split sibling, naming the path its subject's test belongs at" do
      result = through(guard, write_call(sibling, describing("Order")))

      expect(result.is_error).to be(true)
      expect(result.content).to include("spec/unit/models/order_spec.rb")
    end

    it "names that path once, however the guard's own reason already put it" do
      result = through(guard, write_call(sibling, describing("Order")))

      expect(result.content.scan("spec/unit/models/order_spec.rb").size).to eq(1)
    end

    it "writes nothing" do
      through(guard, write_call(sibling, describing("Order")))

      expect(File.exist?(File.join(root, sibling))).to be(false)
    end

    it "journals the refusal with its rule and the path the layout wants" do
      through(guard, write_call(sibling, describing("Order")))

      expect(records("test_layout_refused").map(&:to_journal))
        .to contain_exactly(include("tool" => "write_file", "path" => sibling, "rule" => :elsewhere,
                                    "expected" => "spec/unit/models/order_spec.rb"))
    end

    it "refuses the same sibling named by its absolute path inside the project" do
      result = through(guard, write_call(File.join(root, sibling), describing("Order")))

      expect(result.is_error).to be(true)
    end
  end

  describe "a write the layout admits" do
    it "writes a test that mirrors its source, untouched and unrecorded" do
      result = through(guard, write_call("spec/unit/models/order_spec.rb", describing("Order")))

      expect(result.is_error).to be(false)
      expect(File.read(File.join(root, "spec/unit/models/order_spec.rb"))).to eq(describing("Order"))
      expect(journal).to be_empty
    end

    it "writes a file that is not a test at all, unrecorded" do
      result = through(guard, write_call("app/models/refund.rb", "class Refund; end\n"))

      expect(result.is_error).to be(false)
      expect(journal).to be_empty
    end

    # A test is legitimately written before the class it describes; the
    # land-time check is what refuses one whose class never arrived.
    it "lets a test written before its class through, and notes that it did" do
      result = through(guard, write_call("spec/unit/models/refund_spec.rb", describing("Refund")))

      expect(result.is_error).to be(false)
      expect(File.exist?(File.join(root, "spec/unit/models/refund_spec.rb"))).to be(true)
      expect(records("test_layout_deferred").map(&:path)).to eq(["spec/unit/models/refund_spec.rb"])
    end
  end

  describe "an edit_file, held to the path rules" do
    it "refuses an edit of a test in no level root, naming no path it cannot vouch for" do
      called = false
      result = Sync do
        guard.call({ effect: edit_call("spec/order_extra_spec.rb"), context: session }) do |inner|
          called = true
          inner.merge(result: Lain::Tool::Result.ok("edited"))
        end
      end.fetch(:result)

      expect(called).to be(false)
      expect(result.is_error).to be(true)
      expect(records("test_layout_refused").map(&:rule)).to eq([:stray])
    end

    it "passes an edit of a test that mirrors its source" do
      result = Sync do
        guard.call({ effect: edit_call("spec/unit/models/order_spec.rb"), context: session }) do |inner|
          inner.merge(result: Lain::Tool::Result.ok("edited"))
        end
      end.fetch(:result)

      expect(result.content).to eq("edited")
    end
  end

  # A child leased into a checkout of its own writes there. The layout is
  # repo-relative, so a write in the checkout is judged against the checkout,
  # and a refusal names the repo-relative path.
  describe "a write in a child's own checkout" do
    let(:sibling) { "spec/unit/models/order_extra_spec.rb" }

    around do |example|
      Dir.mktmpdir("lain-layout-checkout") do |dir|
        @checkout = File.realpath(dir)
        FileUtils.cp_r("spec/fixtures/projects/layout_mini/.", @checkout)
        FileUtils.mkdir_p(File.join(@checkout, "spec", "unit", "models"))
        example.run
      end
    end

    attr_reader :checkout

    def in_checkout = Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: checkout))

    it "refuses a split sibling there, naming the path its subject's test belongs at" do
      child = described_class.new(run:, roots: [root, checkout], journal:)

      result = through(child, write_call(sibling, describing("Order")), context: in_checkout)

      expect(result.is_error).to be(true)
      expect(result.content).to include("spec/unit/models/order_spec.rb")
      expect(File.exist?(File.join(checkout, sibling))).to be(false)
      expect(records("test_layout_refused").map(&:path)).to eq([sibling])
    end

    it "writes a correct test there" do
      child = described_class.new(run:, roots: [root, checkout], journal:)

      result = through(child, write_call("spec/unit/models/order_spec.rb", describing("Order")), context: in_checkout)

      expect(result.is_error).to be(false)
    end

    # Held at the project root alone, the same write is outside it, so nothing
    # would be checked: the root is what makes the child's write guarded.
    it "is unguarded when the checkout's root is not one the guard holds" do
      result = through(guard, write_call(sibling, describing("Order")), context: in_checkout)

      expect(result.is_error).to be(false)
    end
  end

  describe described_class::Run do
    def env_at(cwd, checkout: nil) = Lain::WorkerEnv.default.with(cwd:, checkout:)

    it "keeps one guard per root for the whole run" do
      expect(run.guard_for(root)).to be(run.guard_for(root))
      expect(run.guard).to be(run.guard_for(root))
    end

    it "adds the checkout a leased child's environment names" do
      Dir.mktmpdir do |dir|
        expect(run.roots_for(env_at(dir, checkout: dir))).to eq([root, dir])
      end
    end

    # The lease is asked, never the filesystem: an unleased child standing in
    # some other repository is held exactly where its parent is.
    it "gives an unleased child the parent's roots, even standing in another repository" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, ".git"), "gitdir: elsewhere\n")

        expect(run.roots_for(env_at(dir))).to eq([root])
        expect(run.roots_for(env_at(File.join(root, "app")))).to eq([root])
      end
    end

    # A checkout's guard indexes that checkout's sources, and a run spawns
    # many leases over its life; the project's own guard is never the one let go.
    it "bounds the checkout guards it keeps, and never lets the project's go" do
      Dir.mktmpdir do |dir|
        checkouts = Array.new(described_class::CHECKOUTS + 1) { |n| File.join(dir, "w#{n}") }
        FileUtils.mkdir_p(checkouts)
        project = run.guard
        first = run.guard_for(checkouts.first)

        checkouts.drop(1).each { |checkout| run.guard_for(checkout) }

        expect(run.guard_for(checkouts.first)).not_to be(first)
        expect(run.guard).to be(project)
      end
    end
  end

  # What its parent could write, an unleased child can write: the root it is
  # held at is the project's alone, whatever directory it happens to stand in.
  it "lets an unleased child standing in another repository write what its parent could" do
    Dir.mktmpdir do |other|
      File.write(File.join(other, ".git"), "gitdir: elsewhere\n")
      FileUtils.mkdir_p(File.join(other, "spec"))
      env = Lain::WorkerEnv.default.with(cwd: other)
      child = described_class.new(run:, roots: run.roots_for(env), journal:)

      result = through(child, write_call("spec/widget_spec.rb", describing("Widget")),
                       context: Lain::Session.new(worker_env: env))

      expect(result.is_error).to be(false)
    end
  end

  describe "what it does not judge" do
    def downstream_raising(error) = ->(_inner) { raise error }

    def with_downstream(effect, context: session, &app) = Sync { guard.call({ effect:, context: }, &app) }

    # The rescue belongs to the judging alone. A tool that failed after the
    # guard admitted it failed as itself: relabelling it a layout failure, or
    # saying "nothing was written" over bytes that landed, would be a lie.
    it "lets a guarded tool's own failure through as itself" do
      written = File.join(root, "spec/unit/models/order_spec.rb")
      effect = write_call(written, describing("Order"))

      expect do
        with_downstream(effect) do
          File.write(written, describing("Order"))
          raise Errno::ENOSPC, "after the bytes landed"
        end
      end.to raise_error(Errno::ENOSPC)
    end

    it "lets an unguarded tool's failure through untouched" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_b", name: "bash", input: { "command" => "make" })

      expect { with_downstream(effect) { raise IOError, "pipe closed" } }.to raise_error(IOError, "pipe closed")
    end

    it "still refuses a write it could not judge, naming only the error's class" do
      result = with_downstream(write_call("spec/unit/models/bad\0name_spec.rb", "x")) do |inner|
        inner.merge(result: Lain::Tool::Result.ok("wrote"))
      end.fetch(:result)

      expect(result.is_error).to be(true)
      expect(result.content).to include("could not be checked against the test layout (ArgumentError)")
    end
  end

  # A "let through" record describes a write that went through. A write the
  # gate then denied, or the tool failed, went nowhere and leaves none.
  describe "what it records about a write that did not happen" do
    def denied(middleware, effect)
      Sync do
        middleware.call({ effect:, context: session }) do |inner|
          inner.merge(result: Lain::Tool::Result.error("approval denied"))
        end
      end
    end

    it "journals no deferral for a test-before-its-class write the gate denied" do
      denied(guard, write_call("spec/unit/models/refund_spec.rb", describing("Refund")))

      expect(records("test_layout_deferred")).to be_empty
    end

    context "when the project declares no layout" do
      let(:layout) { Lain::TestLayout::None }

      it "says the absence on the first write that went through, not on one that was denied" do
        denied(guard, write_call("spec/a_spec.rb", "x", id: "tu_1"))
        expect(records("test_layout_absent")).to be_empty

        through(guard, write_call("spec/b_spec.rb", "x", id: "tu_2"))
        expect(records("test_layout_absent").size).to eq(1)
      end
    end
  end

  it "leaves every other tool untouched" do
    effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_r", name: "read_file",
                                        input: { "path" => "spec/order_extra_spec.rb" })
    result = Sync do
      guard.call({ effect:, context: session }) { |inner| inner.merge(result: Lain::Tool::Result.ok("read")) }
    end.fetch(:result)

    expect(result.content).to eq("read")
    expect(journal).to be_empty
  end

  # Enforcement is opt-in: a project that declared no `[tests]` table is held
  # to nothing, and is told so once rather than on every write.
  context "when the project declares no layout" do
    let(:layout) { Lain::TestLayout::None }

    it "refuses neither of two test writes, and journals one absence" do
      results = [through(guard, write_call("spec/unit/models/order_extra_spec.rb", describing("Order"), id: "tu_1")),
                 through(guard, write_call("spec/order_extra_spec.rb", describing("Order"), id: "tu_2"))]

      expect(results.map(&:is_error)).to eq([false, false])
      expect(records("test_layout_absent").size).to eq(1)
    end

    # The parent's guard and each child's are separate instances over the
    # run's one Run, and it is the Run that remembers the absence was said.
    it "journals one absence for the whole run, however many guards share it" do
      child = described_class.new(run:, journal:)

      through(guard, write_call("spec/a_spec.rb", "x", id: "tu_1"))
      through(child, write_call("spec/b_spec.rb", "x", id: "tu_2"))

      expect(records("test_layout_absent").size).to eq(1)
    end
  end
end
