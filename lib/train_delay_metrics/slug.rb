module TrainDelayMetrics
  module Slug
    # German umlauts and ß are transliterated to their ASCII equivalents so
    # filenames remain portable. Other non-ASCII letters/digits are dropped.
    TRANSLIT = {
      "ä" => "ae", "ö" => "oe", "ü" => "ue",
      "Ä" => "Ae", "Ö" => "Oe", "Ü" => "Ue",
      "ß" => "ss"
    }.freeze

    def self.slugify(value)
      s = value.to_s.dup
      TRANSLIT.each { |k, v| s.gsub!(k, v) }
      s.gsub(/[^A-Za-z0-9]+/, "_").gsub(/^_+|_+$/, "")
    end
  end
end
