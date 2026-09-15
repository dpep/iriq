describe Iriq::Cluster, "#segment_stats" do
  it "lists a position's values by descending count, then value" do
    clusterer = Iriq::Clusterer.new
    # First seen: 6, 5, 11, 3. Reading a .db back used to yield byte order.
    %w[6 5 11 6 5 11 11 3].each { |v| clusterer.add("https://foo.com/users/#{v}") }

    values = clusterer.clusters.first.segment_stats[1][:values]

    expect(values.to_a).to eq([["11", 3], ["5", 2], ["6", 2], ["3", 1]])
  end
end
