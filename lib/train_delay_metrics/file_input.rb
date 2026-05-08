module TrainDelayMetrics
  module FileInput
    OUT_DIR = "out".freeze

    # Resolves a bare or relative path: returns the literal path if it exists,
    # else (for bare filenames) tries OUT_DIR/<file>. Returns nil if neither
    # exists.
    def self.resolve(raw)
      return raw if File.exist?(raw)
      return nil if raw.include?(File::SEPARATOR)
      candidate = File.join(OUT_DIR, raw)
      File.exist?(candidate) ? candidate : nil
    end

    # Reads non-empty trimmed lines from `path`.
    def self.read_lines(path)
      File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
    end
  end
end
