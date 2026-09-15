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

  # Each insert into a capped position must count what the other writers
  # committed, so the position ends holding exactly `cap` values.
  it "keeps a position at its value cap while CLI writers interleave" do
    require "sqlite3"
    Dir.mktmpdir do |dir|
      path = File.join(dir, "capped.db")
      cap  = 20
      Iriq::Corpus.open(path, max_values_per_position: cap).close

      root    = File.expand_path("../..", __dir__)
      command = [RbConfig.ruby, "-I", File.join(root, "lib"), File.join(root, "exe/iriq"), "-n", "--corpus", path]
      writers = WRITERS.times.map { IO.popen(command, "r+") }
      # Barrier: every writer has booted and opened the corpus before the
      # interleaved lines start.
      writers.each { |w| w.puts("https://warm.example.com/x") }
      writers.each(&:gets)
      # Strict round-robin: each line is echoed (committed) before the next
      # writer's turn, so every writer's view goes stale between its lines.
      30.times do |i|
        writers.each_with_index do |w, n|
          w.puts("https://cap.example.com/t/w#{n}v#{i}")
          w.gets
        end
      end
      statuses = writers.map do |w|
        w.close_write
        w.read
        w.close
        $?
      end
      expect(statuses).to all(be_success)

      db = SQLite3::Database.new(path)
      counts = db.execute(
        "SELECT locator, COUNT(*) FROM position_values WHERE host = 'cap.example.com' GROUP BY locator",
      ).to_h
      db.close
      expect(counts).to eq("" => 1, "/t" => cap)
    end
  end
end
