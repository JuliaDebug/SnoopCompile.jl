# SnoopCompile

[![Build Status](https://github.com/timholy/SnoopCompile.jl/workflows/CI/badge.svg)](https://github.com/timholy/SnoopCompile.jl/actions?query=workflow%3A%22CI%22+branch%3Amaster)
[![Codecov](https://codecov.io/github/timholy/SnoopCompile.jl/coverage.svg)](https://codecov.io/gh/timholy/SnoopCompile.jl)

SnoopCompile observes the Julia compiler, causing it to record the
functions and argument types it's compiling.  From these lists of methods,
you can generate lists of `precompile` directives that may reduce the latency between
loading packages and using them to do "real work."

See the documentation:

[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://timholy.github.io/SnoopCompile.jl/dev/)
