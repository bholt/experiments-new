#!/usr/bin/env ruby
require './expoo.rb'

Experiments.new do
  database 'test_expoo.db', :test
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