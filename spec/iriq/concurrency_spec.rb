require "tmpdir"

# The SQLite backend claims to support concurrent observers (WAL journaling
# plus a busy_timeout). Prove it: fork N processes that each open the SAME
# .db corpus — including racing to initialize it from scratch — and observe
# a disjoint slice of URLs. The reopened corpus must contain every
# observation with consistent aggregates.
describe "SQLite corpus concurrency" do
  before { skip "fork not supported on this platform" unless Process.respond_to?(:fork) }

  WRITERS       = 4
  URLS_PER_FORK = 50

  def urls_for(writer)
    Array.new(URLS_PER_FORK) do |j|
      "https://c#{writer}.example.com/users/#{(writer * URLS_PER_FORK) + j}"
    end
  end

  it "supports concurrent observers against the same corpus file" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "corpus.db")

      pids = WRITERS.times.map do |i|
        fork do
          # exit! skips the parent's at_exit hooks (RSpec autorun, SimpleCov).
          begin
            corpus = Iriq::Corpus.open(path)
            urls_for(i).each { |u| corpus.observe(u) }
            corpus.close
            exit!(0)
          rescue Exception => e # rubocop:disable Lint/RescueException
            warn "concurrent observer #{i} crashed: #{e.class}: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
            exit!(1)
          end
        end
      end

      statuses = pids.map { |pid| Process.wait2(pid).last }
      expect(statuses).to all(be_success)

      corpus = Iriq::Corpus.open(path)
      total  = WRITERS * URLS_PER_FORK

      expect(corpus.observed_iri_count).to eq(total)

      expected_hosts = WRITERS.times.to_h { |i| ["c#{i}.example.com", URLS_PER_FORK] }
      expect(corpus.host_counts).to eq(expected_hosts)

      expect(corpus.raw_shape_counts.values.sum).to eq(total)
      expect(corpus.clusters.sum(&:count)).to eq(total)
      corpus.close
    end
  end
end
