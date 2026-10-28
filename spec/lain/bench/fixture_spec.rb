# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Bench::Fixture do
  around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

  def write(name, text) = File.join(@dir, name).tap { File.write(_1, text) }

  describe ".yaml" do
    it "returns the parsed document" do
      expect(described_class.yaml(write("a.yml", "tasks: [1]\n"), kind: "arm-task fixture")).to eq("tasks" => [1])
    end

    it "refuses a missing file as a Lain::Error naming the kind and the path" do
      path = File.join(@dir, "none.yml")
      expect { described_class.yaml(path, kind: "arm-task fixture") }
        .to raise_error(described_class::Missing, "no arm-task fixture at #{path}")
      expect(described_class::Missing.ancestors).to include(Lain::Error)
    end

    it "refuses malformed YAML naming the path and Psych's reason" do
      path = write("bad.yml", "tasks: [unclosed\n")
      expect { described_class.yaml(path, kind: "arm-task fixture") }
        .to raise_error(described_class::Malformed,
                        /arm-task fixture at #{Regexp.escape(path)} is not valid YAML: .*did not find/)
    end
  end

  describe ".existing!" do
    it "returns the path when the file is there" do
      path = write("a.yml", "x: 1\n")
      expect(described_class.existing!(path, kind: "sweep corpus file")).to eq(path)
    end

    it "refuses a missing path with the kind in the message" do
      expect { described_class.existing!("/nowhere/x.yml", kind: "sweep corpus file") }
        .to raise_error(described_class::Missing, "no sweep corpus file at /nowhere/x.yml")
    end
  end
end
