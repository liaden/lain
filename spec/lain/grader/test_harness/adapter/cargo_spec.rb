# frozen_string_literal: true

RSpec.describe Lain::Grader::TestHarness::Adapter::Cargo do
  def fixture(name) = File.read(File.expand_path("../../../../fixtures/cargo/#{name}", __dir__))

  let(:root) { "/work/nyotes" }
  let(:adapter) { described_class.new(root, metadata: -> { fixture("workspace_metadata.json") }) }
  let(:flags) { %w[--no-fail-fast --message-format=json] }

  def argv(*paths) = adapter.command(out_path: "/unused", paths:)

  it "reads cargo's stdout rather than a result file" do
    expect(adapter.stdout?).to be(true)
  end

  describe "#parse" do
    it "names the passing and the failing test" do
      parsed = adapter.parse(fixture("pass_fail.stdout"), 101)

      expect(parsed).to include(passed: ["tests::passes"], failed: ["tests::fails"], errors: [])
    end

    it "reports a compile error once, with its code, file and message" do
      errors = adapter.parse(fixture("compile_error.stdout"), 101).fetch(:errors)

      expect(errors.size).to eq(1)
      expect(errors.first).to include("E0425", "src/lib.rs", "cannot find value `missing_value`")
    end

    it "leaves out an error with no code and a warning that has one" do
      lines = [{ level: "error", code: nil, message: "aborting due to 1 previous error", spans: [] },
               { level: "warning", code: { code: "unused" }, message: "unused variable", spans: [] }]
      document = lines.map { |message| JSON.generate(reason: "compiler-message", message:) }.join("\n")

      expect(adapter.parse(document, 101).fetch(:errors)).to eq([])
    end

    it "raises when cargo printed nothing to parse" do
      expect { adapter.parse("", 127) }.to raise_error(Lain::Grader::TestHarness::Adapter::Unparseable, /exit 127/)
    end
  end

  describe "#command" do
    it "runs the whole workspace with no paths" do
      expect(argv).to eq(%w[cargo test --workspace] + flags)
    end

    it "filters a module file to its package and module path" do
      expect(argv("crates/capture/src/pipewire.rs")).to eq(%w[cargo test -p nyotes-capture] + flags + ["pipewire::"])
    end

    it "names a nested module by its whole path" do
      expect(argv("crates/capture/src/a/b.rs").last).to eq("a::b::")
    end

    it "treats mod.rs as its directory's module" do
      expect(argv("crates/capture/src/a/mod.rs").last).to eq("a::")
    end

    it "runs a crate root's whole package" do
      expect(argv("crates/capture/src/lib.rs")).to eq(%w[cargo test -p nyotes-capture] + flags)
    end

    it "runs a tests/ file as its own test target" do
      expected = %w[cargo test -p nyotes-capture --test end_to_end] + flags

      expect(argv("crates/capture/tests/end_to_end.rs")).to eq(expected)
    end

    it "keeps one filter when 2 module paths are asked for" do
      filters = argv("crates/capture/src/a.rs", "crates/capture/src/b.rs").grep(/::\z/)

      expect(filters).to eq(["a::"])
    end

    it "runs the whole package when a module path comes with its crate root" do
      whole = %w[cargo test -p nyotes-capture] + flags

      expect(argv("crates/capture/src/a.rs", "crates/capture/src/lib.rs")).to eq(whole)
    end

    it "picks a nested crate over the package that contains it" do
      nested = JSON.generate("packages" => [
                               { "name" => "outer", "manifest_path" => "/work/nyotes/Cargo.toml" },
                               { "name" => "inner", "manifest_path" => "/work/nyotes/crates/inner/Cargo.toml" }
                             ])
      cargo = described_class.new(root, metadata: -> { nested })

      expect(cargo.command(paths: ["crates/inner/src/lib.rs"])).to include("inner")
    end

    it "names each package once for paths in two crates" do
      expect(argv("crates/capture/src/lib.rs", "crates/other/src/lib.rs"))
        .to eq(%w[cargo test -p nyotes-capture -p nyotes-other] + flags)
    end

    it "refuses a path no package owns" do
      expect { argv("elsewhere/x.rs") }.to raise_error(Lain::Error, %r{elsewhere/x.rs.*no package})
    end
  end

  describe "naming the manifest a package lacks" do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    let(:layout) do
      Lain::TestLayout.from({ "preset" => "cargo", "source_roots" => %w[crates/store/src crates/asr/src] }, path: nil)
    end
    let(:adapter) do
      described_class.new(@dir, metadata: -> { fixture("workspace_metadata.json") }, mapping: layout.mapping)
    end

    def refusal(path, with: adapter)
      with.command(paths: [path])
    rescue Lain::Error => e
      e.message
    end

    it "names the layout's package manifest for a crate not yet created, though the root has one" do
      File.write(File.join(@dir, "Cargo.toml"), "")

      expect(refusal("crates/store/tests/store-crate.rs")).to include("no crates/store/Cargo.toml")
    end

    it "takes the package from the layout, not from the nearest src or tests segment" do
      nested = Lain::TestLayout.from({ "preset" => "cargo", "source_roots" => ["crates/a/src"] }, path: nil)
      cargo = described_class.new(@dir, metadata: -> { fixture("workspace_metadata.json") }, mapping: nested.mapping)

      expect(refusal("crates/a/src/foo/tests/x.rs", with: cargo)).to include("no crates/a/Cargo.toml")
    end

    it "names the conventional manifest for a workspace path when the layout declares only a top-level root" do
      top = Lain::TestLayout.from({ "preset" => "cargo" }, path: nil)
      cargo = described_class.new(@dir, metadata: -> { fixture("workspace_metadata.json") }, mapping: top.mapping)

      expect(refusal("crates/store/tests/x.rs", with: cargo)).to include("no crates/store/Cargo.toml")
    end

    it "falls back to the directory above src/ or tests/ when no layout is given" do
      bare = described_class.new(@dir, metadata: -> { fixture("workspace_metadata.json") })

      expect(refusal("crates/asr/tests/x.rs", with: bare)).to include("no crates/asr/Cargo.toml")
    end

    it "falls back the same way for a path in no package of the layout" do
      expect(refusal("crates/other/tests/x.rs")).to include("no crates/other/Cargo.toml")
    end
  end

  describe "#awaiting_subject?" do
    def awaiting?(errors, subject: "src/meeting.rs")
      adapter.awaiting_subject?(errors, subject:, target: subject, root:)
    end

    it "accepts only missing-item errors in the subject's own file" do
      errors = ["E0425 src/meeting.rs: cannot find function `start`", "E0433 src/meeting.rs: failed to resolve",
                "E0432 src/meeting.rs: unresolved import", "E0412 src/meeting.rs: cannot find type",
                "E0599 src/meeting.rs: no method named `end`"]

      expect(awaiting?(errors)).to be(true)
    end

    it "refuses an error of another kind beside a missing item" do
      expect(awaiting?(["E0425 src/meeting.rs: x", "E0308 src/meeting.rs: mismatched types"])).to be(false)
    end

    it "refuses a missing item whose primary span is in another file" do
      expect(awaiting?(["E0425 src/other.rs: cannot find value"])).to be(false)
    end

    it "cannot tell a typo in the subject's own inline tests from a missing item, so it accepts it" do
      expect(awaiting?(["E0425 src/meeting.rs: cannot find value `expected_totl` in this scope"])).to be(true)
    end

    context "with an integration test file in the subject's own package" do
      let(:subject_file) { "crates/capture/src/pipewire.rs" }
      let(:target) { "crates/capture/tests/capture-pipewire.rs" }

      def awaiting_from?(errors, target: self.target)
        adapter.awaiting_subject?(errors, subject: subject_file, target:, root:)
      end

      it "accepts missing-item errors in that file naming the subject's crate as the subject not written yet" do
        errors = ["E0432 #{target}: unresolved import `nyotes_capture::pipewire`",
                  "E0433 #{target}: failed to resolve: could not find `pipewire` in `nyotes_capture`",
                  "E0425 #{target}: cannot find function `open` in crate `nyotes_capture`",
                  "E0425 #{target}: cannot find type `Stream` in crate `nyotes_capture`"]

        expect(awaiting_from?(errors)).to be(true)
      end

      it "refuses a missing item naming no item of the subject's crate as a typo in the test" do
        errors = ["E0425 #{target}: cannot find function `helpr` in this scope"]

        expect(awaiting_from?(errors)).to be(false)
      end

      it "refuses a missing method, whose message names no crate" do
        errors = ["E0599 #{target}: no method named `close` found for struct `Stream`"]

        expect(awaiting_from?(errors)).to be(false)
      end

      it "still accepts missing items in the subject itself beside them" do
        expect(awaiting_from?(["E0432 #{target}: unresolved import `nyotes_capture::x`",
                               "E0425 #{subject_file}: cannot find value"]))
          .to be(true)
      end

      it "refuses any other compile error in that file as not loading" do
        expect(awaiting_from?(["E0432 #{target}: unresolved import `nyotes_capture::x`",
                               "E0308 #{target}: mismatched types"]))
          .to be(false)
      end

      it "refuses missing items in a test file of another package" do
        expect(awaiting_from?(["E0432 crates/other/tests/x.rs: unresolved import"],
                              target: "crates/other/tests/x.rs")).to be(false)
      end
    end

    it "refuses no errors at all" do
      expect(awaiting?([])).to be(false)
    end
  end

  describe "#registration" do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    let(:adapter) { described_class.new(@dir, metadata: -> { fixture("workspace_metadata.json") }) }

    def write(path, text = "")
      FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
      File.write(File.join(@dir, path), text)
    end

    def registration(subject) = adapter.registration(subject:, root: @dir)

    def entry(path, line) = Lain::Grader::TestHarness::Adapter::Registration.new(path:, line:)

    it "declares a new top-level subject in the crate root" do
      write("src/lib.rs", "pub fn old() {}\n")

      expect(registration("src/meeting.rs")).to eq([entry("src/lib.rs", "pub mod meeting;")])
    end

    it "falls back to main.rs when the crate has no lib.rs" do
      write("src/main.rs", "fn main() {}\n")

      expect(registration("src/meeting.rs")).to eq([entry("src/main.rs", "pub mod meeting;")])
    end

    it "declares a nested subject in its parent's mod.rs" do
      write("src/lib.rs")
      write("src/capture/mod.rs")

      expect(registration("src/capture/pipewire.rs")).to eq([entry("src/capture/mod.rs", "pub mod pipewire;")])
    end

    it "declares a nested subject in a sibling file named for the parent module" do
      write("src/lib.rs")
      write("src/capture.rs")

      expect(registration("src/capture/pipewire.rs")).to eq([entry("src/capture.rs", "pub mod pipewire;")])
    end

    it "finds a workspace member's crate root" do
      write("crates/app/src/lib.rs")

      expect(registration("crates/app/src/meeting.rs")).to eq([entry("crates/app/src/lib.rs", "pub mod meeting;")])
    end

    it "registers nothing when the parent already declares the module, publicly or not" do
      write("src/lib.rs", "mod meeting;\n")
      write("src/capture/mod.rs", "pub(crate) mod pipewire ;\n")

      expect([registration("src/meeting.rs"), registration("src/capture/pipewire.rs")]).to eq([[], []])
    end

    it "registers nothing for a crate root or a mod.rs" do
      write("src/lib.rs")

      expect(%w[src/main.rs src/lib.rs src/capture/mod.rs].map { |path| registration(path) }).to eq([[], [], []])
    end

    it "registers nothing for a subject outside src/" do
      expect(registration("tests/meeting.rs")).to eq([])
    end

    it "refuses a subject whose parent module file does not exist, naming it" do
      write("src/lib.rs")

      expect { registration("src/capture/pipewire.rs") }
        .to raise_error(Lain::Error, %r{src/capture\.rs.*src/capture/mod\.rs|src/capture/mod\.rs.*src/capture\.rs})
    end

    it "refuses a src/bin subject as unsupported, not as a missing mod file" do
      write("src/lib.rs")

      expect { registration("src/bin/tool.rs") }.to raise_error(Lain::Error, %r{src/bin.*not supported})
    end

    it "refuses a crate with no root file" do
      expect { registration("src/meeting.rs") }.to raise_error(Lain::Error, %r{src/lib\.rs})
    end
  end

  it "names Cargo.lock as the lockfile and target/ as the build dir" do
    expect([adapter.lockfile, adapter.build_dir]).to eq(["Cargo.lock", "target/"])
  end

  describe "against real cargo", :seam do
    it "counts the passing and the failing test of a scratch crate" do
      skip "cargo is not on PATH" unless system("cargo", "--version", out: File::NULL, err: File::NULL)

      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Cargo.toml"), %([package]\nname = "scratch"\nversion = "0.1.0"\nedition = "2021"\n))
        FileUtils.mkdir_p(File.join(dir, "src"))
        File.write(File.join(dir, "src/lib.rs"), <<~RUST)
          #[cfg(test)]
          mod tests {
              #[test] fn passes() {}
              #[test] fn fails() { panic!("no"); }
          }
        RUST
        env = Data.define(:cwd, :env).new(cwd: dir, env: ENV.to_h)
        harness = Lain::Grader::TestHarness.new(dir, adapter: described_class.new(dir))

        run = harness.run(env)

        expect([run.passed.size, run.failed.size]).to eq([1, 1])
      end
    end
  end
end
