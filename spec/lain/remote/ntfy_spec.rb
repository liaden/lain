# frozen_string_literal: true

require "socket"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module NtfySpecSupport
  # A one-shot HTTP server on loopback: records the request it is sent, then
  # answers with `status`, or never answers when `status` is nil.
  class Stub
    Request = Struct.new(:verb, :path, :headers, :body)

    attr_reader :request

    # Serves for the block, with the loopback port it binds open to the suite's offline posture.
    def self.serve(status: 200)
      stub = new(status:)
      NetworkAccess.permit_loopback(stub.port) { yield stub }
    ensure
      stub&.stop
    end

    def initialize(status: 200)
      @server = TCPServer.new("127.0.0.1", 0)
      @status = status
      @thread = Thread.new { serve }
    end

    def port = @server.addr[1]

    def url = "http://127.0.0.1:#{port}/lain-x7"

    def stop
      @thread.kill
      @server.close
    end

    def wait = @thread.join(5) && request

    private

    def serve
      @client = @server.accept
      @request = read(@client)
      @client.write("HTTP/1.1 #{@status} Stub\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") if @status
      @status ? @client.close : sleep
    end

    def read(socket)
      verb, path = socket.gets.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.chomp.split(": ", 2)
        headers[name.downcase] = value
      end
      Request.new(verb, path, headers, socket.read(headers.fetch("content-length", "0").to_i))
    end
  end
end

RSpec.describe Lain::Remote::Ntfy do
  let(:call) do
    Lain::Remote::Agenda::ParkedCall.new(id: "ab12-call-1", requester: "agent", tool: "bash",
                                         input: { "command" => "rm -rf build" }, cwd: "/work/repo",
                                         why: "deletes the build directory", asked_at: Time.at(0), releases: 0)
  end
  let(:gate) do
    Lain::Remote::Agenda::GateQuestion.new(id: "g", requester: "gate", epic: "e", stage: "plan", issues: [],
                                           question: "sign off?", asked_at: Time.at(0), releases: 0)
  end
  let(:question) do
    Lain::Remote::Agenda::Question.new(id: "q", requester: "agent", question: "which one?", options: [],
                                       asked_at: Time.at(0), releases: 0)
  end

  # The request one notice makes to a server that answers 200.
  def sent(item = call)
    NtfySpecSupport::Stub.serve do |stub|
      described_class.new(url: stub.url).notify(item)
      stub.wait
    end
  end

  it "posts once to the topic, with a title naming the kind and the requester" do
    request = sent

    expect([request.verb, request.path, request.headers["title"]])
      .to eq(["POST", "/lain-x7", "lain approval waiting on agent"])
  end

  it "titles each kind of item by what it is" do
    expect([gate, question].map { sent(_1).headers["title"] })
      .to eq(["lain gate question waiting on gate", "lain question waiting on agent"])
  end

  it "offers 1 action, Open, a view to the app's item" do
    expect(sent.headers["actions"]).to eq("view, Open, lain-remote://item/ab12-call-1")
  end

  it "sends none of the item's text" do
    request = sent

    expect(request.headers.values.join(" ") + request.body).not_to include("rm -rf", "/work/repo", "deletes the build")
  end

  it "keeps a hostile requester to one printable header line" do
    request = sent(call.with(requester: "agent\r\nX-Injected: yes \u00e9"))

    expect([request.headers["title"], request.headers.key?("x-injected")])
      .to eq(["lain approval waiting on agent??X-Injected: yes ?", false])
  end

  it "escapes an id that is not URL-safe" do
    expect(sent(call.with(id: "a b/c")).headers["actions"]).to eq("view, Open, lain-remote://item/a%20b%2Fc")
  end

  it "raises Refused naming the status when the server turns it away" do
    NtfySpecSupport::Stub.serve(status: 403) do |stub|
      expect { described_class.new(url: stub.url).notify(call) }.to raise_error(described_class::Refused) { |error|
        expect(error.message).to include("403")
        expect(error.message).not_to include("lain-x7")
      }
    end
  end

  it "gives up on a server that never answers, within its own bound" do
    NtfySpecSupport::Stub.serve(status: nil) do |stub|
      expect { described_class.new(url: stub.url, timeout: 0.2).notify(call) }.to raise_error(Timeout::Error)
    end
  end

  it "gives up on a server that is not there" do
    url = NtfySpecSupport::Stub.serve(&:url)
    port = URI(url).port

    NetworkAccess.permit_loopback(port) do
      expect { described_class.new(url:, timeout: 0.2).notify(call) }.to raise_error(SystemCallError)
    end
  end

  it "has a Null that sends nothing" do
    expect(described_class::Null::INSTANCE.notify(call)).to be_nil
  end
end
