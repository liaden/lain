# frozen_string_literal: true

RSpec.describe Lain::HeapEnv do
  it "holds the 3 measured initial heap sizes, frozen" do
    expect(described_class::VALUES).to eq("RUBY_GC_HEAP_0_INIT_SLOTS" => "300000",
                                          "RUBY_GC_HEAP_1_INIT_SLOTS" => "150000",
                                          "RUBY_GC_HEAP_2_INIT_SLOTS" => "75000").and be_frozen
  end

  describe ".over" do
    it "gives the defaults when the environment sets none" do
      expect(described_class.over({})).to eq(described_class::VALUES)
    end

    it "lets a set value win and keeps unrelated names" do
      env = { "RUBY_GC_HEAP_0_INIT_SLOTS" => "500000", "TMPDIR" => "/t" }

      expect(described_class.over(env)).to include("RUBY_GC_HEAP_0_INIT_SLOTS" => "500000",
                                                   "RUBY_GC_HEAP_1_INIT_SLOTS" => "150000", "TMPDIR" => "/t")
    end

    it "treats a blank value as unset" do
      expect(described_class.over({ "RUBY_GC_HEAP_2_INIT_SLOTS" => " " }))
        .to include("RUBY_GC_HEAP_2_INIT_SLOTS" => "75000")
    end
  end

  it "loads in a bare ruby with no loader, as the shim's installer does" do
    out = IO.popen([RbConfig.ruby, "-e", "load ARGV[0]; print Lain::HeapEnv::VALUES.size",
                    File.expand_path("../../lib/lain/heap_env.rb", __dir__)], &:read)

    expect(out).to eq("3")
  end
end
