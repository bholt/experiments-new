# Experiments
--------------

This library consists entirely of a single Ruby source file: `experiments.rb`

However, there are several dependencies:

- Ruby version >= 1.9
- Rubygems (should have come with the latest Ruby installations)
- gems:
  - `grit` (git integration)
  - `sequel` (database output)
  - `sqlite3` (note: this also requires sqlite3 itself to be installed)
  - `open4`
  - `awesome_print`

# Installation
To "install", `experiments.rb` simply needs to be on your RUBYPATH, so you can either add this directory to your RUBYPATH, or symlink the file into an existing directory set aside for Ruby libraries on your system.

If you haven't already, clone the project locally:
```bash
> git clone git://github.com/bholt/experiments.git
```

# Examples
The file `run_sample.rb` contains a toy run script for use in an application. This can be placed anywhere convenient and modified for your own use. See the file for more information about usage. The `examples` directory contains more realistic scripts used in [Grappa](http://sampa.cs.washington.edu/grappa). In particular, they contain more useful output parsers.


## Igor (new name brainstorming)
Lab Assistant
I: interactive, investigat{e,or}
G: guide, gatherer
O: of
R: results, ruby

Interactive Guide for Our Research
Interactive Gatherer Of Results

Interactive Guide Of Research
