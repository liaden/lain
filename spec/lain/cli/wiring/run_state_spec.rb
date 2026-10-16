# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::CLI::Wiring::RunState do
  around do |example|
    Dir.mktmpdir("wiring-run-state") do |state|
      @state = File.realpath(state)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:root) { File.join(@state, "project").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:chat_env) { Lain::WorkerEnv.default.with(cwd: root) }
  let(:notices) { [] }
  let(:state) do
    described_class.new(root:, paths:, notice: notices.method(:push), chat_env:, chronicle: Lain::CLI::Chronicle::Null.new)
  end
  let(:item) { Lain::Memory::Item.new(id: "elsewhere", description: "d", body: "b") }
  let(:resumed_class) { Data.define(:recorder, :session) }

  def resumed_over(recorder) = resumed_class.new(recorder:, session: Lain::Session.new)

  def store = Lain::Memory::ProjectStore.new(project_dir: Lain::ProjectDir.new(root:, paths:))

  describe "#run_state" do
    it "builds a fresh recorder and a session seated at the chat's environment" do
      recorder, session = state.run_state(nil)

      expect(recorder).to be_a(Lain::Memory::Recorder)
      expect(session.worker_env).to be(chat_env)
    end

    it "keeps a resumed session and points it at the re-opened view" do
      session = Lain::Session.new(memory: store.view)
      resumed = resumed_class.new(recorder: store.view, session:)

      recorder, restored = state.run_state(resumed)
      recorder.write(item)

      expect(restored).to be(session)
      expect(restored.reminders.join).to include("elsewhere")
    end
  end

  describe "#memory_notices" do
    it "tells a fresh chat nothing" do
      recorder, = state.run_state(nil)

      expect(state.memory_notices(recorder, nil)).to eq([])
    end

    it "counts the entries written since a resumed view was recorded" do
      resumed = resumed_over(store.view)
      recorder, = state.run_state(resumed)
      store.view.write(item)

      expect(state.memory_notices(recorder, resumed).join).to include("1 entry newer")
    end
  end

  it "opens one project store per run" do
    expect(state.project_memory).to be(state.project_memory)
  end
end
