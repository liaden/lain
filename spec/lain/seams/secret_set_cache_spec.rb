# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The board's one secret source keeps its set while nothing it is built from
# moved, so the asks of 1 call share a build, and still masks a value the call
# itself wrote.
RSpec.describe "the board's secret set across the asks of 1 call", :seam do
  around do |example|
    Dir.mktmpdir("secret-set-cache") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "repo")
      FileUtils.mkdir_p(@home)
      SeedRepo.derived("secret-set-cache committed env", into: @root) do |seed|
        File.write(File.join(seed, ".env"), "DB_PASSWORD=OLDVALUE123456\n")
        SeedRepo.git(seed, "add", ".env")
        SeedRepo.git(seed, "commit", "-q", "-m", "add env")
      end
      example.run
    end
  end

  let(:dotenv) { File.join(@root, ".env") }

  # Well past every stamp, so no take is racy and only a moved stamp rebuilds.
  before do
    allow(Lain::Sensitivity::HistoryLiterals).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options, wall: -> { Time.now + 3600 })
    end
  end

  # A write within the tick of the last one keeps its stamp, so the rewrite is dated plainly apart from it.
  def rewrite(bytes)
    File.write(dotenv, bytes)
    File.utime(Time.now - 600, Time.now - 600, dotenv)
  end

  def board_secrets
    project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
    policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @root, root: @root), home: @home, root: @root
    )
    Lain::CLI::Wiring::BoardBuild.secrets(project:, sensitivity: policy, child_env: Lain::Exec::ChildEnv.new(env: {}))
  end

  it "builds once for a call's approval, announcer start, output scan and announcer end" do
    secrets = board_secrets
    allow(Lain::Sensitivity::Secrets).to receive(:for).and_call_original

    asks = Array.new(4) { secrets.for(nil) }

    expect(asks).to all(include("OLDVALUE123456"))
    expect(Lain::Sensitivity::Secrets).to have_received(:for).once
  end

  it "masks a value the call wrote to .env in that call's output" do
    secrets = board_secrets
    secrets.for(nil)
    rewrite("DB_PASSWORD=NEWVALUE654321\n")

    shown = Lain::Sensitivity::TextMask.text("NEWVALUE654321\n", secrets: secrets.for(nil))

    expect(shown).to match(Lain::Sensitivity::Regions::PLACEHOLDER_SHAPE).and(not_include("NEWVALUE654321"))
  end

  it "sees .env rewritten in place with a new value of the same length" do
    secrets = board_secrets
    secrets.for(nil)
    rewrite("DB_PASSWORD=SAMELEN0000001\n")

    expect(secrets.for(nil)).to include("SAMELEN0000001")
  end
end
