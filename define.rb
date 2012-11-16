#!/usr/bin/env ruby
require 'experiments'
#require 'docile'

class Params < Hash
  def initialize(&dsl_code)     # creates the Proc
    return self if not dsl_code

    if dsl_code.arity == 1      # the arity() check
      dsl_code[self]            # argument expected, pass the object
    else
      instance_eval(&dsl_code)  # no argument, use instance_eval()
    end
    self
  end
  def method_missing(selector, *args, &blk)
    self[selector.downcase.to_sym] = args
  end
  def enumerate()
    puts "enumerating... #{self}"
  end
end

class Builder
  def initialize(&dsl_code)     # creates the Proc
    @experiments = []
    @params = Params.new
    if dsl_code.arity == 1      # the arity() check
      dsl_code[self]            # argument expected, pass the object
    else
      instance_eval(&dsl_code)  # no argument, use instance_eval()
    end
    self
  end
  def params(&blk)
    @params.merge!(Params.new(&blk))
  end
  def cmd(str)
    @cmd = str
  end
  def run(&blk)
    p = Params.new(&blk)
    puts "p = #{p}"
    p = @params.merge(p)
    if not @cmd then
      $stderr.puts 'missing statement: cmd "<command to execute here>"'
      return
    end

    enumerate_exps(p) do |e|
      puts "running... #{@cmd % e}"
      @experiments << e
    end
  end
  #def method_missing(selector, *args, &blk)
    #@params.method(selector).call(*args)
  #end
  def database(dbpath, dbtable)
    @dbpath = dbpath
    @dbtable = dbtable
  end
end

#def experiments(&blk)
  #Docile.dsl_eval(ExperimentBuilder.new, &blk)
#end

$e = Builder.new do
  params {
    scale 26
    nnode 16, 32
  }

  cmd "echo %{scale} %{nnode}"

  run { scale 23; puts "ran #{self}" }
  
  # generate cartesian product
  run {
    nworkers 1024, 2048, 4096
    ppn 4
  }
  
  # zip iter
  zip {
    a 1, 2, 3
    b 2, 4, 8
  }
  
end

# generate GLOG parameters from name, construct

# make a bunch of combinators for doing cartesian products and zip products of parameters, etc.

puts $e.inspect



# more ideas
Experiments do
  database "~/exp/grappa.db", :graph500
  
  { scale: [23, 24] } | { ppn: [2, 3] }  

# or ----------------------------------------
  params {
    ncores{nnode*ppn}
  }

  run {
    ( scale(23,24) | ppn(2,3) ) * bfs("bfs_beamer") * nworker(1024)
  }

  run {
    # something like...
    scale,ppn = (23,2), (24,3)
  }
end


