
Gem::Specification.new do |gem|

    #required info
    gem.name = 'igor'
    gem.version = '0.1.1'
    gem.summary = 'Interactive Gathering Of Results'

    # gem.files = ['experiments.rb', 'igor.rb', 'igor_trampoline.rb', 'slurm_ffi.rb']
    gem.files = `git ls-files`.split($/)

    #dependencies
    # (these are the earliest *tested* versions)
    gem.add_dependency('grit', '>= 2.4.1')
    gem.add_dependency('awesome_print', '>= 1.0.2')
    gem.add_dependency('open4', '>= 1.3.0')
    gem.add_dependency('sequel', '>= 3.32.0')
    gem.add_dependency('sqlite3', '>= 1.3.5')
    gem.add_dependency('sourcify', '>= 0.6.0.rc1')
    gem.add_dependency('colored')
    gem.add_dependency('pry')
    gem.add_dependency('ffi')
    gem.add_dependency('file-tail')
    gem.add_dependency('hirb') # optional, but makes pretty tables...

    gem.authors = ['Brandon Holt', 'Brandon Myers']
    gem.email   = ['bholt@cs.washington.edu', 'bdmyers@cs.washington.edu']

    gem.homepage = "http://github.com/bholt/experiments"
    gem.description = "DSL for running experiments over inputs and storing results in a sqlite database."
end
