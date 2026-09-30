# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "fileutils"

RSpec.describe Lain::CLI::Trust do
  around do |example|
    Dir.mktmpdir("lain-cli-trust") do |tmp|
      @tmp = tmp
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp }) }
  let(:output) { StringIO.new }

  def project(files)
    root = File.join(@tmp, "project")
    FileUtils.mkdir_p(File.join(root, ".lain"))
    files.each { |file, body| File.write(File.join(root, ".lain", file), body) }
    root
  end

  def trusted?(root)
    Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:, paths:), paths:).trusted?
  end

  def run(root, answer: nil, yes: false)
    described_class.new(root:, input: StringIO.new(answer.to_s), output:, paths:, yes:).call
  end

  it "shows every .lain/*.rb with its contents before asking" do
    root = project("summarizers.rb" => "summarizer 'coverage' do\nend\n", "services.rb" => "postgres\n")
    run(root, answer: "y\n")

    expect(output.string).to include(File.join(root, ".lain", "summarizers.rb"))
      .and include("summarizer 'coverage' do")
      .and include(File.join(root, ".lain", "services.rb"))
      .and include("postgres")
      .and include("[y/N]")
  end

  it "records the digest when the human confirms" do
    root = project("summarizers.rb" => "one\n")

    expect(run(root, answer: "y\n")).to include("trusted")
    expect(trusted?(root)).to be(true)
  end

  # A refusal, so `lain trust && lain chat` in a script stops at the decline.
  it "refuses, recording nothing, on anything but a yes, end of input included" do
    root = project("summarizers.rb" => "one\n")

    [nil, "\n", "n\n", "yes please\n"].each do |answer|
      expect { run(root, answer:) }.to raise_error(described_class::Declined, /not trusted/)
    end
    expect(described_class::Declined.ancestors).to include(Lain::Error)
    expect(trusted?(root)).to be(false)
  end

  it "says in the question that what the files require or load is not covered" do
    root = project("summarizers.rb" => "one\n")
    run(root, answer: "y\n")

    expect(output.string).to include("not what they require or load")
  end

  it "grants without reading input when told yes up front, which is how it runs headless" do
    root = project("summarizers.rb" => "one\n")
    input = instance_double(IO)
    allow(input).to receive(:gets)

    described_class.new(root:, input:, output:, paths:, yes: true).call

    expect(input).not_to have_received(:gets)
    expect(output.string).to include("one")
    expect(output.string).not_to include("[y/N]")
    expect(trusted?(root)).to be(true)
  end

  it "asks nothing of a project with no .lain/*.rb" do
    root = project("config.toml" => "[shell]\n")

    expect(run(root, answer: "y\n")).to include("nothing to trust")
    expect(output.string).not_to include("[y/N]")
  end

  it "asks nothing when these exact bytes are already trusted" do
    root = project("summarizers.rb" => "one\n")
    run(root, answer: "y\n")
    output.truncate(0)

    expect(run(root)).to include("already trusted")
    expect(output.string).not_to include("[y/N]")
  end

  # The human consents to what is shown, so a file must not be able to redraw
  # the terminal and hide a line from them.
  it "shows control characters escaped rather than letting them reach the terminal" do
    root = project("services.rb" => "postgres\n\e[1A\e[2Ksystem('rm -rf ~')\n")
    run(root, answer: "y\n")

    expect(output.string).not_to include("\e")
    expect(output.string).to include("\\e[1A\\e[2Ksystem('rm -rf ~')")
  end

  # A bidi override reorders what the human reads without changing what runs.
  it "shows format characters in the contents escaped" do
    root = project("services.rb" => "postgres # \u202E}\u2066 system('x')\n")
    run(root, answer: "y\n")

    expect(output.string).not_to match(/[\u202E\u2066]/)
    expect(output.string).to include("\\u202E}\\u2066 system('x')")
  end

  it "shows a file's name escaped in the listing and in the outcome" do
    root = project("\e[2Jevil.rb" => "one\n")
    outcome = run(root, answer: "y\n")

    expect(output.string + outcome).not_to include("\e")
    expect(outcome).to include("\\e[2Jevil.rb")
    expect(run(root)).to include("already trusted").and include("\\e[2Jevil.rb")
  end

  # The production construction: the ambient state home, read the way every
  # launch reads it, so the catalog the chat builds evaluates what was granted.
  it "lets the project's summarizers load once the human confirms" do
    root = File.join(@tmp, "app")
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(File.join(root, ".lain", "summarizers.rb"),
               "summarizer 'granted-#{object_id}' do\n  def suitable?(_) = true\n  def compact(_) = 'x'\nend\n")

    expect { Lain::Summarizer::Catalog.load(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
    described_class.new(root:, input: StringIO.new("y\n"), output:).call

    expect(Lain::Summarizer::Catalog.load(root:).map(&:name)).to eq(["granted-#{object_id}"])
  end
end
