#!/usr/bin/env ruby
# Fetches monthly processed Parquet files from the piebro/deutsche-bahn-data
# dataset on Hugging Face into data/deutsche_bahn/.
#
# Coverage: monthly files exist from 2024-07 onward. Months before that
# return 404 and are skipped. Re-runs are idempotent: a local file is kept when
# its size matches the remote one, and downloaded again when upstream has
# reprocessed it.
# Exits 1 if any download failed (a 404 is not a failure).
#
# Env overrides:
#   BAHN_FROM   YYYY-MM (default 2024-07; empty counts as unset)
#   BAHN_TO     YYYY-MM (default current month; empty counts as unset)
#   BAHN_FILES  comma-separated list (overrides FROM/TO)
#                e.g. "data-2024-07.parquet,data-2024-08.parquet"

require "date"
require "fileutils"
require "net/http"
require "uri"

DEST = File.expand_path("../data/deutsche_bahn", __dir__)
BASE = "https://huggingface.co/datasets/piebro/deutsche-bahn-data/resolve/main/monthly_processed_data"
MAX_REDIRECTS = 5

def month_range(from_str, to_str)
  from = Date.strptime(from_str, "%Y-%m")
  to   = Date.strptime(to_str,   "%Y-%m")
  [].tap do |out|
    d = from
    while d <= to
      out << d.strftime("data-%Y-%m.parquet")
      d = d.next_month
    end
  end
end

def remote_size(url)
  MAX_REDIRECTS.times do
    uri = URI(url)
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.head(uri.request_uri) }
    case resp
    when Net::HTTPSuccess     then return resp["content-length"]&.to_i
    when Net::HTTPRedirection then url = resp["location"]
    else return nil
    end
  end
  nil
end

def download(url, target)
  remaining = MAX_REDIRECTS
  while remaining.positive?
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request_get(uri.request_uri) do |resp|
        case resp
        when Net::HTTPSuccess
          tmp = "#{target}.part"
          File.open(tmp, "wb") { |f| resp.read_body { |chunk| f.write(chunk) } }
          File.rename(tmp, target)
          return :ok
        when Net::HTTPRedirection
          url = resp["location"]
          remaining -= 1
        when Net::HTTPNotFound
          return :missing
        else
          return [:error, resp.code]
        end
      end
    end
  end
  [:error, "too many redirects"]
end

def env_value(name)
  value = ENV[name]&.strip
  value unless value.nil? || value.empty?
end

files =
  if (env = ENV["BAHN_FILES"]) && !env.strip.empty?
    env.split(",").map(&:strip).reject(&:empty?)
  else
    month_range(
      env_value("BAHN_FROM") || "2024-07",
      env_value("BAHN_TO")   || Date.today.strftime("%Y-%m")
    )
  end

FileUtils.mkdir_p(DEST)
errors = 0

files.each do |name|
  target = File.join(DEST, name)
  url = "#{BASE}/#{name}"
  if File.exist?(target) && File.size(target).positive?
    remote = remote_size(url)
    if remote.nil? || remote == File.size(target)
      puts "skip   #{name} (#{remote.nil? ? "exists, remote size unknown" : "up to date"})"
      next
    end
    puts "stale  #{name} (local #{File.size(target)} bytes, remote #{remote})"
  end

  case (result = download(url, target))
  when :ok      then puts "ok     #{name} (#{File.size(target)} bytes)"
  when :missing then puts "miss   #{name} (404 — month not published)"
  else
    warn "ERROR  #{name}: #{result.inspect}"
    errors += 1
  end
end

puts "done -> #{DEST}"
if errors.positive?
  warn "#{errors} download(s) failed"
  exit 1
end
