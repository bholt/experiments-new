#!/usr/bin/env ruby
require "grit"
require "sequel"
require "open4"
require "awesome_print"

def DIR
  File.dirname(__FILE__)
end

def find_up_path(filename)
  fs = []
  p = Dir.pwd
  while p.length > 0 do
    if Dir.entries(p).include?(filename) then 
      fs << p+'/'+filename
    end
   i = p.rindex('/')
    if i == 0 then
      p = ""
    else
      p = p[0..i-1]
    end
  end
  return fs
end

def run(cmd)
  cmd += " 2>&1"
  cmdout = ""
  cmderr = ""
  status = Open4::popen4(cmd) do |pid, stdin, stdout, stderr|
    Signal.trap("INT") { Process.kill("INT", pid) }
    stdout.each_line{|l| puts l; cmdout += l }
  end
  if ($opt_err_fatal && cmderr.length > 0) || not(status.success?) then
    puts "error! #{status}\n### stdout ###\n#{cmdout}\n### stderr ###\n#{cmderr}"
    return nil
  else
    return cmdout + cmderr
  end
end

# return sha of the most recent commit (string)
def current_commit()
  gitpaths = find_up_path(".git")
  return nil if gitpaths.length == 0
  $repo = Grit::Repo.new(gitpaths[0]) if $repo == nil
  return $repo.commits("HEAD").first.sha
end

def current_tag()
  gitpaths = find_up_path(".git")
  return nil if gitpaths.length == 0
  $repo = Grit::Repo.new(gitpaths[0]) if $repo == nil
  return $repo.recent_tag_name
end  

# return dict with info that should be included in every experiment record
def common_info()
  {
    :commit => current_commit(),
    :run_at => Time.now.to_s,
    :tag => current_tag()
  }
end

# parses command line options
# TODO: make this extensible so that scripts can add their own options easily
$opt_called = false

def parse_cmdline_options()
  return if $opt_called # only call once...
  
  $opt_called = true
  require "optparse"
  optparse = OptionParser.new do |opts|
    opts.banner = "Ruby Experiment"
    $opt_force = false
    opts.on('-f', '--force', "Force re-runs of experiments even if they are found in DB") { $opt_force = true }
    $opt_noinsert = false
    opts.on('-n', '--no-insert', "Don't insert results into database") { $opt_noinsert = true }
    $opt_clean = false
    opts.on('-c', '--clean', "Clean database table (drop all its records)") { $opt_clean = true }
    $opt_err_fatal = false
    opts.on('-e', '--err-fatal', "Output on stderr assumed fatal") { $opt_err_fatal = true }
    $opt_as_csv = false
    $opt_csvfn = nil
    opts.on('-s', '--csv FNAME', "Output csv to FNAME") do |fname|
        ap fname
         $opt_as_csv = true
         $opt_csvfn = fname
    end
    $opt_rerun_on_diff = false
    opts.on('-D', '--rerun-diff', "Rerun experiments where commit is different") { $opt_rerun_on_diff = true }
    $opt_include_tag = false
    opts.on('-t', '--include-tag', "Include tag when deciding to rerun.") { $opt_include_tag = true }
    $opt_dry_run = false
    opts.on('-y', '--dry-run', "Don't actually run any experiments. Just print the commands") { $opt_dry_run = true }
   
    yield opts if block_given?
  end
  optparse.parse!
end

# queries database to see if any match the given dict of run parameters
def run_already?(table, params, db = Sequel.sqlite($exp_db))
  # make sure all fields in params are existing columns, then query database
  return db.table_exists?(table) \
      && (params.keys - db[table].columns).empty? \
      && db[table].filter(params).count > 0
end

# create a fresh binding object (for use in enumerate_exps)
def new_binding; binding; end

#
# Calculate the number of experiments based
# on total number of values per key
#
def number_of_exps(d)
    product = 1
    d.each { |k,v|
        if not v.respond_to? :each then
          v = [v]
        end
       product *= v.length 
    }
    product
end

# iterator that takes a dict of variables and enumerates all possible combinations
# yields: dict of experiment parameters
def enumerate_exps(d, keys=d.keys, upb=new_binding())
  if keys.empty? then
    h = {}
    yield h
  else
    k,*rest = *keys
    vals = d[k]
    # puts "#{k.inspect} -- #{d.inspect}"
    if not vals.respond_to? :each then
      vals = [vals]
    end
    
    vals.each {|v|
      if v.is_a?(ExpressionString) || !v.is_a?(String) then
        # evaluate as an expression (and give an error if it doesn't evaluate correctly)
        begin
          eval("#{k} = #{v}", upb)
        rescue TypeError, NameError
          puts "#{v}: #{k} is not available!"
          exit()
        end
      else
        eval("#{k} = '#{v}'", upb) # eval as a string literal instead of an expression
      end
      enumerate_exps(d, rest, upb) { |result|
        if v.is_a? ExpressionString then
          v = eval("#{v}", upb) if v.is_a? String
        end
        yield ({k => v}.merge(result))
      }
    }
  end
end

# create table if it doesn't exist, add any columns in new record that don't exist in table
def prepare_table(table, new_record, db = Sequel.sqlite($exp_db))
  # create table if it doesn't already exist
  db.create_table?(table) { primary_key :id }
  

  # check each column exists and add it if it doesn't
  new_record.each_pair do |k,v|
    if not db[table].columns.include? k then
      # remove any nil values
      if (v == nil) then
        puts "Warning: can't create column (#{k}) from 'nil' value, ignoring."
        new_record.delete(k)
        next
      end
      db.add_column(table, k, v.class)
    end
  end
  
  return db[table]
end

# # I'm not convinced that we need to expose the ability to run a single experiment
# def run_experiment(cmd, &parser)
#   
# end

def clean(db, table)
  db = Sequel.sqlite($exp_db)
  if db.table_exists?(table) then
    # db[table].delete
	db.drop_table table
  end  
end

#
# Converts dictionary to csv formatted string
#
def dict_to_csv(d)
  #create column list
  columns_sorted = d.keys().sort

  #list of names
  title_str = columns_sorted.join(", ") + ","

  data_str = ""

  #data
  columns_sorted.each { |c|
    data_str += "%s, " % d[c]
  }

  [title_str,data_str]
end

#
# Writes a row to an open csv file
#
def csv_write_row(openfile, record, writeHeader)
  csvt,csvd = dict_to_csv(record)
  if writeHeader then 
    openfile.write("\n---new---\n")
    openfile.write(csvt)
    openfile.write("\n") 
  end
  openfile.write(csvd)
  openfile.write("\n")
end

# enumerate and run all experiments dictated by command and set of parameters
# insert into table if specified (table should be a symbol)
def run_experiments(cmd_template, dict, dbfile, table, &parse)
  $exp_db = dbfile
  parse_cmdline_options()
  if $opt_clean then
    clean($exp_db, table)
    exit()
  end
  
  info = common_info()
 
  total_num_exps = number_of_exps(dict)
  current_exp_num = 0 
  csvfirst = true

  db = Sequel.sqlite($exp_db)

  enumerate_exps(dict) do |params|
    current_exp_num+=1
    puts "------"
    puts "experiment: #{current_exp_num} / #{total_num_exps} (#{Time.now})"
    check_rows = params
    if $opt_rerun_on_diff then check_rows=check_rows.merge({commit: info[:commit]}) end
    if $opt_include_tag then check_rows=check_rows.merge({tag: info[:tag]}) end
    if !$opt_force && !$opt_as_csv && run_already?(table, check_rows, db)
      print "skipping... "
      ap params, {multiline:false}
      next
    end
    # otherwise, execute and insert
    cmd = cmd_template % params # substitute params into template
    puts cmd # verbose
    
    # don't execute if dry-run
    if $opt_dry_run then next end
   
    # execute 
    cout = run(cmd)
    if cout == nil
         # if there was an error, try next experiment
         print "error!"
        next
    end

    datas = parse.call(cout) # get dict (or array of dicts) of data from user-specified parser
    if (datas.length == 0) then
      puts "no data found, must have been an error!"
      next
    end

    # box up data into an array (so we can easily handle multiple data records if needed)
    datas = [datas] if datas.is_a? Hash
   
    datas.each do |data|
      new_record = params.merge(info).merge(data)
      ap new_record
      if not $opt_noinsert then    
        if $opt_as_csv then 
            File.open($opt_csvfn, "a") do |csvfile|
                csv_write_row(csvfile, new_record, csvfirst)
                csvfirst = false
            end
        else
            # create table and columns if necessary
            t = prepare_table(table, new_record, db)
            t.insert(new_record)
        end
      end
    end
  end
end

# Regex utility stuff
REG_NUM = "[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?" # number (handles scientific notation)
REG_HASH = "{.*}"

class MatchData
  def dictionize
    h = {}
    names .zip captures do |name, cap|
      if cap then
        h[name.to_sym] = cap.match(REG_NUM) ? cap.to_f : cap
      end
    end
    return h
  end
end

class ExpressionString < String
end

def expr(*exprs)
  return exprs.map {|s| ExpressionString.new(s) }
end

