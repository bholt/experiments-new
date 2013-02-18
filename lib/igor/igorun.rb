#!/usr/bin/env ruby
require 'igor/experiment'
e = Marshal.load(File.binread(ARGV[0]))
# puts "#{e}"
puts e.command
puts e.params
success = e.run
File.delete(e.serialized_file) if success
