# frozen_string_literal: true

require "erb"
require "net/http"
require "uri"

module Lain
  module Remote
    # Announces a waiting item on an ntfy topic, so the phone buzzes and its one
    # action opens the lain-remote app, where every answer is given. The relay
    # grows no HTTP surface for this: the notice carries a title and a link and
    # nothing else, so neither the item's text nor the relay's token can reach
    # a topic that is, to ntfy, a shared name.
    class Ntfy
      # The topic's server answered something other than success.
      class Refused < Error; end

      # What announcing nothing looks like, for a chat with no `remote ntfy:`.
      class Null
        def notify(_item) = nil

        INSTANCE = new.freeze
      end

      KINDS = {
        Agenda::ParkedCall => "approval",
        Agenda::GateQuestion => "gate question",
        Agenda::Question => "question"
      }.freeze

      # A dead topic server must cost the surface one failed announcement, so the wait is short.
      DEFAULT_TIMEOUT = 5

      # @param url [String] the topic, `http(s)://host:port/topic`
      # @param timeout [Numeric] seconds each of connecting, writing and reading may take
      def initialize(url:, timeout: DEFAULT_TIMEOUT)
        @uri = URI(url)
        @timeout = timeout
      end

      # @param item [Agenda::ParkedCall, Agenda::GateQuestion, Agenda::Question] the masked view
      #   of what waits, under the id the phone's app knows it by
      # @return [void]
      # @raise [Refused] when the server turns the notice away
      # @raise [Timeout::Error, SystemCallError] when the server is slow or not there
      def notify(item)
        response = http.post(@uri.request_uri, "Open lain-remote to answer.", headers(item))
        raise Refused, "ntfy answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end

      private

      def http
        Net::HTTP.new(@uri.host, @uri.port).tap do |http|
          http.use_ssl = @uri.scheme == "https"
          http.open_timeout = http.read_timeout = http.write_timeout = @timeout
        end
      end

      def headers(item)
        { "Title" => title(item), "Actions" => "view, Open, lain-remote://item/#{ERB::Util.url_encode(item.id)}" }
      end

      # A requester is model-influenced text and a header is one line of ASCII.
      def title(item) = "lain #{KINDS.fetch(item.class)} waiting on #{item.requester}".gsub(/[^\x20-\x7E]/, "?")
    end
  end
end
