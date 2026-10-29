# Does a PrefixChain inside the purity battery's input change its inspect after one walk?
require "lain"
chain = Lain::Request::PrefixChain.new
req = Lain::Request.new(model: "m", max_tokens: 64,
                        messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi", "cache" => true }] }])
before = { chain: }.inspect
req.prefix_digests(chain:)
puts "inspect changed after a walk: #{before != { chain: }.inspect}"
puts "chain shareable: #{Ractor.shareable?(chain)}"
