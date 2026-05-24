#!/usr/bin/env ruby
# Performance benchmark for the main hot paths in Iriq.
#
# Usage:
#   bundle exec script/benchmark.rb              # default sizes
#   bundle exec script/benchmark.rb 50000        # custom "large" size
#
# Inputs are generated deterministically from IriGenerator so results are
# comparable across runs.

require "benchmark"
require "tempfile"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../spec/support", __dir__)
require "iriq"
require "iri_generator"

LARGE = Integer(ARGV[0] || 10_000)
SMALL = [LARGE / 10, 1_000].min
HUGE  = LARGE * 10

puts "Iriq benchmark — Ruby #{RUBY_VERSION}, Iriq #{Iriq::VERSION}"
puts "Sizes: small=#{SMALL}, large=#{LARGE}, huge=#{HUGE}"
puts

small_urls = IriGenerator.urls(count: SMALL, seed: 1)
large_urls = IriGenerator.urls(count: LARGE, seed: 1)
huge_urls  = IriGenerator.urls(count: HUGE,  seed: 1)

# ~ LARGE URLs embedded in prose
text_blob = small_urls.map { |u| "Some prose about #{u} here, also random words." }.join(" ") * (LARGE / SMALL)
puts "Text blob: #{text_blob.bytesize / 1024} KB (~#{LARGE} URLs embedded)"
puts

results = {}
Benchmark.bm(42) do |x|
  results[:parse]     = x.report("parse #{LARGE} URLs")                  { large_urls.each { |u| Iriq.parse(u) } }
  results[:normalize] = x.report("normalize #{LARGE} URLs (deterministic)") { large_urls.each { |u| Iriq.normalize(u) } }
  results[:explain]   = x.report("explain #{LARGE} URLs (deterministic)")   { large_urls.each { |u| Iriq.explain(u) } }
  results[:extract]   = x.report("extract from ~#{text_blob.bytesize / 1024} KB text")     { Iriq.extract(text_blob) }

  results[:observe_small] = x.report("Corpus.observe #{SMALL} URLs") do
    c = Iriq::Corpus.new
    small_urls.each { |u| c.observe(u) }
  end
  results[:observe_large] = x.report("Corpus.observe #{LARGE} URLs") do
    c = Iriq::Corpus.new
    large_urls.each { |u| c.observe(u) }
  end
  results[:observe_huge] = x.report("Corpus.observe #{HUGE} URLs") do
    c = Iriq::Corpus.new
    huge_urls.each { |u| c.observe(u) }
  end

  results[:roundtrip] = x.report("Corpus save+load (#{LARGE} observations)") do
    c = Iriq::Corpus.new
    large_urls.each { |u| c.observe(u) }
    Tempfile.open(["iriq-bench", ".json"]) do |f|
      c.save(f.path)
      Iriq::Corpus.load(f.path)
    end
  end
end

puts
puts "Throughput summary:"
[
  [:parse,         LARGE, "URLs/s"],
  [:normalize,     LARGE, "URLs/s"],
  [:explain,       LARGE, "URLs/s"],
  [:observe_small, SMALL, "URLs/s"],
  [:observe_large, LARGE, "URLs/s"],
  [:observe_huge,  HUGE,  "URLs/s"],
].each do |key, n, unit|
  per_sec = n / results[key].real
  printf("  %-30s %12s %s\n", key, per_sec.round.to_s, unit)
end

extract_mb = text_blob.bytesize / (1024.0 * 1024.0)
printf("  %-30s %12s MB/s\n", :extract, (extract_mb / results[:extract].real).round(2).to_s)
