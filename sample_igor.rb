#!/usr/bin/env ruby
require 'igor'

Igor.new do
  database 'sample_igor.db', :test
  cmd      "echo '%{a} %{b} %{c}'"
  parser {|cmdout|
    /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  }

  params {
    a 1, 2
    b '2', '2', '3'
    c 'abc'
  }

  run { d 4 }
end