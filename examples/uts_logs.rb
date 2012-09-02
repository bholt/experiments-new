#!/usr/bin/env ruby
require "experiments"

# example of parsing experiment logs in individual files

db = "data.db"
table = :uts_xmt

num_files = 33
if num_files > 99 then
    raise Error
end

# experiment logs are in numbered files uts.log.01,...,uts.log.<num_files>
cmd = "cat uts.log.%{d}"

params = {
    i: (1..num_files).to_a,
    d: expr('"%02d" % i')
}

#sample output
"""
UTS - Unbalanced Tree Search 2.1 (MTA Futures-Parallel Recursive Search)
Tree type:  1 (Geometric)
Tree shape parameters:
  root branching factor b_0 = 7.0, root seed = 220
Payload: 0
  GEO parameters: gen_mx = 23, shape function = 2 (Cyclic)
Random number generator: SHA-1 (state size = 20B)
Compute granularity: 1
Execution strategy:  MTA Futures-Parallel Recursive Search
  MTA parallel search using 30 teams, 30 max teams, 30 max streams per team

creating tree....
Tree size = 96793510, tree depth = 67, num leaves = 53791152 (55.57%)
Wallclock time = 26.131 sec, performance = 3704188 nodes/sec (123473 nodes/sec per PE)

searching tree once....
Tree size = 96793510, tree depth = 67, num leaves = 53791152 (55.57%)
Wallclock time = 3.331 sec, performance = 29059258 nodes/sec (968642 nodes/sec per PE)

searching tree twice....
Tree size = 96793510, tree depth = 67, num leaves = 53791152 (55.57%)
Wallclock time = 3.313 sec, performance = 29217797 nodes/sec (973927 nodes/sec per PE)
"""

# pick out number of processors, streams, size of tree, and runtimes for tree create, search1, and search2
parser = lambda {|cmdout|
    p cmdout
    /MTA parallel search using (?<num_places>\d+) teams, \d+ max teams, (?<num_threads>\d+) max streams.*\n.*\n.*\nTree size = (?<nNodes>\d+).*\nWallclock time = (?<create_time>\d+\.\d+).*\n.*\n.*\n.*\nWallclock time = (?<search1_runtime>\d+\.\d+).*\n.*\n.*\n.*\nWallclock time = (?<search2_runtime>\d+\.\d+)/.match(cmdout).dictionize
}


run_experiments(cmd, params, db, table, &parser)


