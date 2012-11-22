#!/usr/bin/env ruby
require 'experiments'
require 'cloister'
require 'colored'
require 'pry'

module Helpers
  module Sqlite
    def insert(dbname, dbtable, record)
      db = Sequel.sqlite(dbname)
     
      # ensure there are fields to hold this record
      tbl = prepare_table(dbtable, record, db)

      tbl.insert(record)
    end
  end

  module DSL

    def eval_dsl_code(&dsl_code)
      # do an arity check so users of the DSL can leave off the object parameter:
      #   ExampleDSL.new { example_call }
      # or if they want to be more explicit:
      #   ExampleDSL.new {|e| e.example_call }
      if dsl_code.arity == 1      # the arity() check
        dsl_code[self]            # argument expected, pass the object
      else
        instance_eval(&dsl_code)  # no argument, use instance_eval()
      end
    end

  end
end

class Params < Hash
  include Helpers::DSL
  def initialize(&dsl_code)
    eval_dsl_code(&dsl_code) if dsl_code
  end
  # Arbitrary method calls create new entries in Hash
  # Enables DSL syntax:
  #   Params.new { nnode 4; ppn 1, 2 }
  def method_missing(selector, *args, &blk)
    self[selector.downcase.to_sym] = args
  end
end

def parse_cmdline(opt=nil)
  opt = { :force => false,
          :no_insert => false,
          :include_tag => true,
          :dry_run => false
        }.merge(opt || {})

  require 'optparse'
  parser = OptionParser.new do |p|
    p.banner = "Usage: #{__FILE__} [options]"

    p.on('-f', '--force', 'Force re-runs of experiments even if found in database.') { opt[:force] = true }
    p.on('-n', '--no-insert', "Run experiments, but don't insert results in database.") { opt[:no_insert] = true }
    p.on('-y', '--dry-run', "Don't actually run any experiments. Just print the commands.") { opt[:dry_run] = true }
    p.on('-t', '--[no-]include-tag', "Include tag when deciding to rerun.") {|b| opt[:include_tag] = b }
  end
  parser.parse!
  opt
end

class Experiments
  include Helpers::Sqlite
  include Helpers::DSL

  def initialize(dbpath, dbtable, &dsl_code)
    @dbpath = dbpath
    @dbtable = dbtable
    @db = Sequel.sqlite(@dbpath)
    @cmd = nil
    @slurm = Cloister::Slurm.new
    @params = {}

    # fill 'params' with things like 'tag', 'run_at', etc. that are not usually specified
    @params.merge!(common_info())

    @opt = parse_cmdline()

    eval_dsl_code(&dsl_code)
  end

  #################################
  # Methods intended for DSL usage:

  # all calls to 'params' append to existing params, overwriting if needed
  # should allow for imperative-style experiments:
  #   params { scale 16; nnode 4 }
  #   run    # runs with {scale:16, nnode:4}
  #   params { scale 25 }
  #   run    # runs with {scale:25, nnode:4}
  def params(&blk) @params.merge!(Params.new(&blk)) end

  # Allow looking up experiments with aliases (currently just index in experiments array)
  def exp(a) @experiments[@job_aliases[a]] end

  # Set command template string
  def cmd(c) @cmd = c end

  # Run a set of experiments, merging this block's params into @params.
  def run(&blk) enumerate_experiments(Params.new(&blk)) end

  # Parser
  def parser(&blk)
    if blk.arity != 1
      $stderr.puts "Error: invalid parser."
      exit 1
    end
    @parser = blk
  end

  # END DSL methods
  #################################

  def enumerate_experiments(override_params)
    params = @params.merge(override_params)
    enumerate_exps(params) do |p|
      c = @cmd % p
      print "Created experiment: ".green; ap p
      puts "  " + c.black

      if not @opt[:dry_run]
        if (not run_already?(@dbtable, p, @db) || @opt[:force])
          run_experiment(c, p)
        end
      end
    end
  end

  def run_experiment(cmd, params)
    jobid = @slurm.run(params) {
      @@_not_isolated_vars = :global
      require 'expoo'
      r,w = IO.pipe
      pid = Process.spawn(cmd, [:out,:err]=>w)
      w.close
      pout = ''
      r.each_line {|l|
        pout += l
        puts l.strip
      }
      Process.wait(pid)
      if not $?.success? then puts "Error!"; return end

      results = @parser[pout]
      if not results || results.size == 0 then puts "Error! No results."; return end

      # box up data into an array (so we can easily handle multiple data records if needed)
      results = [results] if results.is_a? Hash

      results.each {|d|
        new_record = params.merge(d)
        ap new_record # print
        Sqlite.insert(@dbname, @dbtable, new_record) unless @opt[:noinsert]
      }
    }
    @experiments[jobid] = params
  end

  def status
    @job_aliases = []
    @slurm.jobs.each_with_index {|(id,job),index|
      puts "[#{'%2d'%index}]".blue + " " + job.to_s
      @job_aliases << id  # so user can refer to an experiment by a shorter number (or alias)
      if @experiments.include? id  # if this job is one of our experiments...
        # display what job it is...
        print '    '; ap @experiments[id]
      end
    }
  end
end # class Experiments
