# Reports card pairs sharing a file with no Depends-on path between them.
text = File.read(ARGV.fetch(0))
cards = text.split(/^### (?=T\d+:)/).drop(1).to_h do |chunk|
  id = chunk[/\AT(\d+)/, 1].to_i
  deps = chunk[/\*\*Depends on:\*\*(.*)/, 1].to_s.scan(/T(\d+)/).flatten.map(&:to_i)
  files_block = chunk[/\*\*Files:\*\*(.*?)\n\*\*Reuse/m, 1].to_s
  paths = files_block.scan(/`([^`]+)`/).flatten.flat_map do |p|
    p = p.sub(/ \(new.*\)\z/, "")
    if (m = p.match(/\A(.*)\{([^}]*)\}(.*)\z/)) then m[2].split(",").map { |x| "#{m[1]}#{x}#{m[3]}" } else [p] end
  end
  [id, { deps:, files: paths.reject { |p| p.include?("*") } }]
end
reach = ->(a, b, seen = {}) { cards[a][:deps].any? { |d| d == b || (!seen[d] && (seen[d] = true) && reach.(d, b, seen)) } }
pairs = cards.keys.combination(2).filter_map do |a, b|
  shared = cards[a][:files] & cards[b][:files]
  next if shared.empty? || reach.(a, b) || reach.(b, a)
  "T#{a} T#{b} PARALLEL #{shared.join(" ")}"
end
p cards.size, cards[14][:files].size, cards[37][:files].size, cards[9][:deps]; puts pairs, "#{pairs.size} PARALLEL"
