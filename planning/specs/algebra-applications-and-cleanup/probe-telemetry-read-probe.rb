# Builds the generic reader T1 describes (camelize the type, settle through the
# carrier with symbolised keys) and runs it over every fixture session line.
require "lain"
require "json"
counts = Hash.new(0)
Dir["spec/fixtures/sessions/**/*.ndjson"].each do |path|
  File.foreach(path) do |line|
    hash = JSON.parse(line)
    type = hash["type"]
    klass = (Lain::Telemetry.const_get(type.camelize) rescue nil)
    carrier = klass && (Lain::Telemetry::Carriers.const_get(type.camelize, false) rescue nil)
    unless carrier
      counts["no record class or carrier: #{type}"] += 1
      next
    end
    attrs = hash.except("type").transform_keys(&:to_sym)
    begin
      carrier.settle!(**attrs)
      counts["settled: #{type}"] += 1
    rescue StandardError => e
      counts["#{e.class.name.split("::").last}: #{type}: #{e.message[0, 90]}"] += 1
    end
  end
end
counts.sort.each { |k, v| puts "#{v}\t#{k}" }
