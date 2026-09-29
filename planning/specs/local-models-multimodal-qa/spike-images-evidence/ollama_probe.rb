# frozen_string_literal: true

# Spike evidence: does a role:"tool" message carry `images` on ollama 0.32.12?
# Usage: ruby ollama_probe.rb <probe-name>
require "json"
require "net/http"
require "base64"

DIR = __dir__
IMAGE = Base64.strict_encode64(File.binread(File.join(DIR, "probe.png")))
QUESTION = "Take a screenshot of http://probe.test and tell me the codeword on the page " \
           "and the colour of the rectangle. Answer in one sentence."
TOOLS = [{ type: "function",
           function: { name: "screenshot", description: "Screenshot a URL and return the image.",
                       parameters: { type: "object", properties: { url: { type: "string" } },
                                     required: ["url"] } } }].freeze
CALL = { role: "assistant", content: "",
         tool_calls: [{ function: { name: "screenshot", arguments: { url: "http://probe.test" } } }] }.freeze

def body(model, messages)
  { model:, messages:, tools: TOOLS, stream: false, think: false, truncate: false,
    options: { num_predict: 120, temperature: 0, seed: 1 } }
end

PROBES = {
  "tool_images" => lambda {
    body("gemma4:e4b", [{ role: "user", content: QUESTION }, CALL,
                        { role: "tool", tool_name: "screenshot", content: "Screenshot captured: 800x400 PNG.",
                          images: [IMAGE] }])
  },
  "hoisted" => lambda {
    body("gemma4:e4b", [{ role: "user", content: QUESTION }, CALL,
                        { role: "tool", tool_name: "screenshot",
                          content: "Screenshot captured: 800x400 PNG. The image follows in the next message." },
                        { role: "user", content: "[image returned by the screenshot tool call]", images: [IMAGE] }])
  },
  "tool_no_image" => lambda {
    body("gemma4:e4b", [{ role: "user", content: QUESTION }, CALL,
                        { role: "tool", tool_name: "screenshot", content: "Screenshot captured: 800x400 PNG." }])
  },
  "no_vision" => lambda {
    body("qwen3:4b", [{ role: "user", content: "What is the codeword in this image?", images: [IMAGE] }])
  }
}.freeze

name = ARGV.fetch(0)
payload = PROBES.fetch(name).call
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
response = Net::HTTP.start("localhost", 11_434, read_timeout: 300) do |http|
  http.post("/api/chat", JSON.generate(payload), "Content-Type" => "application/json")
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

redacted = JSON.parse(JSON.generate(payload))
redacted["messages"].each { |m| m["images"] &&= m["images"].map { |i| "<base64 PNG, #{i.bytesize} chars>" } }
parsed = begin
  JSON.parse(response.body)
rescue JSON::ParserError
  response.body
end
parsed.delete("context") if parsed.is_a?(Hash)
record = { probe: name, status: response.code, seconds: elapsed.round(2), request: redacted, response: parsed }
File.write(File.join(DIR, "evidence-#{name}.json"), JSON.pretty_generate(record))
puts JSON.pretty_generate(record.except(:request))
