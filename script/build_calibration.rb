#!/usr/bin/env ruby
# Builds spec/fixtures/calibration/segments.json from the inline labeled
# corpus below. Re-run this script after editing the labels to refresh the
# fixture used by both Ruby and Rust calibration tests.
#
# Each entry is { value, expected_type, category, source }:
#   value         — the segment string
#   expected_type — the ground-truth classifier output we want
#   category      — one of:
#                     "positive"     — clear example of expected_type
#                     "negative_*"   — looks like another type X, but the right
#                                      answer is expected_type
#                     "edge"         — ambiguous; this is a judgment call we
#                                      want pinned down
#   source        — short note on why this label is what it is
#
# This corpus has two jobs:
#   (1) regression test — current SegmentClassifier output must match every
#       expected_type. Run via spec/iriq/calibration_spec.rb.
#   (2) calibration target — when the scored ensemble lands (step 4), we'll
#       measure per-Recognizer precision / recall against this corpus and
#       calibrate confidence values to match.
#
# Aim for ~15 entries per type. Mix positives and adjacent negatives:
# every type that the classifier could plausibly confuse with type X should
# have at least one negative_X entry.

require "json"
require "fileutils"

OUT = File.expand_path("../spec/fixtures/calibration/segments.json", __dir__)
FileUtils.mkdir_p(File.dirname(OUT))

SEGMENTS = []

def add(value, expected_type, category, source)
  SEGMENTS << {
    "value"         => value,
    "expected_type" => expected_type.to_s,
    "category"      => category,
    "source"        => source,
  }
end

# ── literal ────────────────────────────────────────────────────────────────
add "users",     :literal, "positive", "plain noun, ubiquitous in URLs"
add "posts",     :literal, "positive", "plain noun"
add "Profile",   :literal, "positive", "mixed-case word"
add "settings",  :literal, "positive", "plain noun"
add "admin",     :literal, "positive", "plain noun"
add "deadbeef",  :literal, "positive", "short hex — not long enough for hash"
add "if",        :literal, "negative_locale", "2-letter not in locale allowlist"
add "to",        :literal, "negative_locale", "2-letter not in locale allowlist"
add "FAQ",       :literal, "negative_currency", "3-letter uppercase not in currency allowlist"
add "OK",        :literal, "negative_country", "2-letter not in country allowlist"
add "XX",        :literal, "negative_country", "2-letter not in country allowlist"
add "vNext",     :literal, "negative_version", "looks like a version tag but no digit"
add "こんにちは", :literal, "positive", "Unicode letters"
add "café",      :literal, "positive", "Unicode with combining mark"
add "12:34",     :literal, "negative_timestamp", "colon-separated but not a date-time"

# ── integer ────────────────────────────────────────────────────────────────
add "0",                  :integer, "positive", "zero"
add "1",                  :integer, "positive", "one"
add "42",                 :integer, "positive", "small int"
add "123",                :integer, "positive", "three-digit"
add "9999999",            :integer, "positive", "seven-digit"
add "2026",               :integer, "edge",     "year-shape int — corpus may promote :year"
add "1999",               :integer, "edge",     "year-shape int"
add "1800",               :integer, "edge",     "year-shape int below corpus window"
add "2200",               :integer, "edge",     "year-shape int above corpus window"
add "404",                :integer, "edge",     "HTTP-status-shape int — corpus may promote"
add "200",                :integer, "edge",     "HTTP-status-shape int"
add "1234567",            :integer, "positive", "seven-digit not in timestamp window"
add "999999999",          :integer, "positive", "nine-digit just below timestamp window"
add "10000000000",        :integer, "edge",     "11-digit between sec/ms timestamp windows"
add "99999999999999",     :integer, "positive", "14-digit above ms timestamp window"

# ── float ──────────────────────────────────────────────────────────────────
add "1.5",      :float, "positive", "basic positive float"
add "0.0",      :float, "positive", "zero float"
add "-1.5",     :float, "positive", "negative float"
add "3.14159",  :float, "positive", "pi"
add "100.001",  :float, "positive", "small fraction"
add ".5",       :literal,   "negative_float", "missing leading digit — falls to literal fallback (too short for opaque)"
add "1.",       :literal,   "negative_float", "missing trailing digits — falls to literal fallback"
add "1.2.3",    :opaque_id, "negative_float", "multiple dots — matches opaque shape"

# ── uuid ───────────────────────────────────────────────────────────────────
add "f47ac10b-58cc-4372-a567-0e02b2c3d479", :uuid, "positive", "canonical RFC 4122 example"
add "00000000-0000-0000-0000-000000000000", :uuid, "positive", "nil UUID"
add "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", :uuid, "positive", "max UUID, uppercase"
add "550e8400-e29b-41d4-a716-446655440000", :uuid, "positive", "common test UUID"
add "f47ac10b58cc4372a5670e02b2c3d479",     :hash, "negative_uuid", "no dashes — classifies as hash"
add "not-a-uuid",                            :slug, "negative_uuid", "wrong shape"
add "f47ac10b-58cc-4372-a567",               :slug, "negative_uuid", "truncated — multi-dash hex falls into slug"

# ── date ───────────────────────────────────────────────────────────────────
add "2024-05-23", :date, "positive", "ISO 8601"
add "1999-12-31", :date, "positive", "Y2K eve"
add "2100-12-31", :date, "positive", "upper bound of plausible window"
add "1900-01-01", :date, "positive", "lower bound of plausible window"
add "2024/05/23", :date, "positive", "slash form"
add "5/23/2024",  :date, "positive", "US M/D/YYYY"
add "12/31/1999", :date, "positive", "US two-digit month/day"
add "20240523",   :date, "positive", "compact YYYYMMDD (classified via integer recognizer)"
add "2024-13-01", :date, "edge",     "shape matches DATE_RE; classifier doesn't validate month — CanonicalDate would reject"
add "2024-05-23T10:30:00Z", :timestamp, "negative_date", "full timestamp"
add "1899-12-31", :date, "edge",     "shape matches DATE_RE; year-plausibility check lives in CanonicalDate"
add "23-05-2024", :slug, "negative_date", "DD-MM-YYYY isn't a recognized date shape; matches slug"

# ── timestamp ──────────────────────────────────────────────────────────────
add "2024-05-23T10:30:00Z",        :timestamp, "positive", "ISO with Z"
add "2024-05-23T10:30:00+00:00",   :timestamp, "positive", "ISO with offset"
add "2024-05-23T10:30:00.123Z",    :timestamp, "positive", "ISO with fractional"
add "2024-05-23 10:30:00",         :timestamp, "positive", "ISO with space"
add "2024-05-23T10:30",            :timestamp, "positive", "no seconds"
add "1716470400",                  :timestamp, "positive", "UNIX seconds"
add "1716470400000",               :timestamp, "positive", "UNIX millis"
add "999999999",                   :integer,   "negative_timestamp", "just below seconds window"
add "9999999999",                  :timestamp, "positive", "max of seconds window"

# ── hash ───────────────────────────────────────────────────────────────────
add "d41d8cd98f00b204e9800998ecf8427e",                                 :hash, "positive", "MD5"
add "da39a3ee5e6b4b0d3255bfef95601890afd80709",                         :hash, "positive", "SHA-1"
add "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", :hash, "positive", "SHA-256"
add "DEADBEEFDEADBEEFDEADBEEFDEADBEEF",                                  :hash, "positive", "all-uppercase 32 hex"
add "0123456789abcdef0123456789abcdef",                                  :hash, "positive", "32 hex"
add "deadbeef",                                                          :literal, "negative_hash", "too short for hash"
add "ghijklmnopqrstuv12345678901234567890",                              :opaque_id, "negative_hash", "non-hex chars"

# ── slug ───────────────────────────────────────────────────────────────────
add "my-cool-post",  :slug, "positive", "dash-separated"
add "my_cool_post",  :slug, "positive", "underscore-separated"
add "foo-bar-baz",   :slug, "positive", "multi-dash"
add "a-b",           :slug, "positive", "minimal"
add "no-at-sign",    :slug, "positive", "looks like email but no @"
add "by-locale",     :slug, "positive", "looks like locale-pair but lang not in allowlist"
add "123-456-7890",  :slug, "negative_phone", "NANP-shape but starts with 1"
add "100-200-3000",  :slug, "negative_phone", "leading 1 invalidates NANP"
add "FOO-BAR",       :opaque_id, "negative_slug", "uppercase invalidates slug shape"

# ── ipv4 ───────────────────────────────────────────────────────────────────
add "192.168.1.1",     :ipv4, "positive", "private"
add "10.0.0.1",        :ipv4, "positive", "private class A"
add "0.0.0.0",         :ipv4, "positive", "any-address"
add "255.255.255.255", :ipv4, "positive", "broadcast"
add "127.0.0.1",       :ipv4, "positive", "loopback"
add "8.8.8.8",         :ipv4, "positive", "Google DNS"
add "999.999.999.999", :opaque_id, "negative_ipv4", "out-of-range octets"
add "256.0.0.1",       :opaque_id, "negative_ipv4", "octet > 255"
add "1.2.3",           :opaque_id, "negative_ipv4", "only three octets"

# ── ipv6 ───────────────────────────────────────────────────────────────────
add "::1",                                       :ipv6, "positive", "loopback"
add "::",                                        :ipv6, "positive", "all-zero"
add "2001:db8::1",                               :ipv6, "positive", "documentation prefix"
add "2001:0db8:0000:0000:0000:ff00:0042:8329",   :ipv6, "positive", "full form"
add "fe80::1",                                   :ipv6, "positive", "link-local"
add "fe80::abcd:1234:5678:9abc",                 :ipv6, "positive", "link-local with iface"

# ── url ────────────────────────────────────────────────────────────────────
add "https://foo.com/bar",         :url, "positive", "https"
add "http://x",                    :url, "positive", "http minimal"
add "ftp://files.example.com/x",   :url, "positive", "ftp"
add "https://foo.com",             :url, "positive", "no path"
add "file:///etc/passwd",          :url, "positive", "file scheme"
add "foo.com/bar",                 :url, "positive", "schemeless"
add "sub.foo.com/",                :url, "positive", "schemeless with subdomain"
add "https://",                    :literal, "negative_url", "scheme but no host content"

# ── email ──────────────────────────────────────────────────────────────────
add "alice@example.com",             :email, "positive", "basic"
add "user.name+tag@sub.example.co.uk", :email, "positive", "with dots, plus, subdomain"
add "a@b.co",                        :email, "positive", "minimal"
add "USER@EXAMPLE.COM",              :email, "positive", "uppercase"
add "no-at-sign",                    :slug,    "negative_email", "missing @"
add "@nohost.com",                   :literal, "negative_email", "leading @ rules out literal/opaque shapes; falls to literal fallback"

# ── boolean ────────────────────────────────────────────────────────────────
add "true",  :boolean, "positive", "lowercase"
add "false", :boolean, "positive", "lowercase"
add "TRUE",  :boolean, "positive", "uppercase"
add "False", :boolean, "positive", "title-case"
add "yes",   :literal, "negative_boolean", "yes/no not recognized as boolean"
add "1",     :integer, "negative_boolean", "1/0 not recognized as boolean from single value"

# ── version ────────────────────────────────────────────────────────────────
add "v1",            :version, "positive", "single-digit"
add "v2.0.1",        :version, "positive", "semver-ish"
add "v1.2.3-beta",   :version, "positive", "with pre-release"
add "v1.2.3+build1", :version, "positive", "with build metadata"
add "v10",           :version, "positive", "two-digit major"
add "vNext",         :literal, "negative_version", "no digit after v"
add "1.2.3",         :opaque_id, "negative_version", "missing v prefix"

# ── locale ─────────────────────────────────────────────────────────────────
add "en",      :locale, "positive", "bare ISO 639-1"
add "fr",      :locale, "positive", "bare ISO 639-1"
add "ja",      :locale, "positive", "bare ISO 639-1"
add "zh",      :locale, "positive", "bare ISO 639-1"
add "en-US",   :locale, "positive", "language-region"
add "fr_CA",   :locale, "positive", "underscore form"
add "zh-Hant", :locale, "positive", "language-script"
add "zh-Hans", :locale, "positive", "language-script"
add "pt-BR",   :locale, "positive", "Brazilian Portuguese"
add "xx-YY",   :literal, "negative_locale", "language not in allowlist"
add "by-locale", :slug, "negative_locale", "lang not in allowlist, slug shape"

# ── currency ───────────────────────────────────────────────────────────────
add "USD", :currency, "positive", "ISO 4217 uppercase"
add "eur", :currency, "positive", "ISO 4217 lowercase"
add "GBP", :currency, "positive", "ISO 4217 uppercase"
add "jpy", :currency, "positive", "ISO 4217 lowercase"
add "CHF", :currency, "positive", "ISO 4217 uppercase"
add "FAQ", :literal,  "negative_currency", "not in allowlist"
add "XYZ", :literal,  "negative_currency", "not in allowlist"

# ── phone ──────────────────────────────────────────────────────────────────
add "+15551234567",      :phone, "positive", "E.164 compact"
add "+1 (555) 123-4567", :phone, "positive", "E.164 with separators"
add "+44 20 7946 0958",  :phone, "positive", "international"
add "+81-3-1234-5678",   :phone, "positive", "Japan"
add "555-666-7777",      :phone, "positive", "NANP with dashes"
add "(555) 666-7777",    :phone, "positive", "NANP parens"
add "555.666.7777",      :phone, "positive", "NANP dots"
add "+1",                :literal, "negative_phone", "too few digits"
add "123-456-7890",      :slug, "negative_phone", "leading 1 invalidates NANP"

# ── jwt ────────────────────────────────────────────────────────────────────
add "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dQw4w9WgXcQ",                              :jwt, "positive", "minimal three-part"
add "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NSJ9.SflKxwRJSMeKKF2QT4f", :jwt, "positive", "typical"
add "eyJhbGciOiJIUzI1NiJ9",                                                          :opaque_id, "negative_jwt", "only one segment, no base64 disambiguator chars"
add "ey.foo.bar",                                                                    :opaque_id, "negative_jwt", "JWT regex requires non-empty first segment after `ey`; falls to opaque"

# ── mime ───────────────────────────────────────────────────────────────────
add "image/png",                :mime, "positive", "common"
add "application/json",         :mime, "positive", "common"
add "text/html",                :mime, "positive", "common"
add "application/vnd.api+json", :mime, "positive", "vendor"
add "image/svg+xml",            :mime, "positive", "vendor"
add "multipart/form-data",      :mime, "positive", "request body"
add "video/mp4",                :mime, "positive", "video"

# ── file ───────────────────────────────────────────────────────────────────
add "image.png",          :file, "positive", "image"
add "report.pdf",         :file, "positive", "document"
add "data.csv",           :file, "positive", "data"
add "user-photo.jpg",     :file, "positive", "image with slug stem"
add "archive.tar.gz",     :file, "positive", "double-extension"
add "Inter-Bold.woff2",   :file, "positive", "web font with digit in extension"
add "master.m3u8",        :file, "positive", "HLS manifest"
add "app.min.js.map",     :file, "positive", "sourcemap double extension"
add "script.rb",          :file, "positive", "code"
add "video.mp4",          :file, "positive", "video"
add "page.html",          :file, "positive", "web"
add "no-known-ext.qwerty", :opaque_id, "negative_file", "extension not in allowlist"

# ── color ──────────────────────────────────────────────────────────────────
add "#fff",      :color, "positive", "3-hex shorthand"
add "#ffffff",   :color, "positive", "6-hex"
add "#ffffff80", :color, "positive", "8-hex with alpha"
add "#abc1",     :color, "positive", "4-hex with alpha"
add "#zz",       :literal, "negative_color", "non-hex chars"
add "#12",       :literal, "negative_color", "too short for any rule, falls to literal fallback"

# ── coordinate ─────────────────────────────────────────────────────────────
add "37.7749,-122.4194", :coordinate, "positive", "SF"
add "0,0",               :coordinate, "positive", "null island"
add "-90,-180",          :coordinate, "positive", "extreme"
add "90,180",            :coordinate, "positive", "extreme"
add "51.5074,-0.1278",   :coordinate, "positive", "London"
add "200,200",           :opaque_id, "negative_coordinate", "both out of range"
add "1000,1000",         :opaque_id, "negative_coordinate", "both out of range"

# ── country ────────────────────────────────────────────────────────────────
add "US", :country, "positive", "ISO 3166-1 alpha-2"
add "CA", :country, "positive", "ISO 3166-1 alpha-2"
add "GB", :country, "positive", "ISO 3166-1 alpha-2"
add "JP", :country, "positive", "ISO 3166-1 alpha-2"
add "BR", :country, "positive", "ISO 3166-1 alpha-2"
add "DE", :country, "positive", "ISO 3166-1 alpha-2"
add "XX", :literal, "negative_country", "not in allowlist"
add "OK", :literal, "negative_country", "OK is not a country code"

# ── base64 ─────────────────────────────────────────────────────────────────
add "TWFuIGlzIGRpc3Rpbmd1aXNoZWQ=", :base64, "positive", "RFC 4648 example with padding"
add "AAAAAAAAAAAAAA+/==",            :base64, "positive", "with + / and padding"
add "SGVsbG8gV29ybGQh",              :opaque_id, "negative_base64", "no disambiguating + / = chars"
add "short+/=",                       :literal, "negative_base64", "too short"

# ── opaque_id ──────────────────────────────────────────────────────────────
add "abc123XYZ",                  :opaque_id, "positive", "alphanumeric mixed case"
add "session_abc.123",            :opaque_id, "positive", "with allowed punctuation"
add "AKIAIOSFODNN7EXAMPLE",       :opaque_id, "positive", "AWS access key shape"
add "ghp_abc123def456ghi789jkl0", :slug, "edge", "GitHub PAT — currently SLUG wins over OPAQUE. step 4 should reclassify as opaque_id"
add "abc",                        :literal,   "negative_opaque", "too short (3 chars), hits literal first"
add "a_b",                        :slug,      "negative_opaque", "slug shape with allowed sep"

puts "Built #{SEGMENTS.size} segments across #{SEGMENTS.group_by { _1["expected_type"] }.size} types"

File.write(OUT, JSON.pretty_generate({
  "version"      => "1",
  "description"  => "Labeled segment calibration corpus. See script/build_calibration.rb.",
  "segments"     => SEGMENTS,
}))
puts "Wrote #{OUT}"
