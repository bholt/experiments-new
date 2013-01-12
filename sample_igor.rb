#!/usr/bin/env ruby
require 'igor'

Igor.new do
  database 'sample_igor.db', :test
  cmd      "echo '%{a} %{b} %{c}'"

  # beware: the literal source given will be eval'd to create the parser for each job, no state will be transfered
  parser {|cmdout|
    /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  }

  setup {
    
  }

  params {
    a 1, 2
    b '2', '2', '3'
    c 'abc'
  }

  run { d 4 }
end