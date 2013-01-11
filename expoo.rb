#!/usr/bin/env ruby
require 'experiments'
require './slurm_ffi'
require 'colored'
require 'pry-debugger'
require 'securerandom'
require 'sourcify'

class Hash
  def to_s
    '{ '.red + map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red
  end
end

module Helpers
  module Sqlite
    def insert(dbpath, dbtable, record)
      db = Sequel.sqlite(dbpath)
     
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

class BatchJob
  attr_reader :jobid, :state, :nodes, :out_file
  def initialize(jobid, out_file)
    @jobid = jobid
    @out_file = out_file
    update()
  end

  def update
    jptr = FFI::MemoryPointer.new :pointer
    Slurm.slurm_load_job(jptr, @jobid, 0)
    jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
    raise "assertion failure" unless jmsg[:record_count] == 1
    sinfo = Slurm::JobInfo.new(jmsg[:job_array])

    @state = sinfo[:job_state]
    @nodes = sinfo[:nodes]
    @start_time = sinfo[:start_time]
    @end_time = sinfo[:end_time]

    Slurm.slurm_free_job_info_msg(jmsg)
  end

  def to_s()
    time = @state == :JOB_COMPLETE ? total_time : elapsed_time
    "#{@jobid}: #{@state} on #{@nodes}, time: #{time}"
  end

  def elapsed_time()
    Time.at(Time.now.tv_sec - @start_time).gmtime.strftime('%R:%S')
  end
  def total_time()   Time.at(@end_time - @start_time).gmtime.strftime('%R:%S') end
  def out()          @out ||= File.open(@out_file, 'r') end
  def tail
    stop_tailing = false
    out.backward(10).tail {|l|
      puts l
      break if stop_tailing
    }
  end
  def cat
    out.seek(0)
    puts out.read
  end
end


class Params < Hash
  include Helpers::DSL
  def initialize(&dsl_code)
    merge!({nnode:1, ppn:1})
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
          :dry_run => false,
          :interactive => false
        }.merge(opt || {})

  require 'optparse'
  parser = OptionParser.new do |p|
    p.banner = "Usage: #{__FILE__} [options]"

    p.on('-f', '--force', 'Force re-runs of experiments even if found in database.') { opt[:force] = true }
    p.on('-n', '--no-insert', "Run experiments, but don't insert results in database.") { opt[:no_insert] = true }
    p.on('-y', '--dry-run', "Don't actually run any experiments. Just print the commands.") { opt[:dry_run] = true }
    p.on('-t', '--[no-]include-tag', "Include tag when deciding to rerun.") {|b| opt[:include_tag] = b }
    p.on('-i', '--interactive', "Enter interactive mode (pry prompt) after initializing.") { opt[:interactive] = true }
  end
  parser.parse!
  opt
end

class Experiment
  include Helpers::Sqlite
  attr_reader :command, :params, :jobid, :serialized_file

  def initialize(params, exps, serialized_file)
    @command = exps.command
    @params = params
    @jobid = nil
    @parser_str = exps.parser.to_source
    @dbpath = exps.dbpath
    @dbtable = exps.dbtable
    @opt = exps.opt
    @serialized_file = serialized_file
  end

  def run()
    require 'open3'
    require 'experiments'
    pid = -1
    pout = ''

    @parser = eval(@parser_str)

    # puts "running..."
    c = @command % @params
    # puts "#{c}\n--------------".black

    Open3.popen2e(c) {|i,oe,waiter|
      pid = waiter.pid
      oe.each_line {|l|
        pout += l
        puts l.strip
      }
      exit_status = waiter.value
      if not exit_status.success? then puts "Error!"; return end
    }
    results = @parser[pout]
    if not results || results.size == 0 then puts "Error! No results."; return end

    # box up data into an array (so we can easily handle multiple data records if needed)
    results = [results] if results.is_a? Hash

    results.each {|d|
      new_record = params.merge(d)
      ap new_record # print
      insert(@dbpath, @dbtable, new_record) unless @opt[:noinsert]
    }
    return true # success
  end

  def to_s
    Experiment.color_command(@command, @params)
  end

  def self.color_command(command, params)
    '( '.blue +
    '{ '.red + params.map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red +
    ", " + (command % params).black +
    ' )'.blue
  end

end

class Experiments
  include Helpers::Sqlite
  include Helpers::DSL

  attr_reader :dbpath, :dbtable, :command, :opt, :parser_file

  def initialize(&dsl_code)
    @dbpath = nil
    @dbtable = nil
    @db = Sequel.sqlite(@dbpath)
    @command = nil
    @params = {}
    @experiments = {}
    @jobs = {}
    @running = Set.new

    # fill 'params' with things like 'tag', 'run_at', etc. that are not usually specified
    @common_info = common_info()

    @opt = parse_cmdline()

    # make sure directory where we'll put things exists
    begin Dir.mkdir(cloister_dir) rescue Errno::EEXIST end

    eval_dsl_code(&dsl_code)

    status

    self.pry if @opt[:interactive]
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
  def job(a) exp(a) end

  # Set command template string
  def cmd(c) @command = c end

  def database(dbpath, dbtable)
    @dbpath = dbpath
    @dbtable = dbtable
  end

  # Run a set of experiments, merging this block's params into @params.
  def run(&blk) enumerate_experiments(Params.new(&blk)) end

  # Parser
  def parser(&blk)
    # getter...
    if !blk then return @parser end

    if blk.arity != 1
      $stderr.puts "Error: invalid parser."
      exit 1
    end

    @parser = blk
  end

  def tail(a)
    begin
      j = @jobs[@job_aliases[a]]
      j.tail
    rescue
      puts "Unable to tail alias: #{a}, job: #{@job_aliases[a]}."
    end
  end
  def view(a)
    begin
      j = @jobs[@job_aliases[a]]
      j.cat
    rescue
      puts "Unable to cat alias: #{a}, job: #{@job_aliases[a]}."
    end
  end

  # END DSL methods
  #################################

  def cloister_dir
    return "#{Dir.pwd}/.cloister"
  end

  def setup_experiment(p)
    d = cloister_dir

    f = "#{d}/cloister.#{Process.pid}.#{SecureRandom.hex(3)}."
    fout = "#{d}/cloister.%j.out"

    e = Experiment.new(p, self, f)

    File.open(f, 'w') {|o| o.write Marshal.dump(e) }

    cmd = "#{File.dirname(__FILE__)}/sbatch.rb '#{f}'"

    s = `sbatch --nodes=#{p[:nnode]} --ntasks-per-node=#{p[:ppn]} #{"--partition=#{p[:partition]}" if p[:partition]} --output=#{fout} --error=#{fout} #{cmd}`

    jobid = s[/Submitted batch job (\d+)/,1].to_i

    @jobs[jobid] = BatchJob.new(jobid, fout.gsub(/%j/,jobid.to_s))
    @running << jobid

    @experiments[jobid] = e
  end

  def enumerate_experiments(override_params)
    params = @params.merge(@common_info).merge(override_params)
    enumerate_exps(params) do |p|
      # c = @command % p
      # e = Experiment.new(c, p)
      print "Experiment".blue; puts Experiment.color_command(@command, p)

      if not @opt[:dry_run] && (not run_already?(@dbtable, p, @db) || @opt[:force])
        # jobid = run_experiment(e)
        setup_experiment(p)
      end
    end
  end

  def status
    @job_aliases = {}
    @running.each do |jobid|
      @jobs[jobid].update
    end
    @jobs.each_with_index {|(id,job),index|
      puts "[#{'%2d'%index}]".cyan + " " + job.to_s
      @job_aliases[index] = id  # so user can refer to an experiment by a shorter number (or alias)
      if @experiments.include? id  # if this job is one of our experiments...
        # print interesting parameters
        p = @experiments[id].params.select{|k,v|
          (!(@params[k] || @common_info[k])) ||
          (@params[k].is_a? Array and @params[k].length > 1)
        }
        puts "     " + p.to_s
      end
      # puts '------------------'.black
    }
    return
  end
end # class Experiments
