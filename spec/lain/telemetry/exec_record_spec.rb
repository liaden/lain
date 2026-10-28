# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ExecRecord do
  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(tool_use_id: "tu_1",
                                   profile: :traced,
                                   execs: [{ "path" => "/bin/ls", "argv0" => "ls", "rc" => 0 }],
                                   refusals: [{ "path" => "/bin/curl", "argv0" => "curl", "rc" => -1 }],
                                   fd_execs: [{ "path" => "", "argv0" => "x", "rc" => 0 }],
                                   truncated: true,
                                   incomplete: true,
                                   connects: [
                                     { "call" => "connect", "family" => "AF_INET", "address" => "127.0.0.1",
                                       "port" => 80,
                                       "rc" => 0, "errno" => nil, "count" => 2 }
                                   ],
                                   connects_dropped: 3)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"exec_record","tool_use_id":"tu_1","profile":"traced","execs":[{"path":"/bin/ls",' \
        '"argv0":"ls","rc":0}],"refusals":[{"path":"/bin/curl","argv0":"curl","rc":-1}],' \
        '"fd_execs":[{"path":"","argv0":"x","rc":0}],"truncated":true,"incomplete":true,' \
        '"connects":[{"call":"connect","family":"AF_INET","address":"127.0.0.1","port":80,"rc":0,' \
        '"errno":null,"count":2}],"connects_dropped":3}'
      )
    end

    it "journals byte for byte with optional fields at their defaults (min)" do
      record = described_class.new(tool_use_id: "tu_1",
                                   profile: :reader,
                                   execs: [],
                                   refusals: [],
                                   fd_execs: [],
                                   truncated: false)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"exec_record","tool_use_id":"tu_1","profile":"reader","execs":[],"refusals":[],' \
        '"fd_execs":[],"truncated":false,"incomplete":false,"connects":[],"connects_dropped":0}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        tool_use_id: "tu_1",
        profile: :traced,
        execs: [{ "path" => "/bin/ls", "argv0" => "ls", "rc" => 0 }],
        refusals: [{ "path" => "/bin/curl", "argv0" => "curl", "rc" => -1 }],
        fd_execs: [{ "path" => "", "argv0" => "x", "rc" => 0 }],
        truncated: true,
        incomplete: true,
        connects: [
          { "call" => "connect", "family" => "AF_INET", "address" => "127.0.0.1",
            "port" => 80,
            "rc" => 0, "errno" => nil, "count" => 2 }
        ],
        connects_dropped: 3
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing tool_use_id, naming it" do
      given = {
        tool_use_id: "tu_1",
        profile: :traced,
        execs: [{ "path" => "/bin/ls", "argv0" => "ls", "rc" => 0 }],
        refusals: [{ "path" => "/bin/curl", "argv0" => "curl", "rc" => -1 }],
        fd_execs: [{ "path" => "", "argv0" => "x", "rc" => 0 }],
        truncated: true,
        incomplete: true,
        connects: [
          { "call" => "connect", "family" => "AF_INET", "address" => "127.0.0.1",
            "port" => 80,
            "rc" => 0, "errno" => nil, "count" => 2 }
        ],
        connects_dropped: 3
      }
      expect { described_class.new(**given.except(:tool_use_id)) }.to raise_error(ArgumentError, /tool_use_id/)
    end

    it "refuses an unknown keyword with ArgumentError" do
      expect do
        described_class.new(tool_use_id: "t", profile: :reader, execs: [], refusals: [], fd_execs: [], truncated: false,
                            bogus: 1)
      end.to raise_error(ArgumentError, /bogus/)
    end
  end
end
