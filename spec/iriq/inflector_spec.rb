describe Iriq::Inflector do
  describe ".singularize" do
    it "dispatches to the configured adapter" do
      fake = Module.new do
        def self.singularize(_word) = "FAKE"
      end
      original = described_class.adapter
      described_class.adapter = fake
      begin
        expect(described_class.singularize("anything")).to eq("FAKE")
      ensure
        described_class.adapter = original
      end
    end
  end

  describe ".default_adapter" do
    it "prefers ActiveSupport if it can be required" do
      expect(described_class).to receive(:require).with("active_support/inflector").and_return(true)
      expect(described_class.default_adapter).to eq(described_class::ActiveSupportAdapter)
    end

    it "falls back to BuiltinAdapter when ActiveSupport isn't available" do
      expect(described_class).to receive(:require).with("active_support/inflector").and_raise(LoadError)
      expect(described_class.default_adapter).to eq(described_class::BuiltinAdapter)
    end
  end

  describe Iriq::Inflector::ActiveSupportAdapter do
    it "delegates to ActiveSupport::Inflector.singularize" do
      inflector = Module.new do
        def self.singularize(_word); end
      end
      stub_const("ActiveSupport::Inflector", inflector)
      expect(inflector).to receive(:singularize).with("users").and_return("user")
      expect(described_class.singularize("users")).to eq("user")
    end
  end

  describe Iriq::Inflector::BuiltinAdapter do
    {
      # plain
      "users"        => "user",
      "posts"        => "post",
      "orders"       => "order",
      "comments"     => "comment",
      "articles"     => "article",
      "items"        => "item",
      "projects"     => "project",
      # -ies
      "categories"   => "category",
      "companies"    => "company",
      "cities"       => "city",
      "libraries"    => "library",
      # -ses / -es
      "addresses"    => "address",
      "statuses"     => "status",
      "classes"      => "class",
      "boxes"        => "box",
      "buses"        => "bus",
      "churches"     => "church",
      # latin-ish
      "matrices"     => "matrix",
      "indices"      => "index",
      "vertices"     => "vertex",
      "octopi"       => "octopus",
      "analyses"     => "analysis",
      "diagnoses"    => "diagnosis",
      "theses"       => "thesis",
      # -ves
      "knives"       => "knife",
      "leaves"       => "leaf",
      "wolves"       => "wolf",
      # irregulars
      "people"       => "person",
      "children"     => "child",
      "men"          => "man",
      "women"        => "woman",
      "mice"         => "mouse",
      # -ice
      "lice"         => "louse",
      # -oes
      "heroes"       => "hero",
      "tomatoes"     => "tomato",
      # uncountable
      "news"         => "news",
      "fish"         => "fish",
      "sheep"        => "sheep",
      # already singular / no rule
      "data"         => "data",
      "person"       => "person",
    }.each do |plural, singular|
      it "singularizes #{plural.inspect} to #{singular.inspect}" do
        expect(described_class.singularize(plural)).to eq(singular)
      end
    end

    it "preserves capitalization" do
      expect(described_class.singularize("Users")).to eq("User")
      expect(described_class.singularize("USERS")).to eq("USER")
    end

    it "preserves irregular case" do
      expect(described_class.singularize("People")).to eq("Person")
    end

    it "returns empty/nil unchanged" do
      expect(described_class.singularize("")).to eq("")
      expect(described_class.singularize(nil)).to be_nil
    end
  end
end
