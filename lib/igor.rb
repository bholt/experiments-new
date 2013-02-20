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

  attr_reader :dbpath, :dbtable, :opt, :parser_file

  @dbpath = nil
  @dbtable = nil
  @command = nil
  @params = {}
  @experiments = {}
  @jobs = {}
  @interesting = Set.new

  def dsl(&dsl_code)
    @opt = parse_cmdline()
    
    # fill 'params' with things like 'tag', 'run_at', etc. that are not usually specified
    @common_info = common_info()

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
  # Also takes a hash of options that replace the global @opt for this set of runs
  def run(opts={},&blk)
    if opts.size > 0
      saved_opts = @opt.clone
      @opt.merge!(opts)
    end
    
    p = Params.new(&blk)
    @interesting += p.keys   # any key in a 'run' is interesting enough to be displayed
    enumerate_experiments(p)
    status
    
    @opt = saved_opts if saved_opts  # restore
    return  # no return value
  end
  
  # shortcut to call `run` with :force => true.
  def run_forced(opts={},&blk)
    run(opts.merge({force:true}), &blk)
  end

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
    # View output from batch job. Interprets a number as a job alias and looks it up,
    # interprets a String as the path of the output file itself.
    
    if a.is_a? Integer
      j = @jobs[@job_aliases[a]]
      j.cat
    elsif a.is_a? String
      File.open(a,'r') {|f| puts f.read }
    end
  end
  alias :v :view
  
  def attach(job_alias)
    
    j = @jobs[@job_aliases[job_alias]]
    j.update
    
    if j.state == :JOB_PENDING
      puts "job pending..."
      Signal.scoped_trap("INT", ->{ raise }) {
        begin
          sleep 0.1 and j.update while j.state == :JOB_PENDING
        rescue # catch ctrl-c safely, will return below
        end
      }
      return if j.state == :JOB_PENDING
    end
    
    begin
      sleep 0.5 # give squeue time to get itself together
      job_with_step = %x{ squeue --jobs=#{j.jobid} --steps --format %i }.split[1]
    end while j.state == :JOB_RUNNING && (job_with_step == nil)
    
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
  alias :a :attach
  alias :at :attach

  def status    
    @job_aliases = {}
    update_jobs
    @jobs.each_with_index {|(id,job),index|
      puts "[#{'%2d'%index}]".cyan + " " + job.to_s
      @job_aliases[index] = id  # so user can refer to an experiment by a shorter number (or alias)
      if @experiments.include? id  # if this job is one of our experiments...
        # print interesting parameters
        p = @experiments[id].params.select{|k,v|
          not(@params[k] || @common_info[k] || k == :command) ||
          (@params[k].is_a? Array and @params[k].length > 1) ||
          (@interesting.include? k)
        }
        puts "     " + p.pretty_s
      end
      # puts '------------------'.black
    }
    return 'status'
  end
  alias :st :status

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

  # ----- Deprecated -----  
  def print_results(&blk)
    # print results (records in database), optionally takes a block to specify a custom query
    # 
    # usage:
    #   results {|t| t.select(:field).where{value > 100}.order(:run_at) }
    #
    # default (without block) does:
    #   results {|t| t.reverse_order(:run_at) }
    
    if blk
      d = yield @db[@dbtable]
    else
      d = @db[@dbtable].order(:run_at)
    end
    puts Hirb::Helpers::AutoTable.render(d.all) # (doesn't do automatic paging...)
  end
  
  # Get new handle for a dataset from the results database.
  # This handle is actually a `Sequel::Model`, which means it has lots of useful little things
  # you can do with it.
  # 
  # Example usage:
  # print all results:
  # > results.all
  # get field value from result with given id:
  # > results[12].nnode
  # 
  def results(&blk)
    if blk
      # same as DSL eval: if they want a handle, give it to 'em
      if blk.arity == 1
        d = yield @db[@dbtable]
      else # otherwise just evaluate directly on the dataset (implicit 'self')
        d = @db[@dbtable].instance_eval(&blk)
      end
    else
      d = @db[@dbtable]
    end
    return Class.new(Sequel::Model) { set_dataset d }
  end

  # doesn't currently work ('create_or_replace_view' unsupported for SQLite, or Sequel bug?)
  # def results_filter(dataset=nil,&blk)
  #   if blk
  #     dataset = yield @db[@dbtable]
  #   end
  #   if dataset || blk
  #     @db.create_or_replace_view(:temp, dataset)
  #   end
  #   return results{|t| t.from(:temp)}
  # end
  
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
      p[:command] = @command % p  # make sure substitution goes already, use in run_already? check
      
      if (not @opt[:dry_run]) && ((not run_already?(p)) || @opt[:force])
        setup_experiment(p)
      else
        print "<skipped> ".red
      end
      
      print "Experiment".blue; puts Experiment.color_command(@command, p)      
    end
  end

end # module Igor

def Igor(&blk)
  Igor.dsl(&blk)
end

# Hirb (for better table output)
begin
  require 'pry'
  require 'hirb'
  Hirb.enable
  old_print = Pry.config.print
  Pry.config.print = proc do |output, value|
    Hirb::View.view_or_page_output(value) || old_print.call(output, value)
  end
rescue LoadError
  # Hirb is just bonus anyway...
end
