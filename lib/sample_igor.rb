#!/usr/bin/env ruby
require 'igor'

exe = 'graph.exe'

Igor do
  database 'sample_igor.db', :test
  # command  "echo '%{a} %{b} %{c}'"
  command "srun #{File.dirname(__FILE__)}/../examples/slow_loop.sh"
  
  sbatch_flags "--time=30:00 #{
      (`hostname` =~ /pal/) \
        ? '--account=pal --partition=pal' \
        : '--partition=grappa'
      }"

  # this would be interesting, and should be possible
  # command {
  #   `sbcast stuff`
  #   `mpirun echo #{@a} #{@b} #{@c}`
  # }

  # beware: the literal source given will be eval'd to create the parser for each job, no state will be transfered
  parser {|cmdout|
    /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  }

  params {
    a 1, 2
    b '1', '2', '3'
    c 'abc'
    # e ->{@a*2}, ->{@a*4} # pass lambdas to do expression params
  }

  run { d 4; tag 'sample_tag' } # tag a set of runs as being part of a logical set 

end
