describe Iriq::Event do
  describe "Corpus#events_for" do
    let(:corpus) { Iriq::Corpus.new }

    it "emits HostSeen, PathLengthSeen, RawShapeSeen, FingerprintSeen, per-segment PositionSeen, then ClusterAddition" do
      events = corpus.events_for("https://foo.com/users/123")
      kinds  = events.map(&:class)

      expect(kinds.first).to eq(Iriq::Event::HostSeen)
      expect(kinds.last).to  eq(Iriq::Event::ClusterAddition)
      expect(kinds.count(Iriq::Event::PositionSeen)).to eq(2)
      expect(kinds).to include(Iriq::Event::PathLengthSeen,
                               Iriq::Event::RawShapeSeen,
                               Iriq::Event::FingerprintSeen)
    end

    it "events_for is pure — no storage side-effects" do
      before_size = corpus.size
      corpus.events_for("https://foo.com/users/123")
      expect(corpus.size).to eq(before_size)
    end

    it "PositionSeen carries a Position with the typed prefix" do
      events = corpus.events_for("https://foo.com/users/123")
      pos_events = events.grep(Iriq::Event::PositionSeen)
      expect(pos_events.map { |e| e.position.locator }).to eq(["", "/users"])
    end
  end
end

describe Iriq::Reducer do
  it "dispatches each event class to its registered reducer(s)" do
    Iriq::Reducer::DEFAULTS.each_key do |event_class|
      expect(Iriq::Reducer::DEFAULTS[event_class]).not_to be_empty
    end
  end

  it "applies HostSeen to increment_host" do
    storage = Iriq::Storage::Memory.new
    Iriq::Reducer.apply(Iriq::Event::HostSeen.new("foo.com"), storage)
    expect(storage.host_counts["foo.com"]).to eq(1)
  end

  it "applies ClusterAddition and returns the Cluster" do
    storage = Iriq::Storage::Memory.new
    iri     = Iriq.parse("https://foo.com/users/123")
    event   = Iriq::Event::ClusterAddition.new(
      "key", "foo.com", "https", "/users/{integer}", iri,
    )
    cluster = Iriq::Reducer.apply(event, storage)
    expect(cluster).to be_a(Iriq::Cluster)
    expect(cluster.key).to eq("key")
  end

  it "no-ops for unknown events (defensive — keeps unregistered events from blowing up)" do
    unknown = Class.new(Struct.new(:foo)).new("bar")
    expect { Iriq::Reducer.apply(unknown, Iriq::Storage::Memory.new) }.not_to raise_error
  end
end
