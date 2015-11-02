# redo

An implementation of djb's [redo](http://cr.yp.to/redo.html) in [Haskell](https://www.haskell.org/). What is redo? To quote [Chris Forno](https://github.com/jekor):

> Redo allows you to rebuild files from source files when they've changed. It's simpler than other build systems such as Make or SCons and more generic than language-specific build systems such as Cabal or Apache Ant. Redo gains its power and simplicity by leveraging other tools (in the Unix tradition). Build scripts for redo are simply shell scripts that follow a few conventions.

## Installation

To install redo, first make sure you have [GHC](https://www.haskell.org/ghc/) installed. For some, it may be easier to just install the whole [Haskell Platform](https://www.haskell.org/platform/).

Next, clone this repository and run:

    ./do 

in the top level directory. A `bin/` directory will be created with the `redo`, `redo-ifchange`, and `redo-ifcreate` binaries. Add this `bin/` directory to your path, or copy its contents to a directory on your path, and enjoy!

## Usage

TODO

## About This Implementation

This implementation was inspired by [Chris Forno](https://github.com/jekor/redo)'s fantastic YouTube series [Haskell from Scratch](https://www.youtube.com/watch?v=zZ_nI9E9g0I), but has been improved upon in several ways.

1. `redo-ifcreate` is implemented, which rebuilds a target if a dependency is created
2. `redo-always` has been implemented which forces a target to be rebuilt every time
3. Target dependency meta-data is stored in a manner that should be immune to conflicts
4. Improved colors and formatting on redo output to commandline
5. `-x` and `-v` flags (which are passed onto `sh`) have been added to help users debug .do files
6. (TODO) Matching default.do files can build targets below their current directory if no other suitable .do file exists.
7. (TODO) `-jN` flag has been added to support parallel (faster) builds

This implementation has been tested on MacOSX but should work on any Unix-like platform, and with a little exta effort, maybe even on Windows.

## Performance

TODO

## Credits

D. J. Bernstein conceived the idea behind `redo` and wrote some notes at http://cr.yp.to/redo.html.

I first became interested in `redo` after looking at [Avery Pennarun](https://github.com/apenwarr/redo)'s Python implementation, and began using it in my own software projects. 

[Chris Forno](https://github.com/jekor) created a fantastic [on-camera](https://www.youtube.com/watch?v=zZ_nI9E9g0I) implementation of `redo` in Haskell which served as the inspiration for this implementation.
