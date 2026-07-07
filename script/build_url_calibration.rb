#!/usr/bin/env ruby
# Builds spec/fixtures/calibration/urls.json — the end-to-end (whole-URL)
# calibration corpus, the URL-level analog of segments.json. Inputs simulate
# messy real-world data: access-log URLs, tokens, i18n, encoding damage,
# legacy endpoints, non-http schemes, and outright garbage.
#
# Each entry pins Iriq.normalize's output (or that parsing fails). The
# expected values are ADJUDICATED implementation output: each was reviewed
# for plausibility when added; entries whose output is a judgment call or a
# known imperfection say so in their note. The corpus's job is to make any
# behavior change on real-world-shaped input a deliberate, reviewed act.
#
# Re-run after editing: bundle exec ruby script/build_url_calibration.rb
# CI regenerates this fixture and fails on drift (see rust.yml's parity job).
# Rust asserts the same fixture in rust/iriq/tests/url_calibration.rs.

require "json"
require "fileutils"

OUT = File.expand_path("../spec/fixtures/calibration/urls.json", __dir__)
FileUtils.mkdir_p(File.dirname(OUT))

URLS = []

# Normalizes to the expected template.
def add(input, expected, category, note)
  URLS << { "input" => input, "expected_normalize" => expected,
            "category" => category, "note" => note }
end

# Fails to parse.
def err(input, category, note)
  URLS << { "input" => input, "expected_error" => "parse_error",
            "category" => category, "note" => note }
end

add "https://api.acme.io/v1/users/48213",
    "https://api.acme.io/{version}/users/{user_id}",
    "rest_api", "numeric id after version prefix"
add "https://api.acme.io/v2/orders/9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c",
    "https://api.acme.io/{version}/orders/{order_uuid}",
    "rest_api", "UUID resource id"
add "https://api.acme.io/v3/users/48213/orders/9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c/items/7",
    "https://api.acme.io/{version}/users/{user_id}/orders/{order_uuid}/items/{item_id}",
    "rest_api", "mixed id styles nested in one path"
add "https://api.acme.io/v2.1/projects/kproj_02Hq/tasks/1042",
    "https://api.acme.io/{version}/projects/{project_id}/tasks/{task_id}",
    "rest_api", "dotted version + prefixed id + numeric"
add "https://svc.internal.acme.io/api/v3/teams/eng/members",
    "https://svc.internal.acme.io/api/{version}/teams/eng/members",
    "rest_api", "api/vN embedded mid-path"
add "https://api.acme.io/v1/organizations/org_9aZ2/repos/backend-core/pulls/318/comments",
    "https://api.acme.io/{version}/organizations/org_9aZ2/repos/{repo_id}/pulls/{pull_id}/comments",
    "rest_api", "deep nested resources"
add "https://gateway.acme.io/v1/customers/CUST-000481/invoices/INV-2024-00917",
    "https://gateway.acme.io/{version}/customers/{customer_id}/invoices/{invoice_id}",
    "rest_api", "hyphenated business ids"
add "https://api.acme.io/v1/nodes/0x1a2b3c4d/edges/0x9f8e7d6c",
    "https://api.acme.io/{version}/nodes/{node_id}/edges/{edge_id}",
    "rest_api", "hex-style ids"
add "https://api.acme.io/v1/users/me/settings",
    "https://api.acme.io/{version}/users/me/settings",
    "rest_api", "singleton alias segment"
add "https://api.acme.io/v1/search?q=widget&type=product&type=bundle",
    "https://api.acme.io/{version}/search?q=widget&type=bundle",
    "rest_api", "repeated type param — repeated params collapse last-wins by design"
add "https://shop.northwind.com/p/nike-air-max-90-DM0029-100",
    "https://shop.northwind.com/p/{p_id}",
    "ecommerce", "slug with SKU and colorway embedded"
add "https://shop.northwind.com/products/12490-organic-cotton-tee",
    "https://shop.northwind.com/products/{product_id}",
    "ecommerce", "numeric id prefix + slug"
add "https://shop.northwind.com/en-us/c/mens/shoes/running",
    "https://shop.northwind.com/{locale}/c/mens/shoes/running",
    "ecommerce", "locale + category taxonomy"
add "https://shop.northwind.com/de-de/produkt/laufschuh-42-EU",
    "https://shop.northwind.com/{locale}/produkt/{produkt_id}",
    "ecommerce", "German locale + size token"
add "https://shop.northwind.com/cart?add=SKU-7781&qty=2",
    "https://shop.northwind.com/cart?add={opaque_id}&qty={integer}",
    "ecommerce", "add-to-cart query"
add "https://checkout.northwind.com/checkout/step/shipping?session=cs_live_a1B2c3D4e5F6",
    "https://checkout.northwind.com/checkout/step/shipping?session={opaque_id}",
    "ecommerce", "checkout flow with session token"
add "https://shop.northwind.com/p/sony-wh1000xm5-B09XS7JBH8?variant=black",
    "https://shop.northwind.com/p/{p_id}?variant=black",
    "ecommerce", "ASIN-like id + variant"
add "https://shop.northwind.com/store/US/en/pricing?currency=USD",
    "https://shop.northwind.com/store/{country}/{locale}/pricing?currency=USD",
    "ecommerce", "country + currency path/param mix"
add "https://shop.northwind.com/wishlist/9f8b7c6d/items",
    "https://shop.northwind.com/wishlist/{wishlist_id}/items",
    "ecommerce", "opaque list id"
add "https://shop.northwind.com/gift-cards/redeem?code=GC-4X9K-2M7P-QW10",
    "https://shop.northwind.com/{slug}/redeem?code={opaque_id}",
    "ecommerce", "grouped alnum redemption code"
add "https://shop.northwind.com/p/sku/00840391108844",
    "https://shop.northwind.com/p/sku/{sku_id}",
    "ecommerce", "14-digit GTIN as segment"
add "https://auth.brightpay.dev/callback?code=4%2F0AeaYSHBx9k2&state=xyz789ABCdef",
    "https://auth.brightpay.dev/callback?code=4%2F0AeaYSHBx9k2&state={opaque_id}",
    "auth_tokens", "OAuth callback with encoded code + state"
add "https://api.brightpay.dev/verify?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
    "https://api.brightpay.dev/verify?token={jwt}",
    "auth_tokens", "full JWT in query param"
add "https://api.brightpay.dev/repos?access_token=ghp_16C7e42F292c6912E7710c838347Ae178B4a",
    "https://api.brightpay.dev/repos?access_token={opaque_id}",
    "auth_tokens", "GitHub PAT prefix in query"
add "https://api.brightpay.dev/charge?key=sk_live_51Hq8XZ2eZvKYlo2Cn9k3jQ",
    "https://api.brightpay.dev/charge?key={opaque_id}",
    "auth_tokens", "Stripe secret key prefix"
add "https://hooks.slack.com/services/T00000000/B00000000/xoxb-2401-abcDEF123ghiJKL",
    "https://hooks.slack.com/services/{service_id}/{opaque_id}/{opaque_id}",
    "auth_tokens", "Slack bot token in path"
add "https://app.brightpay.dev/reset-password?token=a3f8b2c1d4e5f6079a8b7c6d5e4f30211223344556677889900aabbccddeeff0",
    "https://app.brightpay.dev/{slug}?token={hash}",
    "auth_tokens", "long hex reset token"
add "https://assets.brightpay.dev.s3.amazonaws.com/report.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20240115%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20240115T120000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=b1c2d3e4f5a6978869504132aabbccddee00112233445566778899aabbccddee",
    "https://assets.brightpay.dev.s3.amazonaws.com/{file}?X-Amz-Algorithm={opaque_id}&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20240115%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date={opaque_id}&X-Amz-Expires={integer}&X-Amz-Signature={hash}&X-Amz-SignedHeaders=host",
    "auth_tokens", "S3 presigned URL with X-Amz params"
add "https://auth.brightpay.dev/oauth/authorize?response_type=code&client_id=abc123&redirect_uri=https%3A%2F%2Fapp.brightpay.dev%2Fcb&scope=read%20write&state=n0nc3",
    "https://auth.brightpay.dev/oauth/authorize?client_id={opaque_id}&redirect_uri=https%3A%2F%2Fapp.brightpay.dev%2Fcb&response_type=code&scope=read%20write&state={opaque_id}",
    "auth_tokens", "authorize with encoded redirect + scope"
add "https://api.brightpay.dev/v1/session?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJleHAiOjE3MDAwMDAwMDB9.QW5vdGhlclNpZ25hdHVyZVBhcnRIZXJlMTIzNA",
    "https://api.brightpay.dev/{version}/session?jwt={jwt}",
    "auth_tokens", "RS256 JWT variant"
add "https://cdn.brightpay.dev/dl?sig=SGVsbG9Xb3JsZFNpZ25hdHVyZQ%3D%3D&expires=1735689600",
    "https://cdn.brightpay.dev/dl?expires={timestamp}&sig=SGVsbG9Xb3JsZFNpZ25hdHVyZQ%3D%3D",
    "auth_tokens", "base64 signature + expiry"
add "https://logs.metrix.io/events/2024-01-15/summary",
    "https://logs.metrix.io/events/2024-01-15/summary",
    "dates_times", "ISO date in path"
add "https://logs.metrix.io/archive/20240115/index.html",
    "https://logs.metrix.io/archive/2024-01-15/{file}",
    "dates_times", "compact YYYYMMDD segment"
add "https://api.metrix.io/points?ts=1705315200",
    "https://api.metrix.io/points?ts={timestamp}",
    "dates_times", "unix timestamp param"
add "https://api.metrix.io/points?ts_ms=1705315200123",
    "https://api.metrix.io/points?ts_ms={timestamp}",
    "dates_times", "millisecond unix timestamp"
add "https://api.metrix.io/report?from=2024-01-01&to=2024-01-31",
    "https://api.metrix.io/report?from=2024-01-01&to=2024-01-31",
    "dates_times", "date range query"
add "https://api.metrix.io/events?after=2024-01-15T09%3A30%3A00%2B02%3A00",
    "https://api.metrix.io/events?after=2024-01-15T09%3A30%3A00%2B02%3A00",
    "dates_times", "RFC3339 with encoded tz offset"
add "https://api.metrix.io/events?after=2024-01-15T07:30:00Z",
    "https://api.metrix.io/events?after={timestamp}",
    "dates_times", "RFC3339 UTC unencoded colons"
add "https://logs.metrix.io/y/2024/m/01/d/15/h/23",
    "https://logs.metrix.io/y/{y_id}/m/{m_id}/d/{d_id}/h/{h_id}",
    "dates_times", "hierarchical date-time path"
add "https://api.metrix.io/week/2024-W03/rollup",
    "https://api.metrix.io/week/{week_id}/rollup",
    "dates_times", "ISO week designator"
add "https://api.metrix.io/range?window=P7D&anchor=2024-01-15",
    "https://api.metrix.io/range?anchor=2024-01-15&window=P7D",
    "dates_times", "ISO8601 duration param"
add "https://api.feedly.co/v1/items?page=3&limit=50",
    "https://api.feedly.co/{version}/items?limit={integer}&page={integer}",
    "pagination", "page + limit"
add "https://api.feedly.co/v1/items?offset=200&limit=25&sort=created_at&order=desc",
    "https://api.feedly.co/{version}/items?limit={integer}&offset={integer}&order=desc&sort={slug}",
    "pagination", "offset + sort + order"
add "https://api.feedly.co/v1/items?cursor=eyJpZCI6MTA0MiwidHMiOjE3MDUzMTUyMDB9",
    "https://api.feedly.co/{version}/items?cursor={opaque_id}",
    "pagination", "base64 cursor token"
add "https://api.feedly.co/v1/posts?tag=ruby&tag=rust&tag=go",
    "https://api.feedly.co/{version}/posts?tag=go",
    "pagination", "repeated tag param — repeated params collapse last-wins by design"
add "https://api.feedly.co/v1/posts?filter%5Bstatus%5D=active&filter%5Bkind%5D=note",
    "https://api.feedly.co/{version}/posts?filter%5Bkind%5D=note&filter%5Bstatus%5D=active",
    "pagination", "encoded bracket filter params"
add "https://api.feedly.co/v1/posts?filter[status]=active&filter[kind]=note",
    "https://api.feedly.co/{version}/posts?filter[kind]=note&filter[status]=active",
    "pagination", "raw bracket filter params"
add "https://api.feedly.co/v1/feed?before=id_9f8b7c&per_page=100",
    "https://api.feedly.co/{version}/feed?before={slug}&per_page={integer}",
    "pagination", "keyset before cursor"
add "https://api.feedly.co/v1/search?q=climate&facets[]=author&facets[]=year",
    "https://api.feedly.co/{version}/search?facets[]=year&q=climate",
    "pagination", "empty-bracket array params — repeated params collapse last-wins by design"
add "https://api.feedly.co/v1/items?sort=-created_at,+name",
    "https://api.feedly.co/{version}/items?sort=-created_at,+name",
    "pagination", "signed multi-field sort"
add "https://api.feedly.co/v1/items?page[number]=4&page[size]=20",
    "https://api.feedly.co/{version}/items?page[number]={integer}&page[size]={integer}",
    "pagination", "JSON:API nested page params"
add "https://münchen-reisen.de/über-uns",
    "https://münchen-reisen.de/über-uns",
    "i18n", "unicode host + umlaut path"
add "https://xn--mnchen-reisen-9db.de/kontakt",
    "https://xn--mnchen-reisen-9db.de/kontakt",
    "i18n", "punycode host"
add "https://blog.example.jp/%E6%97%A5%E6%9C%AC%E8%AA%9E/%E8%A8%98%E4%BA%8B",
    "https://blog.example.jp/%E6%97%A5%E6%9C%AC%E8%AA%9E/%E8%A8%98%E4%BA%8B",
    "i18n", "percent-encoded Japanese path"
add "https://news.example.ru/%D0%BD%D0%BE%D0%B2%D0%BE%D1%81%D1%82%D0%B8/2024",
    "https://news.example.ru/%D0%BD%D0%BE%D0%B2%D0%BE%D1%81%D1%82%D0%B8/{%D0%BD%D0%BE%D0%B2%D0%BE%D1%81%D1%82%D0%B8_id}",
    "i18n", "percent-encoded Cyrillic path"
add "https://shop.example.ae/%D8%A7%D9%84%D9%85%D9%86%D8%AA%D8%AC%D8%A7%D8%AA",
    "https://shop.example.ae/%D8%A7%D9%84%D9%85%D9%86%D8%AA%D8%AC%D8%A7%D8%AA",
    "i18n", "percent-encoded Arabic path (RTL)"
add "https://social.example.io/u/josé_garcía/posts",
    "https://social.example.io/u/josé_garcía/posts",
    "i18n", "raw accented mixed-script slug"
add "https://links.example.io/share?title=I%20%E2%9D%A4%EF%B8%8F%20tacos",
    "https://links.example.io/share?title=I%20%E2%9D%A4%EF%B8%8F%20tacos",
    "i18n", "emoji in encoded query value"
add "https://go.example.io/🔥/trending",
    "https://go.example.io/🔥/trending",
    "i18n", "raw emoji path segment"
add "https://例え.テスト/パス",
    "https://例え.テスト/パス",
    "i18n", "fully unicode host + path"
add "https://xn--r8jz45g.xn--zckzah/%E3%83%91%E3%82%B9",
    "https://xn--r8jz45g.xn--zckzah/%E3%83%91%E3%82%B9",
    "i18n", "punycode host with encoded path"
add "https://cache.example.io/asset%252Fmain.css",
    "https://cache.example.io/asset%252Fmain.css",
    "encoding_mess", "double percent-encoded slash"
add "https://search.example.io/q?query=new+york+city",
    "https://search.example.io/q?query=new+york+city",
    "encoding_mess", "plus-as-space in query"
add "https://search.example.io/q?query=new%20york%20city",
    "https://search.example.io/q?query=new%20york%20city",
    "encoding_mess", "%20 space equivalent"
add "https://search.example.io/q?query=hello world&lang=en",
    "https://search.example.io/q?lang={locale}&query=hello world",
    "encoding_mess", "unencoded literal space in query"
add "https://api.example.io/eval?expr={a|b}&mode=or",
    "https://api.example.io/eval?expr={a|b}&mode=or",
    "encoding_mess", "unencoded braces and pipe"
add "https://api.example.io/note?text=she said \"hi\"",
    "https://api.example.io/note?text=she said \"hi\"",
    "encoding_mess", "unencoded quotes and space"
add "HtTpS://ExAmPle.COM/Path/To/Thing",
    "https://example.com/Path/To/Thing",
    "encoding_mess", "mixed-case scheme and host"
add "https://files.example.io/dir%2Fsub%2Ffile.txt",
    "https://files.example.io/dir%2Fsub%2Ffile.txt",
    "encoding_mess", "encoded slashes inside single segment"
add "https://api.example.io/path?a=%zz&b=%2",
    "https://api.example.io/path?a=%zz&b=%2",
    "encoding_mess", "invalid/truncated percent sequences"
add "https://api.example.io/redir?url=http%3A%2F%2Fother.io%2Fp%3Fx%3D1%26y%3D2",
    "https://api.example.io/redir?url={url}",
    "encoding_mess", "fully encoded nested URL value"
add "http://192.168.1.50:8080/health",
    "http://192.168.1.50:8080/health",
    "infrastructure", "IPv4 host with port"
add "http://10.0.0.7/admin/status",
    "http://10.0.0.7/admin/status",
    "infrastructure", "private IPv4 no port"
add "http://[2001:db8:85a3::8a2e:370:7334]:9000/metrics",
    "http://[2001:db8:85a3::8a2e:370:7334]:9000/metrics",
    "infrastructure", "bracketed IPv6 with port"
add "http://[fe80::1%25eth0]/",
    "http://[fe80::1%25eth0]/",
    "infrastructure", "IPv6 link-local with encoded zone id"
add "http://localhost:3000/api/v1/ping",
    "http://localhost:3000/api/{version}/ping",
    "infrastructure", "localhost dev port"
add "http://payments.svc.cluster.local:8443/grpc",
    "http://payments.svc.cluster.local:8443/grpc",
    "infrastructure", "k8s internal service DNS"
add "http://0.0.0.0:5000/",
    "http://0.0.0.0:5000/",
    "infrastructure", "wildcard bind address"
add "https://www.example.com./index.html",
    "https://www.example.com./{file}",
    "infrastructure", "trailing-dot FQDN"
add "http://[::1]:6379/",
    "http://[::1]:6379/",
    "infrastructure", "IPv6 loopback shorthand"
add "https://api-staging.internal:443/v1/flags",
    "https://api-staging.internal/{version}/flags",
    "infrastructure", "internal hostname explicit 443"
add "https://cdn.example.io/assets/app.a3f8b2.min.js",
    "https://cdn.example.io/assets/{file}",
    "files_media", "content-hashed versioned asset"
add "https://cdn.example.io/img/hero@2x.webp?v=8827",
    "https://cdn.example.io/img/{email}?v={integer}",
    "files_media", "retina asset + cache-buster — known edge: email shape wins over file for name@NxN.ext"
add "https://cdn.example.io/downloads/report-2024-q1.pdf",
    "https://cdn.example.io/downloads/{file}",
    "files_media", "dated document filename"
add "https://cdn.example.io/releases/app-1.4.2-darwin-arm64.tar.gz",
    "https://cdn.example.io/releases/{file}",
    "files_media", "multi-dot archive with double extension"
add "https://media.example.io/video/clip.mp4?range=bytes%3D0-1048575",
    "https://media.example.io/video/{file}?range=bytes%3D0-1048575",
    "files_media", "byte-range-ish param"
add "https://cdn.example.io/a/b/c/d/e/f/g/h/thumb_128x128.png",
    "https://cdn.example.io/a/b/c/d/e/f/g/h/{file}",
    "files_media", "deep CDN path + dimension token"
add "https://cdn.example.io/fonts/Inter-Bold.woff2?ts=1705315200",
    "https://cdn.example.io/fonts/{file}?ts={timestamp}",
    "files_media", "font asset with timestamp buster"
add "https://cdn.example.io/vendor/jquery-3.7.1.min.js.map",
    "https://cdn.example.io/vendor/{file}",
    "files_media", "sourcemap double extension"
add "https://media.example.io/hls/stream/master.m3u8",
    "https://media.example.io/hls/stream/{file}",
    "files_media", "HLS manifest"
add "https://cdn.example.io/i/AbCdEf123456.jpg",
    "https://cdn.example.io/i/{file}",
    "files_media", "opaque short-id image"
add "https://example.io//double//slash///path",
    "https://example.io/double/slash/path",
    "structural_edge", "empty segments from repeated slashes"
add "https://example.io/trailing/slash/",
    "https://example.io/trailing/slash",
    "structural_edge", "trailing slash"
add "https://example.io/a/./b/../c",
    "https://example.io/a/c",
    "structural_edge", "dot and dot-dot segments"
add "https://example.io/shop;jsessionid=9F8B7C6D5E4F30211223344556677889",
    "https://example.io/shop;jsessionid=9F8B7C6D5E4F30211223344556677889",
    "structural_edge", "matrix param jsessionid"
add "https://alice:s3cr3t@example.io/private",
    "https://alice:s3cr3t@example.io/private",
    "structural_edge", "userinfo credentials in authority"
add "https://app.example.io/dashboard#/reports/2024/q1",
    "https://app.example.io/dashboard",
    "structural_edge", "SPA fragment carrying a route — fragments (SPA routes) are dropped by design"
add "https://example.io/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v",
    "https://example.io/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v",
    "structural_edge", "extremely long 22-segment path"
add "https://example.io/x/y/z/1/2/3",
    "https://example.io/x/y/z/{z_id}/{integer}/{integer}",
    "structural_edge", "single-char segments"
add "https://example.io/t/RmFrZVZlcnlMb25nT3BhcXVlVG9rZW5UaGF0R29lc09uQW5kT25BbmRPbkZvckFXaGlsZVdpdGhvdXRBbnlPYnZpb3VzU3RydWN0dXJlSnVzdEJhc2U2NElzaFN0dWZmMTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFla",
    "https://example.io/t/{t_id}",
    "structural_edge", "200+ char opaque token segment"
add "https://example.io/path;v=1.1;lang=en/resource",
    "https://example.io/path;v=1.1;lang=en/resource",
    "structural_edge", "multiple matrix params mid-path"
add "https://example.io/page#section?notaquery=1",
    "https://example.io/page",
    "structural_edge", "query-looking text inside fragment — fragments are dropped by design"
add "mailto:support@northwind.com?subject=Order%20Help&body=Hi%20there",
    "mailto:support@northwind.com?subject=Order%20Help&body=Hi%20there",
    "non_http_scheme", "mailto with subject/body params"
add "mailto:one@x.io,two@y.io",
    "mailto:one@x.io,two@y.io",
    "non_http_scheme", "multiple recipients no host authority"
add "urn:isbn:9780262033848",
    "urn:isbn:{timestamp}",
    "non_http_scheme", "URN ISBN namespace — known edge: 13-digit ISBN falls in the ms-timestamp window"
add "urn:uuid:9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c",
    "urn:uuid:{uuid_uuid}",
    "non_http_scheme", "URN UUID namespace — cosmetic: uuid namespace + uuid type duplicate into the hint"
add "ftp://ftp.gnu.org/gnu/bash/bash-5.2.tar.gz",
    "ftp://ftp.gnu.org/gnu/bash/{file}",
    "non_http_scheme", "classic FTP file URL"
add "tel:+1-415-555-0132",
    "tel:+1-415-555-0132",
    "non_http_scheme", "tel scheme with formatting"
add "slack://channel?team=T024BE7LD&id=C024BE7LR",
    "slack://channel/?id={opaque_id}&team={opaque_id}",
    "non_http_scheme", "custom app scheme with params"
add "vscode://file/Users/dpepper/code/app.rb:42:5",
    "vscode://file/Users/dpepper/code/app.rb:42:5",
    "non_http_scheme", "editor deep-link with line:col"
add "sms:+14155550132?body=on%20my%20way",
    "sms:+14155550132?body=on%20my%20way",
    "non_http_scheme", "sms scheme with body"
add "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a",
    "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a",
    "non_http_scheme", "magnet link, no host, query only"
add "https://blog.northwind.com/post/spring-sale?utm_source=newsletter&utm_medium=email&utm_campaign=spring2024&utm_content=hero&utm_term=shoes",
    "https://blog.northwind.com/post/{post_id}?utm_campaign={opaque_id}&utm_content=hero&utm_medium=email&utm_source=newsletter&utm_term=shoes",
    "tracking_junk", "full utm cluster"
add "https://blog.northwind.com/post/deal?gclid=Cj0KCQiA1AbCDEfGhIjKlMnOpQr",
    "https://blog.northwind.com/post/deal?gclid={opaque_id}",
    "tracking_junk", "Google click id"
add "https://blog.northwind.com/post/deal?fbclid=IwAR0aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890",
    "https://blog.northwind.com/post/deal?fbclid={opaque_id}",
    "tracking_junk", "Facebook click id"
add "https://blog.northwind.com/post/deal?msclkid=9f8b7c6d5e4f3021abcd1234ef567890",
    "https://blog.northwind.com/post/deal?msclkid={hash}",
    "tracking_junk", "Microsoft click id"
add "https://go.northwind.com/r?next=https%3A%2F%2Fapp.northwind.com%2Fdashboard%3Ftab%3Dbilling",
    "https://go.northwind.com/r?next=https%3A%2F%2Fapp.northwind.com%2Fdashboard%3Ftab%3Dbilling",
    "tracking_junk", "nested encoded redirect target"
add "https://go.northwind.com/out?u=https://partner.io/land&aff=12345&sub=email",
    "https://go.northwind.com/out?aff={integer}&sub=email&u={url}",
    "tracking_junk", "unencoded nested url in redirect"
add "https://blog.northwind.com/p?utm_source=twitter&utm_source=x&ref=share",
    "https://blog.northwind.com/p?ref=share&utm_source=x",
    "tracking_junk", "duplicate utm_source + ref — repeated params collapse last-wins by design"
add "https://track.northwind.com/pixel.gif?e=view&cid=9f8b7c6d&t=1705315200",
    "https://track.northwind.com/{file}?cid={opaque_id}&e=view&t={timestamp}",
    "tracking_junk", "tracking pixel beacon"
add "https://blog.northwind.com/post?mc_cid=abc123def4&mc_eid=987654abcd",
    "https://blog.northwind.com/post?mc_cid={opaque_id}&mc_eid={opaque_id}",
    "tracking_junk", "Mailchimp campaign ids"
add "https://go.northwind.com/l/click?upn=aBcDeF&next=%2Fpricing%3Fplan%3Dpro",
    "https://go.northwind.com/l/click?next=%2Fpricing%3Fplan%3Dpro&upn=aBcDeF",
    "tracking_junk", "marketing click wrapper + encoded path"
add "https://legacy.northwind.com/cgi-bin/search.pl?q=widgets&cat=42",
    "https://legacy.northwind.com/{slug}/{opaque_id}?cat={integer}&q=widgets",
    "legacy_web", "cgi-bin perl script"
add "https://legacy.northwind.com/product.php?id=123&ref=home",
    "https://legacy.northwind.com/{opaque_id}?id={integer}&ref=home",
    "legacy_web", "php id query"
add "https://legacy.northwind.com/Default.aspx?__VIEWSTATE=dDwtMTM3NDkwNTYwNTs7Ppr7&id=88",
    "https://legacy.northwind.com/{opaque_id}?__VIEWSTATE={opaque_id}&id={integer}",
    "legacy_web", "aspx ViewState-ish param"
add "https://legacy.northwind.com/orders/submitOrder.do?orderId=9912&action=confirm",
    "https://legacy.northwind.com/orders/{order_id}?action=confirm&orderId={integer}",
    "legacy_web", "struts .do endpoint"
add "https://legacy.northwind.com/~alice/public_html/index.html",
    "https://legacy.northwind.com/{opaque_id}/{slug}/{file}",
    "legacy_web", "tilde user home dir"
add "https://legacy.northwind.com/servlet/CatalogServlet?category=books",
    "https://legacy.northwind.com/servlet/CatalogServlet?category=books",
    "legacy_web", "java servlet path"
add "https://legacy.northwind.com/index.jsp;jsessionid=A1B2C3D4E5?p=2",
    "https://legacy.northwind.com/index.jsp;jsessionid=A1B2C3D4E5?p={integer}",
    "legacy_web", "jsp with jsessionid matrix param"
add "https://legacy.northwind.com/wp-admin/admin-ajax.php?action=get_posts&nonce=abc123",
    "https://legacy.northwind.com/{slug}/{opaque_id}?action={slug}&nonce={opaque_id}",
    "legacy_web", "wordpress admin-ajax"
add "https://legacy.northwind.com/cfm/detail.cfm?ProductID=451&CFID=99&CFTOKEN=88",
    "https://legacy.northwind.com/cfm/{cfm_id}?CFID={integer}&CFTOKEN={integer}&ProductID={integer}",
    "legacy_web", "coldfusion cfm with CFID/CFTOKEN"
add "https://legacy.northwind.com/cgi-bin/mailform.cgi",
    "https://legacy.northwind.com/{slug}/{opaque_id}",
    "legacy_web", "bare cgi endpoint no query"
add "https://api.acme.io/graphql?query=%7Buser(id%3A%2242213%22)%7Bname%20email%7D%7D",
    "https://api.acme.io/graphql?query=%7Buser(id%3A%2242213%22)%7Bname%20email%7D%7D",
    "graphql", "encoded GraphQL query in GET"
add "https://api.acme.io/graphql?operationName=GetUser&variables=%7B%22id%22%3A%2242213%22%7D&extensions=%7B%22persistedQuery%22%3A%7B%22sha256Hash%22%3A%22abc123%22%7D%7D",
    "https://api.acme.io/graphql?extensions=%7B%22persistedQuery%22%3A%7B%22sha256Hash%22%3A%22abc123%22%7D%7D&operationName=GetUser&variables=%7B%22id%22%3A%2242213%22%7D",
    "graphql", "persisted query with variables/extensions"
add "https://api.acme.io/graphql",
    "https://api.acme.io/graphql",
    "graphql", "bare graphql endpoint (POST in practice)"
add "https://api.acme.io/graphiql?query=query%7B__schema%7Btypes%7Bname%7D%7D%7D",
    "https://api.acme.io/graphiql?query=query%7B__schema%7Btypes%7Bname%7D%7D%7D",
    "graphql", "introspection query in explorer"
add "https://api.acme.io/graphql?query={me{id}}&variables={}",
    "https://api.acme.io/graphql?query={me{id}}&variables={}",
    "graphql", "unencoded braces GraphQL query"
add "wss://realtime.acme.io/socket?token=eyJhbGciOiJIUzI1NiJ9.eyJ1IjoxMjN9.abc&v=2",
    "wss://realtime.acme.io/socket?token={jwt}&v={integer}",
    "websocket", "secure websocket with token"
add "ws://localhost:3000/cable",
    "ws://localhost:3000/cable",
    "websocket", "insecure ws localhost actioncable"
add "wss://gateway.acme.io/v1/stream?channels=orders,alerts&heartbeat=30",
    "wss://gateway.acme.io/{version}/stream?channels=orders,alerts&heartbeat={integer}",
    "websocket", "ws with comma channel list"
add "wss://push.acme.io/ws/9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c",
    "wss://push.acme.io/ws/{w_uuid}",
    "websocket", "ws session id in path"
add "https://ci.acme.io/hooks/github?event=push&delivery=72d3162e-cc78-11e3-81ab-4c9367dc0958",
    "https://ci.acme.io/hooks/github?delivery={uuid}&event=push",
    "webhook", "github webhook with delivery uuid"
add "https://hooks.acme.io/stripe/9f8b7c6d?sig=t%3D1705315200%2Cv1%3Dabcdef1234567890",
    "https://hooks.acme.io/stripe/{stripe_id}?sig=t%3D1705315200%2Cv1%3Dabcdef1234567890",
    "webhook", "stripe signature timestamp+v1"
add "https://hooks.acme.io/twilio/sms?From=%2B14155550132&To=%2B14155550199&Body=STOP",
    "https://hooks.acme.io/twilio/sms?Body=STOP&From=%2B14155550132&To=%2B14155550199",
    "webhook", "twilio inbound sms callback"
add "https://hooks.acme.io/endpoint/wh_2Hq8XZ2eZvKYlo2Cn/retry?attempt=3",
    "https://hooks.acme.io/endpoint/{endpoint_id}/retry?attempt={integer}",
    "webhook", "prefixed webhook id + retry counter"
add "https://hooks.acme.io/generic?type=order.created&ts=1705315200&hmac=9f8b7c6d5e4f3021",
    "https://hooks.acme.io/generic?hmac={opaque_id}&ts={timestamp}&type={opaque_id}",
    "webhook", "generic event with hmac"
add "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
    "data_uri", "base64 png data URI"
add "data:text/plain;charset=utf-8,Hello%20World",
    "data:text/plain;charset=utf-8,Hello%20World",
    "data_uri", "plain text data URI with encoding"
add "data:application/json,%7B%22a%22%3A1%7D",
    "data:application/json,%7B%22a%22%3A1%7D",
    "data_uri", "json data URI no base64"
add "blob:https://app.acme.io/9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c",
    "blob:https://app.acme.io/9f8b7c6d-3e2a-4f1b-8a9c-0d1e2f3a4b5c",
    "data_uri", "blob URL with origin + uuid"
err "https://",
    "reject_garbage", "scheme only, no authority"
add "http://:80/",
    "http://:80/",
    "lenient_accept", "port with empty host — parser is deliberately lenient"
err "//cdn.example.com/x.js",
    "reject_garbage", "protocol-relative, no scheme"
add "http://exa mple.com/",
    "http://exa mple.com/",
    "lenient_accept", "literal space in host — parser is deliberately lenient"
add "https://example.com/path%00/etc",
    "https://example.com/path%00/etc",
    "lenient_accept", "null-byte percent sequence — parser is deliberately lenient"
err "http:///no-host/path",
    "reject_garbage", "empty authority triple slash"
err "ht!tp://example.com/",
    "reject_garbage", "illegal char in scheme"
add "https://user@:pass@host.io/x",
    "https://user@:pass@host.io/x",
    "lenient_accept", "malformed userinfo double @ — parser is deliberately lenient"
add "https://example.com:99999/",
    "https://example.com:99999/",
    "lenient_accept", "port out of range — parser is deliberately lenient"
err "just some pasted text not a url at all",
    "reject_garbage", "free text, no scheme or host"

File.write(OUT, JSON.pretty_generate({ "urls" => URLS }) + "\n")
puts "Built #{URLS.size} URL calibration entries"
puts "Wrote #{OUT}"
