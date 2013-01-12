spec = Gem::Specification.new do |s|

    #required info
    s.name = 'igor'
    s.version = '0.1.0'
    s.summary = 'Interactive Gathering Of Results'
    s.files = ['experiments.rb', 'igor.rb', 'igor_trampoline.rb', 'slurm_ffi.rb']

    #dependencies
    # (these are the earliest *tested* versions)
    s.add_dependency('grit', '>= 2.4.1')
    s.add_dependency('awesome_print', '>= 1.0.2')
    s.add_dependency('open4', '>= 1.3.0')
    s.add_dependency('sequel', '>= 3.32.0')
    s.add_dependency('sqlite3', '>= 1.3.5')
    s.add_dependency('sourcify', '>= 0.5.0')
    s.add_dependency('colored')
    s.add_dependency('pry')
    s.add_dependency('ffi')

    s.authors = ['Brandon Holt', 'Brandon Myers']
    s.homepage = "http://github.com/bholt/experiments"
    s.description = "DSL for running experiments over inputs and storing results in a sqlite database."
end
