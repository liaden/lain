# frozen_string_literal: true

RSpec.describe Lain::Notices::Feed do
  let(:dir) { Dir.mktmpdir("lain-feed") }
  let(:notes) { StringIO.new }
  let(:program) { File.join(dir, "notify-feed") }
  let(:capture) { File.join(dir, "capture") }

  after { FileUtils.remove_entry(dir) }

  def stub_program(exit_status: 0)
    File.write(program, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" > #{capture}.args
      cat > #{capture}.stdin
      exit #{exit_status}
    SH
    File.chmod(0o755, program)
  end

  it "passes source and title as arguments and the body on stdin" do
    stub_program

    described_class.new(program:, notes:).call("lain", "T3 landed", "sha abc123")

    expect(File.read("#{capture}.args")).to eq("lain\nT3 landed\n")
    expect(File.read("#{capture}.stdin")).to eq("sha abc123")
  end

  it "spawns with a 2-second timeout" do
    out = instance_double(Lain::Shell::Out, run_command: instance_double(Lain::Shell::Out, exitstatus: 0))
    shell_out = class_double(Lain::Shell::Out)
    allow(shell_out).to receive(:new).and_return(out)

    described_class.new(program: "nf", shell_out:, notes:, env: {}).call("lain", "t", "b")

    expect(shell_out).to have_received(:new).with("nf", "lain", "t", input: "b", timeout: 2, environment: {})
  end

  context "with lain's Ruby loader env set" do
    let(:loader_env) do
      { "RUBYOPT" => "-rlain_no_such_lib", "RUBYLIB" => "/nowhere", "BUNDLE_GEMFILE" => "/nowhere/Gemfile" }
    end
    let(:kept_env) { { "DISPLAY" => ":9", "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/nowhere", "HOME" => "/home/x" } }

    it "hands the program none of the loader names and keeps the display and home ones" do
      File.write(program, "#!/bin/sh\nenv > #{capture}.env\n")
      File.chmod(0o755, program)

      with_env(loader_env.merge(kept_env)) { described_class.new(program:, notes:).call("lain", "t", "b") }

      seen = File.read("#{capture}.env").lines(chomp: true).to_h { |line| line.split("=", 2) }
      expect(seen).to include(kept_env).and(satisfy { |env| !loader_env.keys.intersect?(env.keys) })
    end

    it "delivers the note to a Ruby program that the inherited RUBYOPT would have broken" do
      File.write(program, "#!/usr/bin/env ruby\nFile.write(\"#{capture}.stdin\", $stdin.read)\n")
      File.chmod(0o755, program)

      sent = with_env(loader_env) { described_class.new(program:, notes:).call("lain", "t", "body") }

      expect([sent, notes.string, File.read("#{capture}.stdin")]).to eq([true, "", "body"])
    end
  end

  it "returns false and names the status on the notes sink when the program fails" do
    stub_program(exit_status: 1)

    result = described_class.new(program:, notes:).call("lain", "t", "b")

    expect(result).to be(false)
    expect(notes.string).to eq("#{program} exited 1\n")
  end

  it "names a failing program once, however many notes fail" do
    stub_program(exit_status: 1)
    feed = described_class.new(program:, notes:)

    2.times { feed.call("lain", "t", "b") }

    expect(notes.string).to eq("#{program} exited 1\n")
  end

  it "returns false and says so when the program cannot be spawned" do
    missing = File.join(dir, "missing")
    result = described_class.new(program: missing, notes:).call("lain", "t")

    expect(result).to be(false)
    expect(notes.string).to start_with("#{missing} failed: ").and end_with("\n")
  end

  it "is silent on success, and says it sent" do
    stub_program

    sent = described_class.new(program:, notes:).call("lain", "t", "b")

    expect([sent, notes.string]).to eq([true, ""])
  end
end
