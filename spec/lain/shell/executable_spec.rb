# frozen_string_literal: true

require "json"

RSpec.describe Lain::Shell::Executable do
  describe ".unresolved" do
    subject(:executable) { described_class.unresolved(+"cat", anomalies: [:ld_preload]) }

    it "names the program and knows nothing else about it" do
      expect(executable).to have_attributes(name: "cat", resolved: nil, realpath: nil, chain: [], shadowed: [],
                                            anomalies: [:ld_preload], klass: :unresolved, fresh: false,
                                            run_files: [], wrappers: [])
    end

    it "is Ractor-shareable" do
      expect(Ractor.shareable?(executable)).to be(true)
    end
  end

  describe "#to_journal" do
    it "is JSON-safe, with each wrapper journalled the same way" do
      wrapper = described_class.unresolved("nice", anomalies: [:ld_preload])
      executable = described_class.new(name: "cat", resolved: "/usr/bin/cat", realpath: "/usr/bin/cat",
                                       chain: ["/usr/bin/cat"], shadowed: [], anomalies: [:empty_path_entry],
                                       klass: :system, fresh: false, run_files: [], wrappers: [wrapper])

      expect(executable.to_journal).to eq(
        "name" => "cat", "resolved" => "/usr/bin/cat", "realpath" => "/usr/bin/cat", "chain" => ["/usr/bin/cat"],
        "shadowed" => [], "anomalies" => ["empty_path_entry"], "klass" => "system", "fresh" => false,
        "run_files" => [], "wrappers" => [wrapper.to_journal]
      )
      expect(JSON.parse(JSON.generate(executable.to_journal))).to eq(executable.to_journal)
    end
  end

  it "deep-freezes what it is built from, so a resolved Executable is Ractor-shareable" do
    wrapper = described_class.unresolved(+"nice")
    executable = described_class.new(name: +"cat", resolved: +"/usr/bin/cat", realpath: +"/usr/bin/cat",
                                     chain: [+"/usr/bin/cat"], shadowed: [+"/bin/cat"], anomalies: [],
                                     klass: :system, fresh: false, run_files: [], wrappers: [wrapper])

    expect(Ractor.shareable?(executable)).to be(true)
  end
end
