# frozen_string_literal: true

# Does the anthropic SDK's param model accept an image inside a tool_result?
require "lain"
require "anthropic"

png = File.binread(File.join(__dir__, "probe.png"))
image = Lain::Image.block(png)
result = { "type" => "tool_result", "tool_use_id" => "toolu_1", "is_error" => false,
           "content" => [{ "type" => "text", "text" => "shot" }, image] }
messages = [{ "role" => "user", "content" => "x" },
            { "role" => "assistant",
              "content" => [{ "type" => "tool_use", "id" => "toolu_1", "name" => "s", "input" => {} }] },
            { "role" => "user", "content" => [result] }]
coerced = Anthropic::Internal::Type::Converter.coerce(
  Anthropic::Internal::Type::ArrayOf[Anthropic::MessageParam], JSON.parse(JSON.generate(messages), symbolize_names: true),
  state: { translate_names: true, strictness: true, exactness: { yes: 0, no: 0, maybe: 0 }, branched: 0 }
)
tool_result = coerced.last.content.first
puts tool_result.class
puts tool_result.content.map(&:class).inspect
dumped = Anthropic::Internal::Type::Converter.dump(Anthropic::Internal::Type::ArrayOf[Anthropic::MessageParam], coerced)
puts JSON.generate(dumped) == JSON.generate(JSON.parse(JSON.generate(messages)))
