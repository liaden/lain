# frozen_string_literal: true

# Spike: one real lain Agent turn loop -- Provider::Ollama (gemma4:e4b) + the
# screenshot tool driving real headless Chromium against a local page -- and
# the journal bytes it leaves. Two model calls.
require "lain"
require "socket"
require "stringio"
require "tmpdir"

DIR = __dir__
page = File.read(File.join(DIR, "probe.html"))
server = TCPServer.new("127.0.0.1", 0)
Thread.new do
  loop do
    client = server.accept
    client.readpartial(4096)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{page.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{page}")
    client.close
  rescue IOError, SystemCallError
    nil
  end
end
url = "http://127.0.0.1:#{server.addr[1]}/"

io = StringIO.new
journal = Lain::Journal.new(io:)
provider = Lain::Provider::Ollama.local(journal:)
puts "vision(gemma4:e4b) = #{provider.vision("gemma4:e4b").answer}"
toolset = Lain::Toolset.new([Lain::Tools::Screenshot.new])
context = Lain::Context.new(model: "gemma4:e4b", max_tokens: 200)
middleware = Lain::Middleware::Stack.new([Lain::Middleware::Sensitivity.new,
                                          Lain::Middleware::Gate.new(policy: Lain::Middleware::Gate::ApproveAll.new)])
agent = Lain::Agent.new(provider:, context:, toolset:, journal:, tool_middleware: middleware)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
response = agent.ask("Use the screenshot tool on #{url} at width 800 and height 400, then tell me the codeword " \
                     "written on the page and the colour of the rectangle, in one sentence.")
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts "answer: #{response.text rescue response.content.inspect[0, 300]}"
puts "seconds: #{elapsed.round(2)}"
lines = io.string.lines.map { |line| JSON.parse(line) }
lines.each do |record|
  puts format("%-22s %8d bytes", record["type"], JSON.generate(record).bytesize)
end
turns = agent.timeline.to_a
turns.each do |event|
  images = Lain::Image.each_in(event.content).count
  puts format("turn %-9s %8d canonical bytes, %d image(s)", event.role, Lain::Canonical.dump(event.content).bytesize,
              images)
end
File.write(File.join(DIR, "e2e-journal.ndjson"), io.string)
