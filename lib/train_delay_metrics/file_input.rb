module TrainDelayMetrics
  module FileInput
    OUT_DIR = "out".freeze

    # Resolves a bare or relative path. Order of attempts:
    #   1. literal `raw` (returned untouched if it exists)
    #   2. OUT_DIR/<raw>
    #   3. OUT_DIR/<raw><extension>            (when extension: is given)
    #   4. OUT_DIR/<prefix><raw>               (when prefix: is given)
    #   5. OUT_DIR/<prefix><raw><extension>    (when both are given)
    #
    # Step 4/5 lets a caller declare a filename convention so that a short
    # nickname like `berlin` resolves to `out/station_berlin.txt`. Returns nil
    # if no candidate exists, or if `raw` contains a path separator and the
    # literal path was not found (that signals "user typed an explicit path").
    def self.resolve(raw, prefix: nil, extension: nil)
      return raw if File.exist?(raw)
      return nil if raw.include?(File::SEPARATOR)

      candidates = [raw]
      candidates << raw + extension if extension && !raw.end_with?(extension)
      if prefix && !raw.start_with?(prefix)
        prefixed = prefix + raw
        candidates << prefixed
        candidates << prefixed + extension if extension && !prefixed.end_with?(extension)
      end

      candidates.uniq.each do |name|
        path = File.join(OUT_DIR, name)
        return path if File.exist?(path)
      end
      nil
    end

    # Reads non-empty trimmed lines from `path`.
    def self.read_lines(path)
      File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
    end
  end
end
