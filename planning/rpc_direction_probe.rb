# frozen_string_literal: true

# Probe: can a Neovim.attach_unix client SERVE an inbound rpcrequest?
#
# Plan: start headless nvim on a unix socket, attach with the neovim gem,
# use nvim_set_client_info + a lua rpcrequest(chan, ...) fired from nvim,
# and see whether the gem's event loop surfaces the request so we can respond.
require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

socket = File.join(Dir.tmpdir, "lain-probe-#{Process.pid}.sock")
pid = spawn("nvim", "--headless", "--clean", "--listen", socket,
            out: File::NULL, err: File::NULL)

Timeout.timeout(5) { sleep 0.05 until File.exist?(socket) }

client = Neovim.attach_unix(socket)
chan = client.channel_id
puts "attached, channel_id=#{chan}"

# Schedule nvim to send us a blocking rpcrequest in 200ms via vim.defer_fn.
client.exec_lua(<<~LUA, [chan])
  local chan = ...
  vim.defer_fn(function()
    local ok, result = pcall(vim.rpcrequest, chan, "lain_ping", "hello")
    vim.g.probe_result = ok and result or ("ERROR: " .. tostring(result))
    vim.rpcnotify(chan, "lain_done")
  end, 200)
LUA

# Now run the client's event loop and see if the request arrives.
served = nil
Timeout.timeout(5) do
  client.session.run do |message|
    puts "received: #{message.inspect}"
    if message.sync? # an rpcrequest expecting a response
      client.session.respond(message.id, "pong:#{message.arguments.first}")
      served = true
    elsif message.method_name == "lain_done"
      # The gem only flushes writes on its next read, so the response reached
      # nvim by the time this notification arrives. Now safe to disconnect.
      client.session.shutdown
    end
  end
rescue Timeout::Error
  puts "TIMEOUT: no inbound request surfaced"
end

if served
  # Confirm nvim actually got our response back.
  client2 = Neovim.attach_unix(socket)
  puts "nvim saw: #{client2.get_var("probe_result").inspect}"
end
ensure_pid = pid
Process.kill("TERM", ensure_pid)
Process.wait(ensure_pid)
FileUtils.rm_f(socket)
