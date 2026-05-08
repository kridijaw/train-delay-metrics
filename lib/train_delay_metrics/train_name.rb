module TrainDelayMetrics
  module TrainName
    # Sort key for train names that:
    # - sorts the alphabetic prefix alphabetically (case-insensitive),
    # - then sorts numeric runs by digit length first, then numeric value,
    #   so "ICE 999" comes before "ICE 1052" (3-digit before 4-digit).
    def self.sort_key(name)
      name.to_s.scan(/(\d+|\D+)/).flatten.map do |part|
        if part.match?(/\A\d+\z/)
          [1, part.length, part.to_i]
        else
          [0, part.downcase]
        end
      end
    end
  end
end
