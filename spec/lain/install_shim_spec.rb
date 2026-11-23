# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "bin/install-shim" do
  let(:script) { File.expand_path("../../bin/install-shim", __dir__) }
  let(:repo) { File.expand_path("../..", __dir__) }
  let(:target) { Dir.mktmpdir("lain-shim-target") }
  let(:fake_bin) { Dir.mktmpdir("lain-shim-ruby") }

  after { FileUtils.rm_rf([target, fake_bin]) }

  def install(env = {})
    Open3.capture3(env, "bash", script, target)
  end

  def fake_ruby
    path = File.join(fake_bin, "ruby")
    File.write(path, "#!/bin/sh\n[ \"$1\" = -e ] && exec #{RbConfig.ruby} \"$@\"\n" \
                     "echo \"ruby=$0 ld=$LD_LIBRARY_PATH args=$*\"\n")
    File.chmod(0o755, path)
  end

  it "runs this checkout's lain from any directory, ahead of any other lain on PATH" do
    _, err, status = install
    expect([err, status.success?]).to eq(["", true])
    stub_dir = Dir.mktmpdir("lain-shim-stub")
    File.write(File.join(stub_dir, "lain"), "#!/bin/sh\necho OTHER-LAIN\n")
    File.chmod(0o755, File.join(stub_dir, "lain"))
    ruby_bin = File.dirname(RbConfig.ruby)
    clean = { "PATH" => "#{stub_dir}:#{ruby_bin}:/usr/bin:/bin", "HOME" => Dir.home,
              "LD_LIBRARY_PATH" => ENV.fetch("LD_LIBRARY_PATH", nil) }
    unset = %w[BUNDLE_GEMFILE RUBYOPT BUNDLE_BIN_PATH RUBYLIB].to_h { |k| [k, nil] }

    Dir.mktmpdir("lain-shim-cwd") do |cwd|
      out, = Open3.capture2e(unset.merge(clean), File.join(target, "lain"), "help", chdir: cwd)
      expect(out).to include("Commands:").and(satisfy { |o| !o.include?("OTHER-LAIN") })
    end
    expect(File.read(File.join(target, "lain"))).to include("#{repo}/exe/lain")
  ensure
    FileUtils.rm_rf(stub_dir)
  end

  it "execs the installing ruby with the installed library path after the environment loses it" do
    fake_ruby
    _, err, status = install("PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}", "LD_LIBRARY_PATH" => "/installed/lib")
    expect([err, status.success?]).to eq(["", true])

    out, = Open3.capture2e({ "LD_LIBRARY_PATH" => nil }, File.join(target, "lain"), "--version")
    expect(out.strip).to eq("ruby=#{fake_bin}/ruby ld=/installed/lib args=#{repo}/exe/lain --version")
  end

  it "exports the heap settings before the exec line" do
    _, err, status = install
    shim = File.read(File.join(target, "lain")).lines.map(&:chomp)
    exec_at = shim.index { |l| l.start_with?("exec ") }
    lines = Lain::HeapEnv::VALUES.map { |name, value| "export #{name}=${#{name}:-#{value}}" }

    expect([err, status.success?]).to eq(["", true])
    expect(lines.map { |l| shim.index(l) }).to all(be_a(Integer).and(be < exec_at))
  end

  it "lets a heap setting the caller already exported win over the shim's default" do
    fake_ruby
    install("PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}")
    File.write(File.join(fake_bin, "ruby"), "#!/bin/sh\n[ \"$1\" = -e ] && exec #{RbConfig.ruby} \"$@\"\n" \
                                            "echo \"$RUBY_GC_HEAP_0_INIT_SLOTS $RUBY_GC_HEAP_1_INIT_SLOTS\"\n")

    out, = Open3.capture2e({ "RUBY_GC_HEAP_0_INIT_SLOTS" => "500000", "RUBY_GC_HEAP_1_INIT_SLOTS" => nil },
                           File.join(target, "lain"))
    expect(out.strip).to eq("500000 150000")
  end

  it "leaves the earlier shim intact when the heap values cannot be read" do
    install
    before = File.read(File.join(target, "lain"))
    File.write(File.join(fake_bin, "ruby"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(fake_bin, "ruby"))
    _, _, status = install("PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}")

    expect([status.success?, File.read(File.join(target, "lain"))]).to eq([false, before])
  end

  it "refuses to overwrite a lain that is not a shim" do
    File.write(File.join(target, "lain"), "#!/bin/sh\necho mine\n")
    _, err, status = install

    expect([status.success?, err]).to match([false, include(File.join(target, "lain"))])
    expect(File.read(File.join(target, "lain"))).to include("mine")
  end

  it "replaces a shim it wrote earlier" do
    install
    first = File.read(File.join(target, "lain"))
    _, _, status = install("LD_LIBRARY_PATH" => "/second/lib")
    expect(status.success?).to be(true)
    expect(File.read(File.join(target, "lain"))).to include("/second/lib").and(satisfy { |c| c != first })
  end
end
