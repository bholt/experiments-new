#!/usr/bin/env ruby
require 'colored'
require 'securerandom'
require 'sourcify'
require 'pry'
require 'pty'

require_relative 'experiments'
require_relative 'igor/slurm_ffi'
require_relative 'igor/experiment'
require_relative 'igor/batchjob'
require_relative 'igor/util'

class Params < Hash
  include Helpers::DSL
  
  def initialize(&dsl_code)
    eval_dsl_code(&dsl_code) if dsl_code
  end
  
  # Arbitrary method calls create new entries in Hash
  # Enables DSL syntax:
  #   Params.new { nnode(4); ppn(1, 2) }
  # or even simpler...
  #   Params.new { nnode 4; ppn 1, 2 }
  #
  # TODO: fix problem with collisions (i.e. 'partition' is already a method)
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

module Igor
  extend self # this is probably a really terrible thing to do

  extend Helpers::Sqlite
  extend Helpers::DSL
  
  module Console
    extend Hirb::Console
  end

  attr_reader :dbpath, :dbtable, :opt, :parser_file

  @dbpath = nil
  @dbtable = nil
  @command = nil
  @params = {}
  @experiments = {}
  @jobs = {}

  def dsl(&dsl_code)

    # fill 'params' with things like 'tag', 'run_at', etc. that are not usually specified
    @common_info = common_info()

    @opt = parse_cmdline()

    # make sure directory where we'll put things exists
    begin Dir.mkdir(igor_dir) rescue Errno::EEXIST end

    eval_dsl_code(&dsl_code)

    status

    # self.pry if @opt[:interactive]
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
  def command(c=nil)
    @command = c if c
    return @command
  end
  alias :cmd :command

  def database(dbpath, dbtable)
    @dbpath = File.expand_path(dbpath)
    @dbtable = dbtable
    @db = Sequel.sqlite(@dbpath)
  end
  alias :db :database

  # Run a set of experiments, merging this block's params into @params.
  def run(&blk) enumerate_experiments(Params.new(&blk)); status end

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

  # Parser
  def setup(&blk) @setup = blk end
    
  def sbatch_flags(flags) @sbatch_flags = flags end

  # END DSL methods
  #################################

  ######################
  # Interactive methods
  
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
    return j.out_file
  end
  
  def attach(job_alias)
    alias :a :attach
    alias :at :attach
    
    j = @jobs[@job_aliases[job_alias]]
    j.update
    
    if j.state == :JOB_PENDING
      puts "job pending..."
      Signal.scoped_trap("INT", ->{ raise }) {
        begin
          sleep 0.1 and j.update while j.state == :JOB_PENDING
        rescue
        end
      }
    end
    
    job_with_step = %x{ squeue --jobs=#{j.jobid} --steps --format %i }.split[1]
    if not job_with_step
      puts "Job step not found, might have finished already. Try `view #{job_alias}`"
      return
    end
    
    PTY.spawn "sattach #{job_with_step}" do |r,w,pid|
      Signal.trap("INT") { puts "exiting..."; Process.kill("INT",pid) }
      begin
        r.sync
        r.each_line {|l| puts l.strip }
      rescue Errno::EIO => e
        # *correct* behavior is to emit an I/O error here, so ignore
      ensure
        ::Process.wait pid
        Signal.trap("INT", "DEFAULT") # reset signal
      end
    end
  end

  def status
    alias :st :status
    
    @job_aliases = {}
    update_jobs
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
    return 'status'
  end

  # shortcut to provide the pry command-line to debug a remote process
  # usage looks something like: pry(#<Igor>)> .#{gdb 'n01', '11956'}
  # (pry sends commands starting with '.' to the shell, but allows string interpolation)
  def gdb(node, pid)
    return "ssh #{node} -t gdb attach #{pid}"
  end
  
  def interact
    status
    self.pry
  end
  
  # display results (records in database), optionally takes a block to specify a custom query
  # 
  # usage:
  #   results {|t| t.select(:field).where{value > 100}.order(:run_at) }
  #
  # default (without block) does:
  #   results {|t| t.reverse_order(:run_at) }
  def results(&blk)
    if blk
      d = yield @db[@dbtable]
    else
      d = @db[@dbtable].order(:run_at)
    end
    puts Hirb::Helpers::AutoTable.render(d.all) # (doesn't do automatic paging...)
  end
  
  # Interactive methods
  ##########################

  def update_jobs
    jptr = FFI::MemoryPointer.new :pointer
    Slurm.slurm_load_jobs(0, jptr, 0)
    raise "unable to update jobs, slurm returned NULL" if jptr.get_pointer(0) == FFI::Pointer::NULL
    jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
    
    @jobs = {}
    
    (0...jmsg[:record_count]).each do |i|
      sinfo = Slurm::JobInfo.new(jmsg[:job_array]+i*Slurm::JobInfo.size)
      if sinfo[:user_id] == Process.uid
        jobid = sinfo[:job_id]
        @jobs[jobid] = BatchJob.new(jobid,sinfo)
      end
    end

    Slurm.slurm_free_job_info_msg(jmsg)
  end

  def igor_dir
    return "#{Dir.pwd}/.igor"
  end

  def setup_experiment(p)
    d = igor_dir

    f = "#{d}/igor.#{Process.pid}.#{SecureRandom.hex(3)}.bin"
    fout = BatchJob.fout

    e = Experiment.new(p, self, f)

    File.open(f, 'w') {|o| o.write Marshal.dump(e) }

    cmd = "#{File.dirname(__FILE__)}/igor/igorun.rb '#{f}'"

    # make sure the allocation has at least 1 process
    p[:nnode] = 1 unless p[:nnode]
    p[:ppn] = 1 unless p[:ppn]

    puts "sbatch --nodes=#{p[:nnode]} --ntasks-per-node=#{p[:ppn]} #{@sbatch_flags} --output=#{fout} --error=#{fout} #{cmd}"

    s = `sbatch --nodes=#{p[:nnode]} --ntasks-per-node=#{p[:ppn]} #{@sbatch_flags} --output=#{fout} --error=#{fout} #{cmd}`

    jobid = s[/Submitted batch job (\d+)/,1].to_i

    @jobs[jobid] = BatchJob.new(jobid)
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

end # module Igor

def Igor(&blk)
  Igor.dsl(&blk)
end
