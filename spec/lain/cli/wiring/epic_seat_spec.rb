# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The one mount a chat is seated in, read by the toolset and by the editor's
# lain://status. The state home is swapped through the environment because the
# mount resolves its home through a defaulted `Paths.new`, and so must the fold.
RSpec.describe Lain::CLI::Wiring::EpicSeat do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      saved = ENV.fetch("XDG_STATE_HOME", nil)
      ENV["XDG_STATE_HOME"] = File.join(tmp, "state")
      example.run
    ensure
      ENV["XDG_STATE_HOME"] = saved
    end
  end

  def root = File.join(@tmp, "project")

  def seat(options = {})
    described_class.new(chronicle: Lain::CLI::Chronicle::Null.new, options:, notify: nil, root:, replies: -> {})
  end

  def write_demo
    graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "the a issue")])
    config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
    Lain::Epic::Home.resolve(config:, paths: Lain::Paths.new, root:, slug: "demo").write_epic(graph)
  end

  it "mounts once, so the toolset and the editor read the same mount" do
    write_demo
    seated = seat

    expect(seated.mount).to be_a(Lain::CLI::EpicMount).and(equal(seated.mount))
    expect(seated.mount.slug).to eq("demo")
  end

  it "tells the notice why a mount was abandoned, on the first call only" do
    heard = []
    seated = seat(epic: "nope")

    2.times { seated.mount(->(message) { heard << message }) }

    expect(heard.size).to eq(1)
    expect(heard.first).to include("request_review is not wired")
  end

  it "hands the editor the mounted epic, folded from the root the mount resolved" do
    write_demo

    expect(seat.status.lines).to include("# epic `demo`", a_string_including("`a` the a issue"))
  end

  it "hands the editor the unmounted null when the chat is in no epic" do
    expect(seat.status).to equal(Lain::Frontend::Neovim::StatusView::Unmounted)
  end
end
