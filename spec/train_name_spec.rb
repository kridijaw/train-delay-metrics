require "json"

RSpec.describe TrainDelayMetrics::TrainName do
  JSON.parse(File.read(File.expand_path("shared/train_name_sort_cases.json", __dir__))).each do |c|
    it "sorts shared case: #{c["name"]}" do
      expect(c["input"].sort_by { |n| described_class.sort_key(n) }).to eq(c["expected"])
    end
  end

  it "sorts by alphabetic prefix, then by digit length, then by digit value" do
    names = ["ICE 1052", "ICE 10", "ICE 999", "ICE 100", "IC 50", "ICE 9", "NJ"]
    sorted = names.sort_by { |n| described_class.sort_key(n) }
    expect(sorted).to eq([
      "IC 50",      # IC prefix sorts before ICE
      "ICE 9",      # 1-digit
      "ICE 10",     # 2-digit
      "ICE 100",    # 3-digit
      "ICE 999",    # 3-digit, larger value
      "ICE 1052",   # 4-digit
      "NJ"          # different prefix
    ])
  end

  it "handles names with no number suffix" do
    expect(["NJ", "ICE", "IC"].sort_by { |n| described_class.sort_key(n) }).to eq(["IC", "ICE", "NJ"])
  end

  it "is case-insensitive on the alphabetic prefix" do
    expect(["ice 10", "ICE 9"].sort_by { |n| described_class.sort_key(n) }).to eq(["ICE 9", "ice 10"])
  end
end
