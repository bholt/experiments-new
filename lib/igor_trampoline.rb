#!/usr/bin/env ruby
require 'igor'
e = Marshal.load(File.binread(ARGV[0]))
puts "#{e}"
success = e.run
File.delete(e.serialized_file) if success
