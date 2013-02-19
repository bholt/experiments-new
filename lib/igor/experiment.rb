require_relative 'util'
require_relative 'batchjob'

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

    @params[:jobid] = ENV['SLURM_JOBID'].to_i
    @params[:outfile] = BatchJob.fout(@params[:jobid])

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
    if not results or (results.size == 0) then puts "Error! No results."; return end

    # box up data into an array (so we can easily handle multiple data records if needed)
    results = [results] if results.is_a? Hash

    results.each {|d|
      new_record = params.merge(d)
      puts new_record # print
      insert(@dbpath, @dbtable, new_record) unless @opt[:noinsert]
    }
    return true # success
  end

  def to_s
    "(#{params}, #{command})"
  end
    
  def pretty_s
    Experiment.color_command(@command, @params)
  end

  def self.color_command(command, params)
    '( '.blue +
    '{ '.red + params.map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red +
    ", " + (command % params).black +
    ' )'.blue
  end

end
