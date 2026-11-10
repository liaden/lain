# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "LAIN_SEAM_REPORT" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:source) do
    <<~RUBY
      require "open3"
      RSpec.describe "untagged" do
        it("runs git") { 2.times { Open3.capture2e("git", "--version") } }
      end
      RSpec.describe "tagged", :seam do
        it("runs git") { Open3.capture2e("git", "--version") }
      end
    RUBY
  end

  def run_rspec(spec_source, report:)
    Dir.mktmpdir("seam_report") do |dir|
      path = File.join(dir, "git_user_spec.rb")
      File.write(path, spec_source)
      env = { "LAIN_SEAM_REPORT" => report ? "1" : nil }
      out, status = Open3.capture2e(env, RbConfig.ruby, "-S", "bundle", "exec", "rspec", path, "--format", "progress",
                                    chdir: root)
      [out, status, path]
    end
  end

  it "lists an untagged file that runs git with its count, and leaves the exit status alone",
     :aggregate_failures do
    out, status, path = run_rspec(source, report: true)

    expect(status).to be_success
    expect(out).to include("2 examples, 0 failures")
    expect(out).to match(/seam-report: \S*#{Regexp.escape(File.basename(path))} 2$/)
  end

  it "counts backticks, IO.popen and an explicit Kernel.spawn", :aggregate_failures do
    styles = <<~RUBY
      RSpec.describe "styles" do
        it("backtick") { `git --version` }
        it("popen") { IO.popen(["git", "--version"], &:read) }
        it("kernel spawn") { Process.wait(Kernel.spawn("git", "--version", out: File::NULL)) }
      end
    RUBY
    out, status, path = run_rspec(styles, report: true)

    expect(status).to be_success
    expect(out).to match(/seam-report: \S*#{Regexp.escape(File.basename(path))} 3$/)
  end

  it "does not list a file whose git runs sit under :seam", :aggregate_failures do
    out, = run_rspec(source, report: true)

    expect(out.scan("seam-report:").size).to eq(1)
  end

  it "prints nothing without the variable" do
    out, status, = run_rspec(source, report: false)

    expect(status).to be_success
    expect(out).not_to include("seam-report")
  end
end
