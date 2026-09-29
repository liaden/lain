# frozen_string_literal: true

# Spike measurement: journal bytes an image costs, inline vs digest reference.
# A session: user asks, model calls screenshot, tool_result carries a real
# 1280x800 PNG, then K more text exchanges. Each request is journaled as
# RequestSent; each turn once as a turn record.
require "lain"
require "tmpdir"

DIR = __dir__
shot = ARGV.fetch(0, "https___en_wikipedia_org_wiki_Ruby__progra.png")
png = File.binread(File.join(DIR, shot))
later_turns = Integer(ARGV.fetch(1, "10"))

def session(image_block, later_turns)
  timeline = Lain::Timeline.empty(store: Lain::Store.new)
  timeline = timeline.commit(role: :user, content: [{ "type" => "text", "text" => "screenshot the page" }])
  call = { "type" => "tool_use", "id" => "toolu_1", "name" => "screenshot", "input" => { "url" => "https://x" } }
  timeline = timeline.commit(role: :assistant, content: [call])
  result = Lain::Tool::ResultBlock.of(
    Lain::Tool::Result.ok([{ "type" => "text", "text" => "rendered at 1280x800" }, image_block]), tool_use_id: "toolu_1"
  ).to_h
  timeline = timeline.commit(role: :user, content: [result])
  later_turns.times do |i|
    timeline = timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => "answer #{i} " * 20 }])
    timeline = timeline.commit(role: :user, content: [{ "type" => "text", "text" => "follow-up #{i}" }])
  end
  timeline
end

def journal_bytes(timeline)
  context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024)
  toolset = Lain::Toolset.new([Lain::Tools::Screenshot.new])
  prefixes = timeline.to_a.each_index.select { |i| timeline.to_a[i].role == "user" }
  requests = prefixes.map do |i|
    head = timeline.to_a[i]
    context.render(timeline: timeline.checkout(head.digest), toolset:)
  end
  sent = requests.sum { |request| JSON.generate(Lain::Telemetry::RequestSent.from(request).to_journal).bytesize }
  turns = timeline.to_a.sum { |event| Lain::Canonical.dump(event.content).bytesize }
  [requests.size, sent, turns, requests.last]
end

Dir.mktmpdir("lain-measure") do |root|
  blobs = Lain::Image::Blobs.new(root:)
  inline = journal_bytes(session(Lain::Image.block(png), later_turns))
  reference = journal_bytes(session(blobs.reference(png), later_turns))
  text_only = journal_bytes(session({ "type" => "text", "text" => "(no image)" }, later_turns))
  puts "png=#{png.bytesize} base64=#{Lain::Image.block(png).dig("source", "data").bytesize} " \
       "anthropic_tokens(1280x800)=#{Lain::Image.anthropic_tokens(1280, 800)} later_turns=#{later_turns}"
  { "text-only" => text_only, "inline" => inline, "reference" => reference }.each do |label, (n, sent, turns, last)|
    wire = JSON.generate(blobs.inline(last.cache_payload)).bytesize
    puts format("%-10s requests=%2d request_sent_total=%10d turn_records_total=%8d last_wire_payload=%8d",
                label, n, sent, turns, wire)
  end
end
