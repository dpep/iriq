#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates golden JSON fixtures from the Ruby implementation. The Rust port's
# fixture tests load these files and assert the same outputs — a single source
# of truth that catches drift without re-translating every RSpec example.
#
#   bundle exec ruby script/generate_fixtures.rb
#
# Outputs land in spec/fixtures/. Re-run after any semantic change to the Ruby
# library and commit the regenerated files alongside the change.

require "fileutils"
require "json"
require_relative "../lib/iriq"
require_relative "../spec/support/iri_generator"

FIXTURE_DIR = File.expand_path("../spec/fixtures", __dir__)
FileUtils.mkdir_p(FIXTURE_DIR)

PARSER_INPUTS = [
  "https://foo.com/users/123",
  "HTTPS://FOO.COM/Bar",
  "https://foo.com:443/",
  "http://foo.com:80/",
  "https://foo.com:8443/",
  "  https://Foo.com/  ",
  "https://foo.com/a/./b/../c",
  "https://foo.com//a///b",
  "https://foo.com/q?a=1&b=hello&c=",
  "https://foo.com/x#top",
  "foo.com/users/456",
  "urn:isbn:0451450523",
  "urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "https://例え.テスト/こんにちは",
  "https://foo.com:8443/x?a=1&b=2#top",
  "https://127.0.0.1:8080/x",
  "https://россия.рф/о-нас",
].freeze

CLASSIFIER_INPUTS = [
  "users", "Profile", "123", "0", "9999999",
  "3.14", "-2.5", "1.0",
  "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "2024-05-23", "2024-05-23T10:30:00Z", "2024-05-23 10:30:00",
  "1716470400", "1716470400000",
  "d41d8cd98f00b204e9800998ecf8427e",
  "my-cool-post", "my_cool_post",
  "abc123XYZ",
  "192.168.1.1", "10.0.0.1", "999.999.999.999",
  "::1", "2001:db8::1", "fe80::1", "12:34",
  "https://foo.com/bar", "ftp://files.example.com/x",
  "alice@example.com", "user.name+tag@sub.example.co.uk",
  "true", "false", "TRUE",
  "v1", "v2.0.1", "v1.2.3-beta", "1.2.3",
  "en-US", "fr_CA", "zh-Hant",
  "USD", "eur", "FAQ",
  "2026", "1999", "1800",
  "by-locale", "if", "to",
  "+15551234567", "+1 (555) 123-4567",
  "555-666-7777", "(555) 666-7777", "555.666.7777", "123-456-7890",
  "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dQw4w9WgXcQ",
  "image/png", "application/vnd.api+json", "text/html",
  "foo.com/bar", "sub.foo.com/",
  "image.png", "report.pdf", "data.csv", "user-photo.jpg",
  "archive.tar.gz", "no-known-ext.qwerty",
  "#fff", "#ffffff", "#ffffff80", "#abc1", "#zz",
  "37.7749,-122.4194", "0,0", "200,200",
  "US", "CA", "GB", "XX", "OK",
  "TWFuIGlzIGRpc3Rpbmd1aXNoZWQ=", "AAAAAAAAAAAAAA+/==",
  "こんにちは", "",
].freeze

INFLECTOR_INPUTS = %w[
  users posts orders comments articles items projects
  categories companies cities libraries
  addresses statuses classes boxes buses churches
  matrices indices vertices octopi analyses diagnoses theses
  knives leaves wolves
  people children men women mice lice
  heroes tomatoes
  news fish sheep data person
  Users USERS People
].freeze

NORMALIZE_INPUTS = [
  ["https://foo.com/users/123",             true],
  ["https://foo.com/users/123/orders/456",  true],
  ["https://foo.com/users/123",             false],
  ["HTTPS://FOO.COM:443/Bar",               true],
  ["https://foo.com/posts/abc-123",         true],
  ["https://foo.com/search?q=hi&page=2",    true],
  ["urn:isbn:0451450523",                   true],
  ["urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479", true],
  ["https://foo.com/2024-05-23/events",     true],
  ["https://foo.com/files/d41d8cd98f00b204e9800998ecf8427e", true],
  ["https://shop.com/pricing/usd/checkout",                  true],
  ["https://shop.com/price?currency=eur",                    true],
  ["https://foo.com/probe/192.168.1.1",                      true],
  ["https://foo.com/probe/::1",                              true],
  ["https://foo.com/api/v1/status",                          true],
  ["https://foo.com/uploads/image.png",                      true],
  ["https://foo.com/contact/555-666-7777",                   true],
  ["https://foo.com/x?phone=unknown&email=tbd",              true],
  ["https://foo.com/x?phone=12345",                          true],
  ["https://foo.com/ui?bg=%23ff00ff",                        true],
  ["https://foo.com/maps?coords=37.7749,-122.4194",          true],
  ["https://foo.com/orders?country=US&color=%23fff",         true],
].freeze

PATH_SHAPE_INPUTS = [
  [[], true],
  [["users", "123"], true],
  [["users", "123"], false],
  [["users", "123", "orders", "456"], true],
  [["posts", "abc-123"], true],
  [["events", "2024-05-23"], true],
  [["login"], true],
].freeze

EXPLAIN_INPUTS = [
  "https://foo.com/users/123/orders/456",
  "https://foo.com/posts/abc-123",
  "urn:isbn:0451450523",
  "urn:uuid:f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "https://foo.com/2024-05-23/events",
].freeze

EXTRACTOR_INPUTS = [
  "Visit https://foo.com today.",
  "First https://a.com then https://b.com and https://c.com",
  "See urn:isbn:0451450523 for details",
  '"https://foo.com",',
  "(see https://en.wikipedia.org/wiki/Foo_(bar))",
  "She said “https://foo.com” loudly",
  "「https://例え.テスト/こんにちは」を見て",
  "Сайт https://россия.рф/о-нас здесь",
  "visit foo.com/users today",
  "1,https://a.com,2,https://b.com,3",
  "https://maps.example.com/?q=37.7,-122.4 next",
  "user@host:port/path",
  "rsync user@host.com:/var/log/ to backup",
  "see ./README.md and /usr/local/bin",
].freeze

def identifier_hash(iri)
  {
    "original"      => iri.original,
    "kind"          => iri.kind.to_s,
    "scheme"        => iri.scheme,
    "host"          => iri.host,
    "port"          => iri.port,
    "path_segments" => iri.path_segments,
    "query_params"  => iri.query_params,
    "fragment"      => iri.fragment,
    "nss"           => iri.nss,
    "canonical"     => iri.canonical,
  }
end

def hint_hash(entry)
  {
    "value"    => entry[:value],
    "type"     => entry[:type].to_s,
    "variable" => entry[:variable],
    "hint"     => entry[:hint],
  }
end

def write_fixture(name, data)
  path = File.join(FIXTURE_DIR, "#{name}.json")
  File.write(path, JSON.pretty_generate(data) + "\n")
  puts "  wrote #{path}"
end

puts "Generating fixtures in #{FIXTURE_DIR}"

# Parser
parser_cases = PARSER_INPUTS.map do |input|
  iri = Iriq::Parser.parse(input)
  { "input" => input, "identifier" => identifier_hash(iri) }
end
write_fixture("parser", { "cases" => parser_cases })

# Classifier
classifier_cases = CLASSIFIER_INPUTS.map do |input|
  { "input" => input, "type" => Iriq::SegmentClassifier::DEFAULT.classify(input).to_s }
end
write_fixture("classifier", { "cases" => classifier_cases })

# Inflector (built-in adapter only — ActiveSupport may differ)
original_adapter = Iriq::Inflector.adapter
Iriq::Inflector.adapter = Iriq::Inflector::BuiltinAdapter
inflector_cases = INFLECTOR_INPUTS.map do |input|
  { "input" => input, "singular" => Iriq::Inflector.singularize(input) }
end
Iriq::Inflector.adapter = original_adapter
write_fixture("inflector", { "cases" => inflector_cases })

# Normalizer
normalize_cases = NORMALIZE_INPUTS.map do |(input, hints)|
  {
    "input"  => input,
    "hints"  => hints,
    "output" => Iriq::Normalizer.normalize(input, hints: hints),
  }
end
write_fixture("normalizer", { "cases" => normalize_cases })

# PathShape
pathshape_cases = PATH_SHAPE_INPUTS.map do |(segs, hints)|
  {
    "segments" => segs,
    "hints"    => hints,
    "shape"    => Iriq::PathShape.for(segs, hints: hints),
  }
end
write_fixture("pathshape", { "cases" => pathshape_cases })

# Explanation
explain_cases = EXPLAIN_INPUTS.map do |input|
  {
    "input"   => input,
    "entries" => Iriq::Explanation.explain(input).map { |e| hint_hash(e) },
  }
end
write_fixture("explanation", { "cases" => explain_cases })

# Extractor (default options + strict mode for the scheme-less example)
extractor_cases = EXTRACTOR_INPUTS.map do |text|
  {
    "text"       => text,
    "extracted"  => Iriq::Extractor.new.extract_strings(text),
    "strict"     => Iriq::Extractor.new(scheme_less: false).extract_strings(text),
  }
end
write_fixture("extractor", { "cases" => extractor_cases })

# Synthetic corpus — exercises the corpus heuristics end-to-end with a
# deterministic stream. We dump the resulting aggregates so Rust can replay the
# stream and assert the same final state.
seed_count = 200
urls       = IriGenerator.urls(count: seed_count, seed: 1234)
corpus     = Iriq::Corpus.new
urls.each { |u| iri = Iriq::Parser.parse(u); corpus.observe(iri) }

corpus_fixture = {
  "seed"   => 1234,
  "count"  => seed_count,
  "inputs" => urls,
  "expected" => {
    "host_counts"        => corpus.host_counts,
    "path_length_counts" => corpus.path_length_counts.transform_keys(&:to_s),
    "raw_shape_counts"   => corpus.raw_shape_counts,
    "fingerprint_counts" => corpus.fingerprint_counts,
    "cluster_count"      => corpus.size,
    # Top 5 by count for stability; full counts above let Rust assert exact equality.
    "top_hosts"          => corpus.host_counts.sort_by { |_, n| -n }.first(5).to_h,
    "top_shapes"         => corpus.fingerprint_counts.sort_by { |_, n| -n }.first(5).to_h,
  },
}
write_fixture("corpus_stream", corpus_fixture)

# Smaller deterministic corpus we can save+load and assert byte-for-byte parity
# on the in-memory structures (not the JSON bytes).
small = Iriq::Corpus.new
%w[
  https://foo.com/users/1
  https://foo.com/users/2
  https://foo.com/users/3
  https://foo.com/posts/abc-123
  https://bar.com/x
].each { |u| small.observe(u) }
write_fixture("corpus_dump", small.dump)

# Param classification fixture — exercises the const → string → enum ladder,
# the confidence score, and enum member values so Rust asserts identical
# per-param typing. All params share the /items cluster; each carries a
# different distribution to land on a different rung.
params_corpus = Iriq::Corpus.new
param_inputs  = []
observe_param = lambda do |url|
  param_inputs << url
  params_corpus.observe(url)
end

# enum — bounded set, open dominant over closed.
14.times { observe_param.call("https://foo.com/items?status=open") }
10.times { observe_param.call("https://foo.com/items?status=closed") }
# string — varies across many distinct literal words, never bounded.
%w[one two three four five six seven eight nine ten eleven twelve thirteen
   fourteen fifteen sixteen seventeen eighteen nineteen twenty alpha beta
   gamma delta].each { |w| observe_param.call("https://foo.com/items?label=#{w}") }
# constant — a single repeated value stays a literal (rendered as-is).
40.times { observe_param.call("https://foo.com/items?fmt=json") }
# integer — distinct numbers, outside the year/http_status windows.
(1..24).each { |n| observe_param.call("https://foo.com/items?page=#{n}") }
# boolean — true dominant over false.
18.times { observe_param.call("https://foo.com/items?flag=true") }
6.times  { observe_param.call("https://foo.com/items?flag=false") }

param_expected = params_corpus.params_for("https://foo.com/items").to_h do |row|
  entry = {
    "type"        => row[:type].to_s,
    "confidence"  => row[:confidence],
    "cardinality" => row[:cardinality],
  }
  entry["values"] = row[:values] if row[:values]
  [row[:name], entry]
end
write_fixture("param_summary", {
  "query"    => "https://foo.com/items",
  "inputs"   => param_inputs,
  "expected" => param_expected,
})

puts "Done."
