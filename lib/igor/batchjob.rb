require_relative 'slurm_ffi'
require_relative 'util'
require 'file-tail'

module JobOutput
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

class BatchJob
  attr_reader :jobid, :state, :nodes, :out_file
  def initialize(jobid,slurm_info=nil)
    @jobid = jobid
    @out_file = BatchJob.fout(jobid)
    update(slurm_info) if slurm_info
  end
  
  def self.fout(jobid=nil)
    s = "#{Igor.igor_dir}/igor.%j.out"
    s.gsub!(/%j/, jobid.to_s) if jobid
    return s
  end

  def update(sinfo=nil)
    jmsg = nil
    if not sinfo
      jptr = FFI::MemoryPointer.new :pointer
      Slurm.slurm_load_job(jptr, @jobid, 0)
      jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
      raise "assertion failure" unless jmsg[:record_count] == 1
      sinfo = Slurm::JobInfo.new(jmsg[:job_array])
    end
    
    @state = sinfo[:job_state]
    @nodes = sinfo[:nodes]
    @start_time = sinfo[:start_time]
    @end_time = sinfo[:end_time]

    Slurm.slurm_free_job_info_msg(jmsg) if jmsg
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
  
  include JobOutput
end
