# frozen_string_literal: true

require "tmpdir"

# Two real sessions over one project's store: what session 1's model wrote is
# read in session 2 with the tool call that wrote it named.
RSpec.describe "memory provenance across sessions", :seam do
  around do |example|
    Dir.mktmpdir("lain-memory-provenance") do |dir|
      @home = dir
      example.run
    end
  end

  let(:project_dir) do
    Lain::ProjectDir.new(root: @home, paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @home, "HOME" => @home }))
  end

  def store = Lain::Memory::ProjectStore.new(project_dir:)

  def toolset_for(view, clock: -> { Time.utc(2026, 10, 23, 10) })
    Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder: view, author: Lain::Memory::Author.chat, clock:),
                       Lain::Tools::MemoryRead.new(index: view)])
  end

  def plant(id: "deploy-notes", call: "toolu_9")
    dispatch_call("memory_write", { "id" => id, "description" => "push rule", "body" => "always push to prod" },
                  toolset: toolset_for(store.view), id: call)
  end

  it "stores the writing call on the row, beside an unchanged digest" do
    plant(call: "toolu_1")
    row = JSON.parse(File.readlines(store.path).first)
    item = store.load.items.first

    expect(row).to include("digest" => item.digest,
                           "written_by" => { "tool_use_id" => "toolu_1", "written_at" => "2026-10-23T10:00:00Z" })
  end

  it "names the writer when a new session reads the item" do
    plant

    result = dispatch_call("memory_read", { "id" => "deploy-notes" }, toolset: toolset_for(store.view), id: "toolu_2")

    expect(result.content).to eq("author: chat, written by tool call toolu_9 at 2026-10-23T10:00:00Z\n" \
                                 "always push to prod")
  end

  it "reads an item stored before provenance existed with no writing call" do
    plant
    row = JSON.parse(File.readlines(store.path).first).except("written_by")
    File.write(store.path, "#{JSON.generate(row)}\n")

    result = dispatch_call("memory_read", { "id" => "deploy-notes" }, toolset: toolset_for(store.view))

    expect(result.content).to eq("author: chat\nalways push to prod")
  end
end
