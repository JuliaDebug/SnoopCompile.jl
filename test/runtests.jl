using Test
using SnoopCompile

if !isempty(ARGS)  # `.github/workflows/ci.yml` sets ARGS to run these tests on CI, but they don't run by default from `Pkg.test`
    "cthulhu" ∈ ARGS && include("extensions/cthulhu.jl")
    "jet" ∈ ARGS && include("extensions/jet.jl")
else
    include("snoop_inference.jl")
    include("snoop_llvm.jl")
    include("snoop_invalidations_parallel.jl")
    include("snoop_invalidations.jl")

    # otherwise-untested demos
    retflat = SnoopCompile.flatten_demo()
    @test !isempty(retflat.children)
end
