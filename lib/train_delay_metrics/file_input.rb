require_relative "slug"

module TrainDelayMetrics
  module FileInput
    OUT_DIR = "out".freeze

    # Resolves a bare or relative path against the project's `out/` convention.
    #
    # The literal `raw` wins if it exists. Otherwise `raw` is split into a
    # stem by stripping the optional `prefix:` and `extension:`, and looked
    # up under `out/` as each combination of (stem | slugified stem) × bare |
    # +extension | prefix+stem | prefix+stem+extension. Slugifying the stem
    # transliterates German umlauts (ü→ue, ö→oe, ä→ae, ß→ss) so a user can
    # type `düsseldorf`, `düsseldorf.txt`, or `station_düsseldorf.txt` and
    # they all resolve to `out/station_duesseldorf.txt`.
    #
    # Returns nil if no candidate exists, or if `raw` contains a path
    # separator and the literal path was not found (that signals "user typed
    # an explicit path, don't second-guess it").
    def self.resolve(raw, prefix: nil, extension: nil)
      return raw if File.exist?(raw)
      return nil if raw.include?(File::SEPARATOR)

      stem = raw.dup
      stem = stem[prefix.length..]       if prefix    && stem.start_with?(prefix)
      stem = stem[0...-extension.length] if extension && stem.end_with?(extension)

      stems = [stem]
      slug  = Slug.slugify(stem)
      stems << slug if !slug.empty? && slug != stem

      candidates = stems.flat_map do |s|
        names = [s]
        names << s + extension          if extension
        names << prefix + s             if prefix
        names << prefix + s + extension if prefix && extension
        names
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
