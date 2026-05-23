require "date"

# Deterministic synthetic corpus generator — produces a realistic mix of
# RESTful routes (users/orders/orgs/products), static routes (/login,
# /users/me), UUID-based sessions, dated events, search queries, and a small
# long tail. Seeded for reproducibility.
module IriqStreamingFixtures
  HOSTS = %w[
    app.example.com
    api.example.com
    docs.example.com
  ].freeze

  USERS    = (1000..1099).to_a.freeze
  ORGS     = %w[gusto acme globex initech umbrella hooli stark wayne].freeze
  ORDERS   = (50_000..50_200).to_a.freeze
  PRODUCTS = %w[starter-plan pro-plan enterprise-plan payroll-plus time-tracking].freeze
  UUIDS    = %w[
    550e8400-e29b-41d4-a716-446655440000
    6ba7b810-9dad-11d1-80b4-00c04fd430c8
    123e4567-e89b-12d3-a456-426614174000
  ].freeze

  STATIC_PATHS = %w[
    /
    /login
    /logout
    /signup
    /health
    /robots.txt
    /users/me
    /admin
    /admin/settings
  ].freeze

  def self.urls(count: 1_000, seed: 1234)
    rng = Random.new(seed)

    Array.new(count) do
      host   = HOSTS.sample(random: rng)
      path   = sample_path(rng)
      scheme = rng.rand < 0.92 ? "https" : "http"
      "#{scheme}://#{host}#{path}"
    end
  end

  def self.sample_path(rng)
    case rng.rand(100)
    when 0..24
      "/users/#{USERS.sample(random: rng)}"
    when 25..39
      "/users/#{USERS.sample(random: rng)}/orders/#{ORDERS.sample(random: rng)}"
    when 40..54
      "/orgs/#{ORGS.sample(random: rng)}/users/#{USERS.sample(random: rng)}"
    when 55..64
      "/orgs/#{ORGS.sample(random: rng)}/products/#{PRODUCTS.sample(random: rng)}"
    when 65..72
      "/events/#{Date.new(2026, rng.rand(1..12), rng.rand(1..28))}"
    when 73..80
      "/sessions/#{UUIDS.sample(random: rng)}"
    when 81..88
      STATIC_PATHS.sample(random: rng)
    when 89..94
      "/search?q=#{%w[payroll taxes benefits onboarding].sample(random: rng)}&page=#{rng.rand(1..5)}"
    else
      "/weird/#{random_slug(rng)}/#{rng.rand(10_000..99_999)}"
    end
  end

  def self.random_slug(rng)
    words = %w[alpha beta gamma delta omega red blue green fast slow]
    "#{words.sample(random: rng)}-#{words.sample(random: rng)}"
  end
end
