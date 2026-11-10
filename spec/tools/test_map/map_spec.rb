# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../../../tools/test_map/map"

RSpec.describe TestMap::Map do
  let(:tree) { "a" * 40 }

  def line(spec, **fields)
    { "spec" => spec, "lines" => {}, "methods" => {}, "reads" => [], "globs" => [], "ext" => [],
      "spawns" => [], "lain_child" => false, "tree_reader" => false }.merge(fields.transform_keys(&:to_s))
  end

  def write_raw(dir, name, *records)
    File.write(File.join(dir, name), records.map { |r| "#{JSON.generate(r)}\n" }.join)
  end

  def build(dir, expected, **)
    described_class.build(dir, expected:, tree:, **)
  end

  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  describe ".build" do
    it "unions the entries of a spec file split across workers" do
      write_raw(@dir, "w1x1.ndjson",
                line("spec/a_spec.rb", lines: { "lib/x.rb" => [1, 2] }, reads: ["Gemfile"], ext: ["Lain::Ext"]))
      write_raw(@dir, "w2x2.ndjson",
                line("spec/a_spec.rb", lines: { "lib/x.rb" => [2, 9] }, reads: ["Rakefile"], lain_child: true))
      map = build(@dir, ["spec/a_spec.rb"])

      expect(
        [map.specs_running("lib/x.rb", [9]), map.specs_reading("Gemfile"), map.specs_reading("Rakefile"),
         map.specs_calling(["Lain::Ext"]), map.lain_child_specs]
      ).to all(eq(["spec/a_spec.rb"]))
    end

    it "unions every boot line of every worker" do
      write_raw(@dir, "w1x1.ndjson", { "boot" => { "lib/x.rb" => [[10, 14]] } },
                line("spec/a_spec.rb"), { "boot" => { "lib/y.rb" => [[1, 2]] } })
      map = build(@dir, ["spec/a_spec.rb"])

      expect([map.boot_method?("lib/x.rb", 12..13), map.boot_method?("lib/y.rb", 1..1)]).to eq([true, true])
    end

    it "refuses a run missing a spec file that exists, naming it" do
      write_raw(@dir, "w1x1.ndjson", line("spec/a_spec.rb"))

      expect { build(@dir, %w[spec/a_spec.rb spec/c_spec.rb]) }
        .to raise_error(described_class::Incomplete, %r{spec/c_spec\.rb})
    end
  end

  describe "#boot_method?" do
    it "is true when a boot span overlaps and false beside it" do
      write_raw(@dir, "w1x1.ndjson", { "boot" => { "lib/x.rb" => [[10, 14]] } }, line("spec/a_spec.rb"))
      map = build(@dir, ["spec/a_spec.rb"])

      expect([map.boot_method?("lib/x.rb", 10..14), map.boot_method?("lib/x.rb", 15..16),
              map.boot_method?("lib/z.rb", 10..14)]).to eq([true, false, false])
    end
  end

  describe "#specs_running" do
    it "finds a spec by a line hit or by a method span overlapping the lines" do
      write_raw(@dir, "w1x1.ndjson",
                line("spec/a_spec.rb", lines: { "lib/x.rb" => [71] }),
                line("spec/b_spec.rb", methods: { "lib/x.rb" => [[80, 90]] }),
                line("spec/c_spec.rb"))
      map = build(@dir, %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb])

      expect([map.specs_running("lib/x.rb", [71]), map.specs_running("lib/x.rb", [85, 86]),
              map.specs_running("lib/x.rb", [100]), map.specs_running_file("lib/x.rb")])
        .to eq([["spec/a_spec.rb"], ["spec/b_spec.rb"], [], %w[spec/a_spec.rb spec/b_spec.rb]])
    end
  end

  describe "#specs_reading" do
    it "matches a recorded glob against new files at every depth" do
      write_raw(@dir, "w1x1.ndjson", line("spec/d_spec.rb", globs: ["lib/**/*.rb"]), line("spec/e_spec.rb"))
      map = build(@dir, %w[spec/d_spec.rb spec/e_spec.rb])

      expect([map.specs_reading("lib/x.rb"), map.specs_reading("lib/lain/a/b.rb"), map.specs_reading("exe/lain")])
        .to eq([["spec/d_spec.rb"], ["spec/d_spec.rb"], []])
    end
  end

  describe "#specs_spawning, #tree_reader_specs, #covers?" do
    it "answers from the recorded spawns, tree readers and covered files" do
      write_raw(@dir, "w1x1.ndjson",
                line("spec/a_spec.rb", spawns: ["target/release/lain-fence"], tree_reader: true,
                                       lines: { "lib/x.rb" => [1] }),
                { "boot" => { "lib/boot.rb" => [[1, 2]] } })
      map = build(@dir, ["spec/a_spec.rb"])

      expect([map.specs_spawning("target/release/lain-fence"), map.tree_reader_specs, map.lain_child_specs,
              map.covers?("lib/x.rb"), map.covers?("lib/boot.rb"), map.covers?("lib/none.rb")])
        .to eq([["spec/a_spec.rb"], ["spec/a_spec.rb"], [], true, true, false])
    end
  end

  describe "#merge" do
    it "replaces the entries the other map holds and keeps the rest" do
      write_raw(@dir, "w1x1.ndjson", line("spec/a_spec.rb", reads: ["Gemfile"]),
                line("spec/b_spec.rb", reads: ["Gemfile"]))
      base = build(@dir, %w[spec/a_spec.rb spec/b_spec.rb])
      Dir.mktmpdir do |other_dir|
        write_raw(other_dir, "w1x1.ndjson", line("spec/a_spec.rb", reads: ["Rakefile"]))
        merged = base.merge(described_class.build(other_dir, expected: ["spec/a_spec.rb"], tree:))

        expect([merged.specs_reading("Gemfile"), merged.specs_reading("Rakefile"), merged.tree,
                base.specs_reading("Rakefile")])
          .to eq([["spec/b_spec.rb"], ["spec/a_spec.rb"], tree, []])
      end
    end
  end

  describe "#to_h and .from_h" do
    it "round-trips through JSON" do
      write_raw(@dir, "w1x1.ndjson", { "boot" => { "lib/x.rb" => [[1, 2]] } },
                line("spec/a_spec.rb", lines: { "lib/x.rb" => [1] }, globs: ["lib/*.rb"]))
      map = build(@dir, ["spec/a_spec.rb"])
      copy = described_class.from_h(JSON.parse(JSON.generate(map.to_h)))

      expect(copy.to_h).to eq(map.to_h)
    end
  end
end
