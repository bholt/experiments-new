require 'experiments'

# monkeypatching
class Hash
  def to_s
    '{ '.red + map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red
  end

  # recursively flatten nested Hashes
  def flat_each(prefix="", &blk)
    each do |k,v|
      if v.is_a?(Hash)
        v.flat_each("#{prefix}#{k}_", &blk)
      else
        yield "#{prefix}#{k}".to_sym, v
      end
    end
  end
end

require 'file-tail'
class File
  include File::Tail
end

class Array
  def all_numbers?
    reduce(true) {|total,v| total &&= v.respond_to? :/ }
  end
end

module Helpers
  module Sqlite
    def insert(dbpath, dbtable, record)
      puts 'inserting...'
      @db ||= Sequel.sqlite(dbpath)
     
      # ensure there are fields to hold this record
      tbl = prepare_table(dbtable, record, @db)

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
