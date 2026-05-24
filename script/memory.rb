#!/usr/bin/env ruby
# Memory profile for the main code paths in Iriq.
#
# Usage:
#   bundle exec script/memory.rb              # default sizes
#   bundle exec script/memory.rb 50000        # custom corpus size
#
# Reports retained memory per operation, cache footprints, and memory
# growth across corpus sizes (to verify linear scaling — no leaks).

require "objspace"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../spec/support", __dir__)
require "iriq"
require "iri_generator"

CORPUS_SIZE = Integer(ARGV[0] || 10_000)
SIZES       = [1_000, 10_000, 100_000].uniq.sort
SIZES << CORPUS_SIZE unless SIZES.include?(CORPUS_SIZE)
SIZES.sort!

# Bytes → KB / MB string for display.
def fmt_bytes(n)
  if n < 1024
    "#{n} B"
  elsif n < 1024 * 1024
    format("%.1f KB", n / 1024.0)
  else
    format("%.2f MB", n / (1024.0 * 1024.0))
  end
end

# Run a block in isolation: GC before + after, return delta in bytes.
def measure_retained(&block)
  GC.start
  before = ObjectSpace.memsize_of_all
  result = block.call
  GC.start
  after  = ObjectSpace.memsize_of_all
  [after - before, result]
end

# Reset caches so each scenario starts clean.
def reset_caches
  Iriq::SegmentClassifier::DEFAULT.instance_variable_get(:@cache).clear
  Iriq::Inflector.instance_variable_get(:@cache)&.clear
end

puts "Iriq memory profile — Ruby #{RUBY_VERSION}, Iriq #{Iriq::VERSION}"
puts

# -- Section 1: memory growth across corpus sizes --
puts "── corpus retained memory by N (verifies linear growth) ──"
printf("  %-12s %-14s %-14s %-10s\n", "N obs", "retained", "per obs", "allocs")
SIZES.each do |n|
  reset_caches
  urls = IriGenerator.urls(count: n, seed: 1)
  alloc_before = GC.stat(:total_allocated_objects)
  retained, _ = measure_retained do
    c = Iriq::Corpus.new
    urls.each { |u| c.observe(u) }
    c
  end
  alloc_total = GC.stat(:total_allocated_objects) - alloc_before
  printf("  %-12s %-14s %-14s %-10s\n", n, fmt_bytes(retained), fmt_bytes(retained / n), alloc_total)
end
puts

# -- Section 2: corpus state breakdown at CORPUS_SIZE --
puts "── corpus state breakdown at N=#{CORPUS_SIZE} ──"
reset_caches
urls = IriGenerator.urls(count: CORPUS_SIZE, seed: 1)
corpus = Iriq::Corpus.new
urls.each { |u| corpus.observe(u) }
puts "  unique hosts:           #{corpus.host_counts.size}"
puts "  unique fingerprints:    #{corpus.fingerprint_counts.size}"
puts "  unique raw shapes:      #{corpus.raw_shape_counts.size}"
puts "  clusters:               #{corpus.size}"
puts "  position_stats entries: #{corpus.position_stats.size}"
puts "  total observed values:  #{corpus.position_stats.sum { |_, s| s.value_counts.size }}"
puts

# -- Section 3: cache footprints --
puts "── memoization caches ──"
classifier_cache = Iriq::SegmentClassifier::DEFAULT.instance_variable_get(:@cache)
inflector_cache  = Iriq::Inflector.instance_variable_get(:@cache) || {}
puts "  classifier cache: #{classifier_cache.size} entries (cap #{Iriq::SegmentClassifier::CACHE_MAX})"
puts "  inflector cache:  #{inflector_cache.size} entries (cap #{Iriq::Inflector::CACHE_MAX})"
puts

# -- Section 4: per-operation memory cost --
puts "── retained memory per operation (N=#{CORPUS_SIZE}) ──"
urls = IriGenerator.urls(count: CORPUS_SIZE, seed: 1)
text_blob = urls.map { |u| "Some prose about #{u} here." }.join(" ")

[
  ["parse #{CORPUS_SIZE} URLs (discarded after)", ->{ urls.each { |u| Iriq.parse(u) } }],
  ["normalize #{CORPUS_SIZE} URLs",               ->{ urls.each { |u| Iriq.normalize(u) } }],
  ["explain #{CORPUS_SIZE} URLs",                 ->{ urls.each { |u| Iriq.explain(u) } }],
  ["extract from #{fmt_bytes(text_blob.bytesize)} prose", ->{ Iriq.extract(text_blob) }],
  ["Corpus.observe #{CORPUS_SIZE} URLs",          ->{ c = Iriq::Corpus.new; urls.each { |u| c.observe(u) }; c }],
].each do |label, op|
  reset_caches
  retained, _ = measure_retained(&op)
  printf("  %-50s %s\n", label, fmt_bytes(retained))
end
puts

# -- Section 5: persistence overhead --
puts "── save/load roundtrip (N=#{CORPUS_SIZE}) ──"
require "tempfile"
reset_caches
corpus = Iriq::Corpus.new
urls.each { |u| corpus.observe(u) }
Tempfile.open(["iriq-mem", ".json"]) do |f|
  corpus.save(f.path)
  bytes = File.size(f.path)
  puts "  JSON file on disk:  #{fmt_bytes(bytes)}"
  puts "  ratio:              #{format("%.2f bytes/obs", bytes.to_f / CORPUS_SIZE)}"
end
