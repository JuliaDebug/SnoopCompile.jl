# SnoopCompile.jl

Julia is fast, but its execution speed depends on optimizing code through *compilation*. Code must be compiled before you can use it, and unfortunately compilation is slow. This can cause *latency* the first time you use code: this latency is often called *time-to-first-plot* (TTFP) or more generally *time-to-first-execution* (TTFX). If something feels slow the first time you use it, and fast thereafter, you're probably experiencing the latency of compilation. Note that TTFX is distinct from time-to-load (TTL, which refers to the time you spend waiting for `using MyPkg` to finish), even though both contribute to latency.

Modern versions of Julia can store compiled code to disk (*precompilation*) to reduce or eliminate latency. Users and developers who are interested in reducing TTFX should first head to [PrecompileTools](https://github.com/JuliaLang/PrecompileTools.jl), read its documentation thoroughly, and try using it to solve latency problems.

This package, **SnoopCompile**, should be considered when:

- precompilation doesn't reduce TTFX as much as you wish
- precompilation "works," but only in isolation: as soon as you load (certain) additional packages, TTFX is bad again
- you're wondering if you can reduce the amount of time needed to precompile your package and/or the size of the precompilation cache files

In other words, SnoopCompile is a diagonostic package that helps reveal the causes of latency. Historically, it proceeded PrecompileTools, and indeed PrecompileTools was split out from SnoopCompile. Today, SnoopCompile is generally needed only when PrecompileTools fails to deliver the desired benefits.

## SnoopCompile analysis modes

SnoopCompile "snoops" on the Julia compiler, collecting information that may be useful to developers. Here are some of the things you can do with SnoopCompile:

- diagnose *invalidations*, cases where Julia must throw away previously-compiled code (see [Tutorial on `@snoop_invalidations`](@ref))
- trace *inference*, to learn what code is being newly (or freshly) analyzed in an early stage of the compilation pipeline ([Tutorial on `@snoop_inference`](@ref))
- trace *code generation by LLVM*, a late stage in the compilation pipeline ([Tutorial on `@snoop_llvm`](@ref))
- reveal methods with excessive numbers of compiler-generated specializations, a.k.a.*profile-guided despecialization* ([Tutorial on PGDS](@ref pgds))
- integrate with tools like [JET](https://github.com/aviatesk/JET.jl) to further reduce the risk that your lovingly-precompiled code will be invalidated by loading other packages

## Background information

If nothing else, you should know this:
- invalidations occur when you *load* code (e.g., `using MyPkg`) or otherwise define new methods
- inference and other stages of compilation occur the first time you *run* code for a particular combination of input types

The individual tutorials briefly explain core concepts. More detail can be found in [Understanding SnoopCompile and Julia's compilation pipeline](@ref).

## Who should use this package

SnoopCompile is intended primarily for package *developers* who want to improve the
experience for their users. It is also recommended for users who are willing to "dig deep" and understand why packages they depend on have high latency. **Your experience with latency may be personal, as it can depend on the specific combination of packages you load.** If latency troubles you, don't make the assumption that it must be unfixable: you might be the first person affected by that specific cause of latency.
