#!/usr/bin/env ruby
require 'experiments'
require 'cloister'

module SqliteHelper
  def insert(dbname, dbtable, record)
    db = Sequel.sqlite(dbname)
   
    # ensure there are fields to hold this record
    tbl = prepare_table(dbtable, record, db)

    tbl.insert(record)
  end
end

class Experiments
  include SqliteHelper

  def initialize(dbpath, dbtable)
    @dbpath = dbpath
    @dbtable = dbtable
    @db = Sequel.new(@dbpath)

    @cmd = "echo Hello world"

    @params = {}

    @slurm = Cloister::Slurm.new

  end

  def run(cmd, params)
    @slurm.run do
      require 'expoo'
      r,w = IO.pipe
      pid = Process.spawn(cmd, [:out,:err]=>w)
      w.close
      pout = ""
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
        insert(@dbname, @dbtable, new_record) unless @opt[:noinsert]
      }
    end
  end
end # class Experiments
