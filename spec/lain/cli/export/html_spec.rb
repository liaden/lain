# frozen_string_literal: true

RSpec.describe Lain::CLI::Export::Html do
  def turn(digest, role, content, parent: nil)
    { "type" => "turn", "digest" => digest, "role" => role, "content" => content, "parent" => parent, "meta" => {} }
  end

  def text(string) = { "type" => "text", "text" => string }

  def render(records, released: 0, **scrub) = described_class.new(records:, released:, **scrub).render

  let(:chain) do
    [turn("d1", "user", [text("first")]),
     turn("d2", "assistant",
          [{ "type" => "tool_use", "id" => "t1", "name" => "bash", "input" => { "command" => "ls" } }], parent: "d1"),
     turn("d3", "user", [{ "type" => "tool_result", "tool_use_id" => "t1", "content" => "out.txt" }], parent: "d2")]
  end

  it "lists every turn in chain order with role, text, tool name and result" do
    html = render(chain)

    expect(html.scan(/first|bash|out\.txt/)).to eq(%w[first bash out.txt])
    expect(html).to include("user", "assistant")
  end

  it "escapes a script-shaped tool result into text" do
    html = render([turn("d1", "user",
                        [{ "type" => "tool_result", "tool_use_id" => "t", "content" => "<script>x()</script>" }])])

    expect(html).not_to include("<script>")
    expect(html).to include("&lt;script&gt;")
  end

  it "escapes markup and quotes in every interpolated session value" do
    hostile = %(<script>alert(1)</script> "onmouseover="x)
    html = render([turn("d1", %(user" onclick="y), [text(hostile), { "type" => %(odd" onload="z) }])])

    expect(html).not_to include("<script>", %(" onclick="), %(" onload="), %(" onmouseover="))
    expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;", "&quot;onmouseover=&quot;x")
  end

  it "rewrites the home and project prefixes wherever they appear" do
    records = [turn("d1", "assistant",
                    [{ "type" => "tool_use", "id" => "t", "name" => "read_file",
                       "input" => { "path" => "/home/u/proj/a.rb" } }, text("see /home/u/.ssh/x")]),
               turn("d2", "user", [{ "type" => "tool_result", "tool_use_id" => "t", "content" => "/home/u/proj/a.rb" }],
                    parent: "d1")]
    html = render(records, home: "/home/u", root: "/home/u/proj")

    expect(html).to include("&lt;project&gt;/a.rb", "~/.ssh/x")
    expect(html).not_to include("/home/u")
  end

  def scrub_one(path, **scrub) = render([turn("d1", "user", [text(path)])], **scrub)

  it "leaves a longer name sharing the home prefix alone" do
    expect(scrub_one("/home/tarantino/x and /home/tara/y", home: "/home/tara")).to include("/home/tarantino/x", "~/y")
  end

  it "scrubs only at a path boundary" do
    html = scrub_one("/mnt/real/home/tara/x cd=/home/tara/z (/home/tara) \"/home/tara/q\"", home: "/home/tara")

    expect(html).to include("/mnt/real/home/tara/x", "cd=~/z", "(~)", "&quot;~/q&quot;")
  end

  it "scrubs the realpath form of the home as well as the given one" do
    Dir.mktmpdir do |dir|
      real = File.realpath(FileUtils.mkdir_p(File.join(dir, "real")).first)
      link = File.join(dir, "link")
      File.symlink(real, link)

      expect(scrub_one("#{real}/a #{link}/b", home: link)).to include("~/a", "~/b")
    end
  end

  it "scrubs the longer prefix first and skips a prefix under 2 characters" do
    html = scrub_one("/home/u/proj/a /home/u/b", home: "/home/u", root: "/home/u/proj")

    expect(html).to include("&lt;project&gt;/a", "~/b")
    expect(scrub_one("/etc/x", home: "/", root: "/")).to include("/etc/x")
  end

  it "renders only the conversation, never header fields" do
    header = { "type" => "session", "system" => "SYSTEM-PROMPT-TEXT" }

    expect(render([header, *chain])).not_to include("SYSTEM-PROMPT-TEXT")
  end

  it "renders image parts of a tool result as omitted rows" do
    result = { "type" => "tool_result", "tool_use_id" => "t",
               "content" => [{ "type" => "image", "source" => { "data" => "AAAA" } }, text("caption")] }
    html = render([turn("d1", "user", [result])])

    expect(html).to include("[omitted: image]", "caption")
    expect(html).not_to include("AAAA")
  end

  it "wraps a bare Hash content and tolerates non-Hash elements" do
    html = render([turn("d1", "user", text("lone")), turn("d2", "user", ["plain", 4], parent: "d1")])

    expect(html).to include("lone", "plain", "4")
  end

  it "counts source, command and search redactions in the footer" do
    redactions = [{ "type" => "source_masked", "regions" => 1 }, { "type" => "command_redacted", "regions" => 2 },
                  { "type" => "search_redacted", "regions" => 4 }]

    expect(render([*chain, *redactions])).to include("7 regions were masked")
  end

  it "puts the elision marker where the cut was recorded" do
    cut = { "type" => "compaction_cut", "collapses" => [{ "span" => [0, 4], "content" => [text("sum")] }] }
    html = render([chain[0], cut, chain[1]])

    expect(html.index("first")).to be < html.index("elided")
    expect(html.index("elided")).to be < html.index("bash")
  end

  it "counts masked regions in the footer and says nothing was re-scanned" do
    masked = { "type" => "source_masked", "tool_use_id" => "t1", "kind" => "file", "key" => ".env", "regions" => 3 }
    html = render([*chain, masked])

    expect(html).to include("3 regions", "&lt;redacted:n&gt;", "not re-scanned")
  end

  it "says how many regions were released when there are any" do
    expect(render(chain, released: 2)).to include("2 regions were released")
    expect(render(chain)).not_to include("released")
  end

  it "renders an omitted row for a block type it has no row for" do
    html = render([turn("d1", "assistant", [{ "type" => "redacted_thinking", "data" => "opaque" }])])

    expect(html).to include("[omitted: redacted_thinking]")
    expect(html).not_to include("opaque")
  end

  it "follows a rewind to the chain the head ends on" do
    other = turn("d9", "user", [text("branch")], parent: "d1")
    rewound = { "type" => "rewound", "from" => "d3", "to" => "d1" }
    html = render([*chain, rewound, other])

    expect(html).to include("branch")
    expect(html).not_to include("out.txt")
  end
end
