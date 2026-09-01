"""
SnoopCompile allows you to collect and analyze data on actions of Julia's compiler.

The capabilities depend on your version of Julia; in general, the capabilities that
require more recent Julia versions are also the most powerful and useful. When possible,
you should prefer them above the more limited tools available on earlier versions.

### Invalidations

- `@snoop_invalidations`: record invalidations
- `uinvalidated`: collect unique method invalidations from `@snoop_invalidations`
- `invalidation_trees`: organize invalidation data into trees
- `filtermod`: select trees that invalidate methods in particular modules
- `findcaller`: find a path through invalidation trees reaching a particular method
- `ascend`: interactive analysis of an invalidation tree (with Cthulhu.jl)

### LLVM

- `@snoop_llvm`: record data about the actions of LLVM, the library used to generate native code
- `read_snoop_llvm`: parse data collected by `@snoop_llvm`

### "Deep" data on inference

- `@snoop_inference`: record more extensive data about type-inference (`parcel` and `write` work on these data, too)
- `flamegraph`: prepare a visualization from `@snoop_inference`
- `flatten`: reduce the tree format recorded by `@snoop_inference` to list format
- `accumulate_by_source`: aggregate list items by their source
- `inference_triggers`: extract data on the triggers of inference
- `callerinstance`, `callingframe`, `skiphigherorder`, and `InferenceTrigger`: manipulate stack frames from `inference_triggers`
- `ascend`: interactive analysis of an inference-triggering call chain (with Cthulhu.jl)
- `runtime_inferencetime`: profile-guided deoptimization
"""
module SnoopCompile

using SnoopCompileCore
using SnoopCompileCore: InvalidationLists
# More exports are defined below in the conditional loading sections

using Core: MethodInstance, CodeInstance, Binding, CodeInfo
using InteractiveUtils
using Serialization
using Printf
using OrderedCollections
using CodeTracking
import YAML  # For @snoop_llvm

using Base: specializations

# Parcel Regex
const anonrex = r"#{1,2}\d+#{1,2}\d+"         # detect anonymous functions
const kwrex = r"^#kw##(.*)$|^#([^#]*)##kw$"   # detect keyword-supplying functions (prior to Core.kwcall)
const kwbodyrex = r"^##(\w[^#]*)#\d+"         # detect keyword body methods
# Detect generators for @generated functions from the typename of `generator.gen`:
# "##s123#456" on older Julia versions (through 1.12.0), "##123#456" on newer ones
const genrex = r"^##s?\d+#\d+$"
const innerrex = r"^#[^#]+#\d+"               # detect inner functions

include("utils.jl")

# This is for SnoopCompile's own directives. You don't want to call this from packages because then
# SnoopCompile becomes a dependency of your package. Instead, make sure that `writewarnpcfail` is set to `true`
# in `SnoopCompile.write` and a copy of this macro will be placed at the top
# of your precompile files.
macro warnpcfail(ex::Expr)
    modl = __module__
    file = __source__.file === nothing ? "?" : String(__source__.file)
    line = __source__.line
    quote
        $(esc(ex)) || @warn """precompile directive
     $($(Expr(:quote, ex)))
 failed. Please report an issue in $($modl) (after checking for duplicates) or remove this directive.""" _file=$file _line=$line
    end
end

# Parcel

include("parcel_snoop_inference.jl")
include("inference_demos.jl")
export InferenceTiming, InferenceTimingNode
export exclusive, inclusive, flamegraph, flatten, accumulate_by_source, collect_for, runtime_inferencetime, staleinstances
export InferenceTrigger, inference_triggers, callerinstance, callingframe, skiphigherorder, trigger_tree, suggest, isignorable
export report_callee, report_caller, report_callees

include("parcel_snoop_llvm.jl")
export read_snoop_llvm

include("invalidations.jl")
export uinvalidated, invalidation_trees, filtermod, findcaller

include("invalidation_and_inference.jl")
export precompile_blockers

# Write
include("write.jl")

# For PyPlot extension
"""
    methodref, ax = pgdsgui(tinf::InferenceTimingNode; consts::Bool=true, by=inclusive)
    methodref     = pgdsgui(ax, tinf::InferenceTimingNode; kwargs...)

Create a scatter plot comparing:
    - (vertical axis) the inference time for all instances of each Method, as captured by `tinf`;
    - (horizontal axis) the run time cost, as estimated by capturing a `@profile` before calling this function.

Each dot corresponds to a single method. The face color encodes the number of times that method was inferred,
and the edge color corresponds to the fraction of the runtime spent on runtime dispatch (black is 0%, bright red is 100%).
Clicking on a dot prints the method (or location, if inlined) to the REPL, and sets `methodref[]` to
that method.

`ax` is the pyplot axis of the scatterplot.

!!! compat
    `pgdsgui` depends on PyPlot via Julia extensions. You must load both SnoopCompile and PyPlot for this function to be defined.
"""
function pgdsgui end
export pgdsgui
# For PrettyTables extension
function report_invalidations end
export report_invalidations

end # module
