#!/usr/bin/env ruby
# args: <path to marshal dump, e.g.:.cloister/cloister.*.out>
require 'cloister'
require 'colored'
# Marshal.load(File.binread(ARGV[0]).unpack('m')[0]).call(binding)
e = Marshal.load(File.binread(ARGV[0]))
puts "#{e}" + "\n---------------".black
success = e.run
File.delete(@serialized_file) if success