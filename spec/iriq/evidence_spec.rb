describe Iriq::Evidence do
  describe ".segment" do
    it "constructs segment Evidence" do
      r = described_class.segment(
        index: 0, value: "users", source: :recognizer,
        payload: { type: :literal },
      )
      expect(r.subject_kind).to eq(:segment)
      expect(r.subject).to eq(index: 0, value: "users")
      expect(r.source).to eq(:recognizer)
      expect(r.payload).to eq(type: :literal)
    end
  end

  describe ".position" do
    it "constructs Position Evidence" do
      pos = Iriq::Position.path(host: "foo.com", prefix: "/users")
      r = described_class.position(
        position: pos, source: :corpus,
        payload: { observations: 42 },
      )
      expect(r.subject_kind).to eq(:position)
      expect(r.subject).to eq(pos)
    end
  end

  describe ".cluster" do
    it "constructs cluster Evidence" do
      r = described_class.cluster(
        key: "https://foo.com/users/{integer}", source: :corpus,
        payload: { count: 10 },
      )
      expect(r.subject_kind).to eq(:cluster)
      expect(r.subject).to eq("https://foo.com/users/{integer}")
    end
  end

  describe "validation" do
    it "rejects unknown sources" do
      expect {
        described_class::Record.new(
          subject_kind: :segment, subject: {}, source: :bogus, payload: {},
        )
      }.to raise_error(ArgumentError)
    end

    it "rejects unknown subject_kinds" do
      expect {
        described_class::Record.new(
          subject_kind: :something, subject: {}, source: :recognizer, payload: {},
        )
      }.to raise_error(ArgumentError)
    end
  end
end

describe Iriq::Trace do
  describe ".evidence_for" do
    it "emits a recognizer Evidence per path segment" do
      ev = described_class.evidence_for("https://foo.com/users/123")
      types = ev.select { |r| r.source == :recognizer }.map { |r| r.payload[:type] }
      expect(types).to eq(%i[literal integer])
    end

    it "emits a canonical_date policy Evidence when the value gets canonicalized" do
      # Slash-form dates only survive in a single segment via query params;
      # URL path separators split them into multiple integer segments.
      ev = described_class.evidence_for("https://foo.com/c?d=2024/01/15")
      policy = ev.find { |r| r.source == :policy && r.payload[:rule] == :canonical_date }
      expect(policy).not_to be_nil
      expect(policy.payload[:after]).to eq("2024-01-15")
    end

    it "emits a param_name_hint Evidence when a param name lifts the type" do
      ev = described_class.evidence_for("https://foo.com/c?phone=unknown")
      hint = ev.find { |r| r.source == :neighbor && r.payload[:rule] == :param_name_hint }
      expect(hint).not_to be_nil
      expect(hint.payload[:before]).to eq(:literal)
      expect(hint.payload[:after]).to eq(:phone)
    end

    it "emits ip_umbrella_collapse Evidence for ipv4/ipv6 values" do
      ev = described_class.evidence_for("https://foo.com/hosts/192.168.1.1")
      ip = ev.find { |r| r.source == :policy && r.payload[:rule] == :ip_umbrella_collapse }
      expect(ip).not_to be_nil
      expect(ip.payload[:from]).to eq(:ipv4)
    end
  end

  describe ".for / .evidence_for parity" do
    it ".for note strings come from .evidence_for note strings" do
      input = "https://shop.com/pricing/usd?currency=eur"
      view  = described_class.for(input)
      ev    = described_class.evidence_for(input)
      view_notes = (view[:path] + (view[:query] || [])).flat_map { |r| r[:notes] }
      ev_notes   = ev.flat_map(&:notes)
      expect(view_notes.sort).to eq(ev_notes.sort)
    end
  end
end
