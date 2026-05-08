$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "train_delay_metrics"

RSpec.configure do |c|
  c.expect_with(:rspec) { |e| e.syntax = :expect }
end
