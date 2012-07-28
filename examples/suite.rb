#!/usr/bin/env ruby
require "experiments"

db = "#{ENV['HOME']}/exp/grappa-new.db"
table = :suite

# select between running on XMT or SoftXMT by if it's on cougar
hostname = `hostname`
if hostname.match /cougar/ then
  cmd = "mtarun -m %{nproc} suite.exe -s %{scale} -p --centrality --kcent=%{kcent}"
  machinename = "cougarxmt"
else
  # command that will be excuted on the command line, with variables in %{} substituted
  cmd = %Q[ make -j mpi_run TARGET=suite.exe NNODE=%{nnode} PPN=%{ppn}
    SRUN_RESERVE='--time=30:00 --exclude=node0196'
    GARGS='
      --aggregator_autoflush_ticks=%{flushticks}
      --periodic_poll_ticks=%{pollticks}
      --num_starting_workers=%{nworkers}
      --chunk_size=%{chunksize}
      --async_par_for_threshold=%{threshold}
      --global_memory_use_hugepages=%{hugepages}
      --v=1
      -- -s %{scale} -p --centrality --kcent=%{kcent}
    '
  ].gsub(/[\n\r\ ]+/," ")
  machinename = "sampa"
  machinename = "pal" if hostname.match /pal/
end

# map of parameters; key is the name used in command substitution
params = {
  scale: [27],
  nnode: [128],
  nworkers: [10000],
  ppn: [5],
  flushticks: [4000000],
  pollticks: [20000],
  chunksize: [64],
  threshold: [64],
  kcent: [4],
  nproc: expr('nnode*ppn'),
  machine: [machinename],
  hugepages: [1]
}

def inc_avg(avg, count, val)
  return avg + (val-avg)/count
end

# Block that takes the stdout of the shell command and parses it into a Hash
# which will be incorporated into the record inserted into the database.
# If multiple records are desired, an array of Hashes can be returned as well.
# Note: the 'dictionize' method used here is defined by the 'experiments' library 
# and turns the output of named capture groups into a suitable Hash return value.
parser = lambda {|cmdout|
  # /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  h = {}
  c = Hash.new(0)
  cmdout.each_line do |line|
    m = line.chomp.match(/(?<key>[\w_]+):\ (?<value>#{REG_NUM})$/)
    if m then
      h[m[:key].downcase.to_sym] = m[:value].to_f
    else
      # match statistics
      m = line.chomp.match(/(?<obj>[\w_]+)\ +(?<data>{.*})/m)
      if m then
        obj = m[:obj]
        data = eval(m[:data])
        # puts "#{ap obj}: #{ap data}"
        # sum the fields
        h.merge!(data) {|key,v1,v2| v1+v2 }
      end
    end
  end
  if h.keys.length == 0 then
    puts "Error: didn't find any fields."
  end
  h
}

# function that runs all the experiments
# (note: instead of passing a lambda, an explicit block can be used as well)
# this command also parses the following command-line options if passed to this script:
#  -f,--force      forces experiments to be re-run even if their parameters appear in DB
#  -n,--no-insert  suppresses insertion of records into database
run_experiments(cmd, params, db, table, &parser)
