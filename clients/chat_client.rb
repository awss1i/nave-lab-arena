# N chat calls through ruby_llm, checked and summed the way the load tool does.
# Usage: ruby chat_client.rb URL N [--stream]. URL is the stand-in's base, such as http://127.0.0.1:9000/v1.
t_import = Process.clock_gettime(Process::CLOCK_MONOTONIC)
require "ruby_llm"

base, n = ARGV[0], ARGV[1].to_i
stream = ARGV.include?("--stream")
RubyLLM.configure do |c|
  c.openai_api_key = ENV.fetch("LLM_KEY", "local")
  c.openai_api_base = base
  c.max_retries = 0
end
import_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_import) * 1000

MASK = (1 << 64) - 1
def fnv(text)
  text.each_byte.reduce(0xcbf29ce484222325) { |h, b| ((h ^ b) * 0x100000001b3) & MASK }
end

ok = bad = total = 0
lat = []
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n.times do |i|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # A chat keeps its history, so each call gets a chat of its own.
  chat = RubyLLM.chat(model: "mock", provider: :openai, assume_model_exists: true)
  text = if stream
    pieces = +""
    chat.ask("call #{i}") { |chunk| pieces << chunk.content.to_s }
    pieces
  else
    chat.ask("call #{i}").content.to_s
  end
  lat << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1e6
  text.start_with?("echo: call #{i}") ? ok += 1 : bad += 1
  total ^= (fnv(text) * (i + 1)) & MASK
end
s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "ok #{ok}\nbad #{bad}\nchecksum #{format('%016x', total)}"
lat.sort!
warn "metric calls_per_s=#{format('%.1f', n / s)}\nmetric p50_us=#{lat[lat.size / 2].round}\nmetric import_ms=#{format('%.1f', import_ms)}"
exit(bad.zero? ? 0 : 1)
