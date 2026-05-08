RSpec.describe TrainDelayMetrics::TrainName do
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
