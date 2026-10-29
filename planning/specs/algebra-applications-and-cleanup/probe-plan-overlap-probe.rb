# Reads the plan, expands each card's Files, and reports file overlaps between
# cards with no dependency path between them, plus graph-vs-Depends-on drift.
text = File.read(ARGV.fetch(0))
cards = text.split(/^### (?=T\d+:)/).drop(1)
files = {}; deps = {}
cards.each do |c|
  id = c[/\AT\d+/]
  deps[id] = (c[/\*\*Depends on:\*\*(.*)$/, 1] || "").scan(/T\d+/)
  block = c[/\*\*Files:\*\*(.*?)\n\*\*Reuse/m, 1].to_s
  paths = block.scan(/`([^`]+)`/).flatten.flat_map do |p|
    p =~ /\{([^}]*)\}/ ? $1.split(",").map { |x| p.sub(/\{[^}]*\}/, x) } : [p]
  end
  files[id] = paths.map { |p| p.sub(/ \(new.*/, "") }
end
reach = ->(a, seen = {}) { deps[a].each { |d| next if seen[d]; seen[d] = true; reach.(d, seen) }; seen }
ids = files.keys
ids.combination(2).each do |a, b|
  shared = files[a] & files[b]
  next if shared.empty?
  ordered = reach.(a).key?(b) || reach.(b).key?(a)
  puts "#{ordered ? "chained " : "PARALLEL"} #{a} #{b}: #{shared.join(", ")}"
end
graph = text[/```mermaid(.*?)```/m, 1]
edges = graph.scan(/(T\d+)\s*-->\s*(T\d+)/) + graph.scan(/T\d+(?:\s*-->\s*T\d+)+/).flat_map { |l| l.scan(/T\d+/).each_cons(2).to_a }
edges = edges.uniq.map { |a, b| [b, a] }
declared = deps.flat_map { |k, v| v.map { |d| [k, d] } }
puts "in graph not in Depends on: #{(edges - declared).inspect}"
puts "in Depends on not in graph: #{(declared - edges).inspect}"
