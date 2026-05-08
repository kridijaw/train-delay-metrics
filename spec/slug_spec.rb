RSpec.describe TrainDelayMetrics::Slug do
  it "transliterates German umlauts and ß to ASCII" do
    expect(described_class.slugify("Köln")).to eq("Koeln")
    expect(described_class.slugify("München")).to eq("Muenchen")
    expect(described_class.slugify("Bärenstraße")).to eq("Baerenstrasse")
  end

  it "replaces other non-alphanumeric runs with a single underscore and trims" do
    expect(described_class.slugify("berlin sp%")).to eq("berlin_sp")
    expect(described_class.slugify("  foo--bar  ")).to eq("foo_bar")
  end

  it "drops other non-ASCII letters silently (no garbage in filenames)" do
    expect(described_class.slugify("Zürich-€")).to eq("Zuerich")
  end

  it "returns an empty string for input with no slug-able characters" do
    expect(described_class.slugify("---")).to eq("")
  end
end
