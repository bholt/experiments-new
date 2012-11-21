#!/usr/bin/env ruby
require './expoo.rb'

Experiments.new('test.db', :test) do
  # command that will be excuted on the command line, with variables in %{} substituted
  cmd "echo '%{a} %{b} %{c}'"
  
  # Block that takes the stdout of the shell command and parses it into a Hash
  # which will be incorporated into the record inserted into the database.
  # If multiple records are desired, an array of Hashes can be returned as well.
  # Note: the 'dictionize' method used here is defined by the 'experiments' library 
  # and turns the output of named capture groups into a suitable Hash return value.
  parser {|cmdout|
    /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  }

  # map of parameters; key is the name used in command substitution
  params {
    a 1, 2
    b 2, 4
    c 'foo'
  }

  run

  run { a 4; b 2 }
end
