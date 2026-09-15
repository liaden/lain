# frozen_string_literal: true

require "tmpdir"

# A read licenses an edit only while the turn that delivered it is on the chain
# the edit runs on, and several windows the model saw add up to a whole read.
#
# Each unit can pass alone and the joint still fail: the tool records a read, the
# delivery binds it to a turn, `Agent#rewind` moves the head, and the edit's
# contract asks the Session about a chain it never saw. So everything here is
# real -- Agent, Session, ReadFile, EditFile, the Timeline -- and only the model
# is scripted.
RSpec.describe "a read the model no longer sees", :seam do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:session) { Lain::Session.new }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new]) }

  around do |example|
    Dir.mktmpdir("lain-unseen-read") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  def notes(lines = 900)
    File.join(dir, "notes.rb").tap do |path|
      File.write(path, (1..lines).map { |number| "line #{number}\n" }.join)
    end
  end

  def agent(responses)
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), toolset:, context:, session:)
  end

  def read(id, path, **window)
    tool_response([id, "read_file", { "path" => path }.merge(window.transform_keys(&:to_s))])
  end

  def edit(id, path)
    tool_response([id, "edit_file", { "path" => path, "old_string" => "line 900\n",
                                      "new_string" => "line nine hundred\n" }])
  end

  def result_of(agent, id)
    agent.timeline.ancestors.flat_map(&:content).find { |block| block["tool_use_id"] == id }
  end

  it "refuses an edit once the read's tool round is rewound off the chain" do
    path = notes
    run = agent([read("tu_read", path), text_response("read it"), edit("tu_edit", path), text_response("tried")])
    run.ask("read notes.rb")
    run.rewind(run.timeline.length)

    run.ask("now edit it")

    expect(result_of(run, "tu_edit")).to include("is_error" => true)
    expect(result_of(run, "tu_edit")["content"]).to include("was never read in this conversation")
    expect(File.read(path)).to include("line 900\n")
  end

  it "still allows the edit while the read's tool round stays on the chain" do
    path = notes
    run = agent([read("tu_read", path), text_response("read it"), edit("tu_edit", path), text_response("done")])
    run.ask("read notes.rb")

    run.ask("now edit it")

    expect(result_of(run, "tu_edit")).to include("is_error" => false)
    expect(File.read(path)).to include("line nine hundred\n")
  end

  it "applies an edit over two delivered windows that together cover the file" do
    path = notes
    run = agent([read("tu_top", path, offset: 1, limit: 450), text_response("top"),
                 read("tu_bottom", path, offset: 451, limit: 450), text_response("bottom"),
                 edit("tu_edit", path), text_response("done")])
    run.ask("read the top half")
    run.ask("read the bottom half")

    run.ask("now edit it")

    expect(result_of(run, "tu_edit")).to include("is_error" => false)
    expect(File.read(path)).to include("line nine hundred\n")
  end

  it "refuses as a partial read when the file changed between the two windows" do
    path = notes
    run = agent([read("tu_top", path, offset: 1, limit: 450), text_response("top"),
                 read("tu_bottom", path, offset: 451, limit: 450), text_response("bottom"),
                 edit("tu_edit", path), text_response("tried")])
    run.ask("read the top half")
    File.write(path, File.read(path).sub("line 1\n", "line one\n"))
    run.ask("read the bottom half")

    run.ask("now edit it")

    expect(result_of(run, "tu_edit")).to include("is_error" => true)
    expect(result_of(run, "tu_edit")["content"]).to include("only part of #{path} was read")
  end

  # The windows add up only on one chain: rewinding past the second leaves the
  # first standing, which is a partial read, not an unread file.
  it "refuses as a partial read once the second window is rewound away" do
    path = notes
    run = agent([read("tu_top", path, offset: 1, limit: 450), text_response("top"),
                 read("tu_bottom", path, offset: 451, limit: 450), text_response("bottom"),
                 edit("tu_edit", path), text_response("tried")])
    run.ask("read the top half")
    run.ask("read the bottom half")
    run.rewind(4)

    run.ask("now edit it")

    expect(result_of(run, "tu_edit")["content"]).to include("only part of #{path} was read")
    expect(File.read(path)).to include("line 900\n")
  end

  # Through the ceiling: a file too large for one result is refused whole, and
  # two windows under the ceiling that cover it are what license the edit.
  describe "a file over the result ceiling" do
    let(:ceiling) { Lain::Tool::Bounds::CEILINGS.fetch("read_file") }

    def source(lines = 900)
      File.join(dir, "service.rb").tap do |path|
        rows = (1..lines).map { |number| format("line %<number>-3d %<padding>s\n", number:, padding: "x" * 24) }
        File.write(path, rows.join)
      end
    end

    def edit_last(id, path)
      tool_response([id, "edit_file", { "path" => path, "old_string" => "line 900 ",
                                        "new_string" => "line nine hundred " }])
    end

    it "refuses the whole read and the edit that follows it alone" do
      path = source
      run = agent([read("tu_whole", path), text_response("refused"),
                   edit_last("tu_edit", path), text_response("tried")])
      run.ask("read service.rb")

      run.ask("now edit it")

      expect(File.size(path)).to be_between(ceiling + 1, 2 * ceiling)
      expect(result_of(run, "tu_whole")).to include("is_error" => true)
      expect(result_of(run, "tu_edit")).to include("is_error" => true)
      expect(File.read(path)).not_to include("line nine hundred")
    end

    it "applies the edit over two delivered windows, each under the ceiling, that cover the file" do
      path = source
      expect(File.readlines(path).first(450).join.bytesize).to be < ceiling
      run = agent([read("tu_top", path, offset: 1, limit: 450), text_response("top"),
                   read("tu_bottom", path, offset: 451, limit: 450), text_response("bottom"),
                   edit_last("tu_edit", path), text_response("done")])
      run.ask("read the top half")
      run.ask("read the bottom half")

      run.ask("now edit it")

      expect([result_of(run, "tu_top"), result_of(run, "tu_bottom")]).to all(include("is_error" => false))
      expect(result_of(run, "tu_edit")).to include("is_error" => false)
      expect(File.read(path)).to include("line nine hundred")
    end
  end
end
