require "date"

# Seeded synthetic IRI generator for spec fixtures. Produces a realistic
# mix of RESTful routes, static routes, dated events, UUID-keyed sessions,
# search queries, and a long tail. Deterministic via :seed.
#
#   IriGenerator.urls(count: 1000, seed: 1234)
#
# Buckets are declared as a weighted table (sums to 1.0) instead of hard-
# coded percentile ranges, so additions don't require re-numbering.
module IriGenerator
  HOSTS = %w[
    app.example.com
    api.example.com
    docs.example.com
  ].freeze

  USERS    = (1000..20_000).to_a.freeze
  ORGS     = %w[gusto acme globex initech umbrella hooli stark wayne].freeze
  ORDERS   = (50_000..50_200).to_a.freeze
  PRODUCTS = %w[starter-plan pro-plan enterprise-plan payroll-plus time-tracking].freeze

  # Small set of "popular" workspace names that the corpus heuristic should
  # learn to keep as stable literals even inside an otherwise
  # high-cardinality slot.
  POPULAR_WORKSPACES = %w[mainspace primary headquarters].freeze

  # Single-word vocabulary for the workspace long tail. Each entry classifies
  # as :literal (no separators, no digits) so the corpus is forced to make a
  # judgment call on cardinality vs. heuristic dominance.
  WORKSPACE_VOCAB = %w[
    alpha beta gamma delta epsilon zeta eta theta iota kappa
    lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega
    red blue green yellow purple orange pink brown black white gray
    silver gold copper bronze ruby emerald sapphire diamond opal pearl
    apple banana cherry elder fig grape kiwi lemon mango papaya quince
    ant bee cat dog elk fox goat hen ibex jay koala lemur moose newt
    owl panther quail raven snake tiger urchin vole wolf yak zebra
    oak elm pine maple birch cedar willow hazel hickory poplar
    wave river ocean mountain valley desert forest meadow canyon
    comet star nebula galaxy planet asteroid moon eclipse aurora
  ].uniq.freeze

  STATIC_PATHS = %w[
    /
    /login
    /logout
    /signup
    /health
    /robots.txt
    /admin
    /admin/settings
  ].freeze

  WORKSPACE_POPULAR_RATIO = 0.20

  # Weighted bucket table. Keys are bucket names, values are sampling
  # weights. Weights are normalized at call time, so they don't need to
  # sum to 100 or any specific number.
  BUCKETS = {
    user:           20,
    user_order:     15,
    org_user:       15,
    org_product:    10,
    event:           8,
    session:         8,
    workspace:      10,
    static_path:     6,
    search:          5,
    weird:           3,
  }.freeze

  module_function

  def urls(count: 1_000, seed: 1234, uuid_pool_size: 3)
    rng   = Random.new(seed)
    uuids = generate_uuids(uuid_pool_size, rng)

    Array.new(count) do
      host   = HOSTS.sample(random: rng)
      path   = sample_path(rng, uuids)
      scheme = rng.rand < 0.92 ? "https" : "http"
      "#{scheme}://#{host}#{path}"
    end
  end

  # RFC 4122 v4 UUIDs from the seeded rng — deterministic, valid, and
  # cheap to generate at any pool size.
  def generate_uuids(n, rng)
    Array.new(n) do
      bytes = rng.bytes(16).bytes
      bytes[6] = (bytes[6] & 0x0f) | 0x40 # version 4
      bytes[8] = (bytes[8] & 0x3f) | 0x80 # variant
      hex = bytes.map { |b| b.to_s(16).rjust(2, "0") }.join
      "#{hex[0,8]}-#{hex[8,4]}-#{hex[12,4]}-#{hex[16,4]}-#{hex[20,12]}"
    end
  end

  def sample_path(rng, uuids)
    case pick_bucket(rng)
    when :user        then "/users/#{USERS.sample(random: rng)}"
    when :user_order  then "/users/#{USERS.sample(random: rng)}/orders/#{ORDERS.sample(random: rng)}"
    when :org_user    then "/orgs/#{ORGS.sample(random: rng)}/users/#{USERS.sample(random: rng)}"
    when :org_product then "/orgs/#{ORGS.sample(random: rng)}/products/#{PRODUCTS.sample(random: rng)}"
    when :event       then "/events/#{Date.new(2026, rng.rand(1..12), rng.rand(1..28))}"
    when :session     then "/sessions/#{uuids.sample(random: rng)}"
    when :workspace   then "/workspaces/#{workspace_slug(rng)}"
    when :static_path then STATIC_PATHS.sample(random: rng)
    when :search      then "/search?q=#{search_term(rng)}&page=#{rng.rand(1..5)}"
    when :weird       then "/weird/#{random_slug(rng)}/#{rng.rand(10_000..99_999)}"
    end
  end

  def pick_bucket(rng)
    total = BUCKETS.values.sum
    pick  = rng.rand(total)
    cum   = 0
    BUCKETS.each do |name, weight|
      cum += weight
      return name if pick < cum
    end
  end

  def workspace_slug(rng)
    if rng.rand < WORKSPACE_POPULAR_RATIO
      POPULAR_WORKSPACES.sample(random: rng)
    else
      WORKSPACE_VOCAB.sample(random: rng)
    end
  end

  def search_term(rng)
    %w[payroll taxes benefits onboarding].sample(random: rng)
  end

  def random_slug(rng)
    words = %w[alpha beta gamma delta omega red blue green fast slow]
    "#{words.sample(random: rng)}-#{words.sample(random: rng)}"
  end
end
