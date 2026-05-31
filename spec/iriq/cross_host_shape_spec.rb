describe "cross-host shape learning" do
  let(:corpus) { Iriq::Corpus.new }

  describe "Corpus#cross_host_shapes" do
    it "returns empty when no shape is seen on multiple hosts" do
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://foo.com/users/2")
      expect(corpus.cross_host_shapes).to be_empty
    end

    it "returns shapes seen on >=min_hosts hosts" do
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://bar.com/users/2")

      result = corpus.cross_host_shapes
      expect(result.size).to eq(1)
      entry = result.first
      expect(entry.shape).to eq("/users/{user_id}")
      expect(entry.hosts.to_a.sort).to eq(["bar.com", "foo.com"])
      expect(entry.host_count).to eq(2)
      expect(entry.observation_count).to eq(2)
    end

    it "honors min_hosts to require stronger cross-host evidence" do
      corpus.observe("https://foo.com/users/1")
      corpus.observe("https://bar.com/users/2")

      expect(corpus.cross_host_shapes(min_hosts: 2).size).to eq(1)
      expect(corpus.cross_host_shapes(min_hosts: 3)).to be_empty
    end

    it "ranks by host_count desc, then observation_count desc, then shape asc" do
      # /users/{user_id} on 3 hosts, /posts/{post_id} on 2 hosts.
      3.times { |i| corpus.observe("https://h#{i}.com/users/1") }
      2.times { |i| corpus.observe("https://j#{i}.com/posts/1") }

      shapes = corpus.cross_host_shapes
      expect(shapes.map(&:shape)).to eq(["/users/{user_id}", "/posts/{post_id}"])
    end

    it "ignores URN clusters (no host)" do
      corpus.observe("urn:isbn:0451450523")
      corpus.observe("urn:isbn:1234567890")
      expect(corpus.cross_host_shapes).to be_empty
    end

    it "rolls up all clusters under a shape across hosts" do
      # Each host contributes 5 observations to /users/{user_id}; total = 15.
      3.times do |h|
        5.times do |u|
          corpus.observe("https://host#{h}.com/users/#{u + 1}")
        end
      end
      entry = corpus.cross_host_shapes.first
      expect(entry.host_count).to eq(3)
      expect(entry.observation_count).to eq(15)
    end
  end

  describe Iriq::CrossHostShape do
    it "freezes hosts for safe sharing" do
      s = described_class.new(shape: "/x", hosts: ["a.com", "b.com"], observation_count: 4)
      expect(s.hosts).to be_frozen
    end

    it "to_h emits sorted hosts and host_count" do
      s = described_class.new(shape: "/x", hosts: ["b.com", "a.com"], observation_count: 4)
      h = s.to_h
      expect(h[:hosts]).to     eq(["a.com", "b.com"])
      expect(h[:host_count]).to eq(2)
    end
  end
end
