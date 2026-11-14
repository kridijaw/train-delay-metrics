require "date"
require "duckdb"

module TrainDelayMetrics
  # Loads the shared sql/*.sql files and expands their {{...}} markers into
  # positional binds. The JS side implements the same syntax; both are checked
  # against spec/shared/sql_template_cases.json.
  module Sql
    SQL_DIR = File.expand_path("../../sql", __dir__)

    SECTION = %r{\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}}m
    MARKER  = /\{\{(\w+)(\*?)\}\}/

    class TemplateError < ArgumentError; end

    module_function

    def load(*names)
      names.flatten.map { |name| File.read(File.join(SQL_DIR, "#{name}.sql")) }.join("\n")
    end

    def expand(text, params)
      params = params.transform_keys(&:to_s)

      sql = text.gsub(SECTION) do
        name, body = Regexp.last_match(1), Regexp.last_match(2)
        raise TemplateError, "nested section inside {{##{name}}}" if body.match?(%r{\{\{[#/]})
        present?(params[name]) ? body : ""
      end
      raise TemplateError, "unbalanced section marker" if sql.match?(%r{\{\{[#/]})

      binds = []
      sql = sql.gsub(MARKER) do
        name, list = Regexp.last_match(1), Regexp.last_match(2) == "*"
        value = params[name]
        if list
          raise TemplateError, "{{#{name}*}} needs a non-empty array" unless value.is_a?(Array) && !value.empty?
          binds.concat(value)
          (["?"] * value.size).join(", ")
        else
          raise TemplateError, "missing param #{name}" if value.nil?
          binds << value
          "?"
        end
      end

      [sql, binds]
    end

    def query(conn, names, params)
      sql, binds = expand(load(*names), params)
      stmt = conn.prepared_statement(sql)
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }
      stmt.execute
    end

    def connect(parquet_glob)
      conn = DuckDB::Database.new.connect
      conn.query("CREATE OR REPLACE TEMP VIEW stop_events AS SELECT * FROM read_parquet('#{parquet_glob.to_s.gsub("'", "''")}')")
      conn
    end

    def cutoff(months_back, today: Date.today)
      return nil if months_back.nil?
      (today << months_back).iso8601
    end

    def present?(value)
      !(value.nil? || (value.is_a?(Array) && value.empty?))
    end
  end
end
