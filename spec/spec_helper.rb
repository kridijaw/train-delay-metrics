$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "train_delay_metrics"
require "duckdb"

# spec/fixtures/*.sql are shared with web/test, which substitutes __OUT__ the same way.
module FixtureHelper
  FIXTURE_DIR = File.expand_path("fixtures", __dir__)

  def write_fixture(name, out_path)
    sql = File.read(File.join(FIXTURE_DIR, "#{name}.sql")).gsub("__OUT__", out_path.gsub("'", "''"))
    DuckDB::Database.new.connect.execute(sql)
  end
end

RSpec.configure do |c|
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.include FixtureHelper
end
