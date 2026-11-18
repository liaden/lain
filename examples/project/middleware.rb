# frozen_string_literal: true

# .lain/config.rb with your own middleware. Each runs outermost in its area.
# Keep them cheap: a middleware that blocks stalls every agent in the chat.

# Adds a tag to every model request's env, for the layers beneath it to read.
class TagRequests < Lain::Middleware::Base
  def initialize(tag:)
    super()
    @tag = tag
  end

  def call(env, &app) = downstream(env.merge(tag: @tag), &app)
end

middleware do
  model TagRequests, tag: "home"
  tool { |env, &downstream| downstream.call(env) }
  turn { |env, &downstream| downstream.call(env) }
end
