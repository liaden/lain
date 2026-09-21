# frozen_string_literal: true

module Lain
  # A model's reply, in Lain's vocabulary. Providers translate into this; nothing
  # downstream ever touches a provider's own response type.
  #
  # `content` holds the FULL block list -- text, thinking and tool_use alike --
  # in normalized wire form, and the whole of it is what gets appended to the
  # Timeline. Extracting just the text and discarding thinking or tool_use blocks
  # corrupts the very next turn.
  #
  # `raw` carries the provider's own object for debugging and is deliberately not
  # part of #digest.
  Response = Data.define(:id, :model, :content, :stop_reason, :usage, :raw) do
    def initialize(content:, stop_reason:, id: nil, model: nil, usage: Usage.zero, raw: nil)
      super(
        id: id&.to_s&.freeze,
        model: model&.to_s&.freeze,
        content: Canonical.normalize(content),
        stop_reason: StopReason.normalize(stop_reason),
        usage:,
        raw:
      )
    end

    def blocks_of_type(type)
      content.select { |block| block["type"] == type.to_s }
    end

    # Every tool_use block, lensed by {ToolUse}, with `input` already a parsed
    # Hash -- which the Provider guarantees: on Anthropic's STREAMING path with
    # raw-hash tool schemas `tool_use.input` arrives as a raw JSON String, while
    # non-streaming `create` returns it parsed, and nothing above the Provider
    # should have to know that.
    #
    # `ToolUse` is spelled through `Response::` because a method body inside a
    # `Data.define` block resolves constants against its LEXICAL scope (`Lain`),
    # not the Data class -- the trap that sends `Request::SYSTEM_PREFIX` into a
    # reopened class body.
    def tool_uses
      blocks_of_type("tool_use").map { |block| Response::ToolUse.wrap(block) }
    end

    def tool_use?
      stop_reason == StopReason::TOOL_USE
    end

    def text
      blocks_of_type("text").map { |block| block["text"] }.join
    end

    def digest
      Canonical.digest({ "content" => content, "stop_reason" => stop_reason.to_s })
    end

    # Counts blocks rather than #tool_uses, which would allocate a lens per block
    # to reach a number, on the very path something has already gone wrong on.
    def to_s
      "#<Lain::Response #{stop_reason} blocks=#{content.size} tools=#{blocks_of_type("tool_use").size}>"
    end
    alias_method :inspect, :to_s
  end
end

# After the Data.define: the lens reopens `Response`, which has to exist first.
