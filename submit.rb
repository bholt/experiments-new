#!/usr/bin/env ruby
require './experiments'
require 'sourcify'
require 'serializable_proc'
require 'tempfile'

def run_in_slurm(flags={}, &blk)
  script_path = "/tmp/test_sourcify.rb"
  script = open(script_path, 'w') # Tempfile.new("experiment")
  script.write(%Q[#!/usr/bin/env ruby
    #{blk.to_source}
  ])
  script.close

  s = `sbatch --nodes=#{flags[:nnode]} --ntasks-per-node=#{flags[:ppn]} --output=#{script_path}.stdout --error=#{script_path}.stderr #{script_path}`
  puts s
end

run_in_slurm({nnode: 2, ppn: 4}) {
  puts ENV['SLURM_JOB_NODELIST']
}

