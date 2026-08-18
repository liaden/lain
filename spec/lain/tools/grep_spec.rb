# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tools::Grep do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(relative_path, content)
    path = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  it "returns matching lines with file:line locations and the matching text" do
    write("foo.rb", "one\ntwo\nthis has needle in it\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("foo.rb:3:")
    expect(result.content).to include("this has needle in it")
  end

  it "searches recursively under a directory" do
    write("nested/deep/bar.rb", "the needle is here\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.content).to include("nested/deep/bar.rb:1:")
  end

  it "searches a single file when path names a file, not a directory" do
    path = write("foo.rb", "no match here\nneedle on this line\n")

    result = tool.call(pattern: "needle", path:)

    expect(result.content).to include("#{path}:2:")
  end

  # Byte-identical label under the default WorkerEnv: a RELATIVE single-file
  # target labels its matches with the path exactly as the model spelled it
  # ("README.md:1:"), not the WorkerEnv-resolved absolute path -- probe
  # tmp/b1-probes/grep_label.rb.
  it "labels a relative single-file target with the verbatim path, not the resolved absolute" do
    write("README.md", "hello world\n")

    result = Dir.chdir(tmpdir) { tool.call(pattern: "hello", path: "README.md") }

    expect(result.content).to eq("README.md:1:hello world")
  end

  it "says a pattern matched nothing, rather than returning an empty string -- not an error" do
    write("foo.rb", "nothing interesting here\n")

    result = tool.call(pattern: "zzz", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).not_to eq("")
    expect(result.content).to include('"zzz"')
    expect(result.content).to match(/no match/i)
  end

  it "matches case-insensitively when asked" do
    write("foo.rb", "NEEDLE\n")

    result = tool.call(pattern: "needle", path: tmpdir, case_insensitive: true)

    expect(result.content).to include("foo.rb:1:NEEDLE")
  end

  it "supports Ruby regex syntax, not just literal substrings" do
    write("foo.rb", "value = 42\nvalue = abc\n")

    result = tool.call(pattern: 'value = \d+', path: tmpdir)

    expect(result.content).to include("foo.rb:1:")
    expect(result.content).not_to include("foo.rb:2:")
  end

  it "caps output and reports the cap rather than flooding the result" do
    write("many.rb", (["x"] * 5000).join("\n"))

    result = tool.call(pattern: "x", path: tmpdir)

    expect(result.ok?).to be(true)
    matched_lines = result.content.lines.grep(/^many\.rb:/)
    expect(matched_lines.size).to eq(Lain::Tools::Grep::MAX_MATCHES)
    expect(result.content).to include("capped at #{Lain::Tools::Grep::MAX_MATCHES}")
  end

  it "skips .git directories while walking a directory tree" do
    write(".git/objects/pack-junk", "needle\n")
    write("real.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.content).not_to include(".git")
    expect(result.content).to include("real.rb:1:")
  end

  it "skips unreadable (binary) content rather than raising" do
    write("binary.dat", (0..255).map(&:chr).join)
    write("text.rb", "needle\n")

    result = tool.call(pattern: "needle", path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("text.rb:1:")
  end

  it "reports a missing path as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")

    result = tool.call(pattern: "needle", path: missing)

    expect(result).to have_attributes(is_error: true, content: /no such file or directory/)
  end

  it "reports an invalid regex pattern as an error Result rather than raising" do
    write("foo.rb", "needle\n")

    result = tool.call(pattern: "(unclosed", path: tmpdir)

    expect(result).to have_attributes(is_error: true, content: /invalid pattern/)
  end

  # The in-process walk is the DEFAULT, and this is the sharpest witness that
  # it ran: lookaround is exactly what the out-of-process engine refuses
  # (crates/lain-core builds its matcher on finite automata, by construction).
  # A green here with no client wired is the Ruby engine, not a coincidence.
  it "runs the Ruby engine when no core client is wired -- lookaround still compiles" do
    write("foo.rb", "needle in a haystack\n")

    result = tool.call(pattern: '(?=needle)\w+', path: tmpdir)

    expect(result.ok?).to be(true)
    expect(result.content).to include("foo.rb:1:")
  end

  # The description is the text the MODEL reads to decide what to send, so it
  # may only promise what BOTH paths accept. Naming Ruby made the wired-client
  # path a trap: the model writes `(?<=x)y`, the daemon refuses it, and the
  # tool's own words are why.
  it "describes the dialect as the subset both paths accept, never as Ruby's" do
    expect(tool.description).to include("Backreferences", "lookaround")
    expect(tool.description).not_to include("Ruby")
    expect(tool.input_schema.to_s).not_to include("Ruby")
  end

  it "describes no-matches as a named, non-error outcome" do
    expect(tool.description).to match(/no match/i)
  end

  # The transport swap, without a daemon: everything about the core path that
  # is THIS side's responsibility -- the wire params, the label substitution,
  # the cap flag, and how each failure reaches the model -- is pinned here and
  # runs everywhere. spec/lain/core/grep_parity_spec.rb drives the real daemon.
  describe "with a core client wired" do
    let(:client) { instance_double(Lain::Core::Client) }
    let(:tool) { described_class.new(client:) }

    def reply(matches, capped: false) = { "matches" => matches, "capped" => capped }

    it "sends the resolved path, the pattern, and an explicit case flag" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir, case_insensitive: true)

      expect(client).to have_received(:call).with(
        "grep", [{ "pattern" => "needle", "path" => tmpdir,
                   "case_insensitive" => true, "respect_ignores" => false }]
      )
    end

    # The daemon CAN apply .gitignore/.ignore rules and the in-process walk
    # cannot, so leaving them on would make the same tool answer differently
    # depending on how it was wired. Sent explicitly rather than left to the
    # daemon's default, so this side's intent is auditable on the wire -- and
    # so a future flip of that default cannot change grep's behaviour silently.
    it "always tells the daemon NOT to honour VCS ignore rules" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir)

      expect(client).to have_received(:call).with(
        "grep", [hash_including("respect_ignores" => false)]
      )
    end

    it "sends case_insensitive as false, never nil, when the model omits it" do
      allow(client).to receive(:call).and_return(reply([]))

      tool.call(pattern: "needle", path: tmpdir)

      expect(client).to have_received(:call).with(
        "grep", [hash_including("case_insensitive" => false)]
      )
    end

    it "renders the daemon's matches as file:line:text, labels verbatim under a directory" do
      allow(client).to receive(:call).and_return(
        reply([{ "path" => "nested/bar.rb", "line_number" => 7, "line" => "the needle" }])
      )

      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result.ok?).to be(true)
      expect(result.content).to eq("nested/bar.rb:7:the needle")
    end

    # The daemon labels a FILE target with the `path` param verbatim -- which
    # is the WorkerEnv-resolved absolute locator this side sends, not the
    # model's spelling. Substituting `display` back is what keeps the core
    # path's label byte-identical to the Ruby path's (grep_spec.rb:55).
    it "labels a single-file target with the model's spelling, not the path it sent" do
      path = write("README.md", "hello world\n")
      allow(client).to receive(:call).and_return(
        reply([{ "path" => path, "line_number" => 1, "line" => "hello world" }])
      )

      # The cwd arrives through the WorkerEnv rather than Dir.chdir: same
      # resolution, without a process-global mutation the parallel workers
      # would share.
      call = Lain::Tool::Invocation.new(
        context: Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {}))
      )
      result = tool.call({ pattern: "hello", path: "README.md" }, call)

      expect(result.content).to eq("README.md:1:hello world")
    end

    it "reports the daemon's capped flag rather than recounting the rows" do
      rows = Array.new(Lain::Tools::Grep::MAX_MATCHES) { |i| { "path" => "a.rb", "line_number" => i + 1, "line" => "x" } }
      allow(client).to receive(:call).and_return(reply(rows, capped: true))

      result = tool.call(pattern: "x", path: tmpdir)

      expect(result.content.lines.grep(/^a\.rb:/).size).to eq(Lain::Tools::Grep::MAX_MATCHES)
      expect(result.content).to include("capped at #{Lain::Tools::Grep::MAX_MATCHES}")
    end

    it "turns a pattern the daemon's engine refuses into an error Result" do
      allow(client).to receive(:call)
        .and_raise(Lain::Core::Client::Refused, 'invalid pattern "(?=x)y": look-around ... is not supported')

      result = tool.call(pattern: "(?=x)y", path: tmpdir)

      expect(result).to have_attributes(is_error: true, content: /invalid pattern/)
      expect(result.content).to include("look-around")
    end

    # A refusal that is not about the pattern is a bug on THIS side (a param
    # spelled wrong, a daemon too old to know "grep"). Dressing it up as a
    # tool error would hand the model a message it cannot act on and hide the
    # defect; the handler turns the raise into an error Result anyway.
    it "re-raises a refusal that is not about the pattern" do
      allow(client).to receive(:call).and_raise(Lain::Core::Client::Refused, 'unknown method "grep"')

      expect { tool.call(pattern: "needle", path: tmpdir) }.to raise_error(Lain::Core::Client::Refused)
    end

    it "turns boundary death into an error Result naming it, never a raise past the loop" do
      allow(client).to receive(:call).and_raise(Lain::Core::Died.new("signal 9"))

      result = tool.call(pattern: "needle", path: tmpdir)

      expect(result).to be_error
      expect(result.content).to include("Lain::Core::Died", "signal 9")
    end

    it "still answers a missing path from this side, without a round trip" do
      allow(client).to receive(:call)

      result = tool.call(pattern: "needle", path: File.join(tmpdir, "nope"))

      expect(result).to have_attributes(is_error: true, content: /no such file or directory/)
      expect(client).not_to have_received(:call)
    end
  end
end
