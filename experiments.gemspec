spec = Gem::Specification.new do |s|

    #required info
    s.name = 'experiments'
    s.version = '0.1.0'
    s.summary = 'Runs experiments and outputs to sqlite db.'
    s.files = ['experiments.rb']

    #dependencies
    # (these are the earliest *tested* versions)
    s.add_dependency('grit', '>= 2.4.1')
    s.add_dependency('crack', '>= 0.3.1')
    s.add_dependency('awesome_print', '>= 1.0.2')
    s.add_dependency('open4', '>= 1.3.0')
    s.add_dependency('sequel', '>= 3.32.0')
    s.add_dependency('sqlite3', '>= 1.3.5')

    s.authors = ['Brandon Holt', 'Brandon Myers']
    s.homepage = "http://github.com/bholt/experiments"
    s.description = "DSL for running experiments over inputs and storing results in a sqlite database."
end
