using Documenter
using SnoopCompileCore
using SnoopCompile
import PyPlot   # so that the visualizations.jl file is loaded

makedocs(
    sitename = "SnoopCompile",
    format = Documenter.HTML(
        prettyurls = true,
    ),
    modules = [SnoopCompileCore, SnoopCompile],
    linkcheck = true,   # the link check is slow, set to false if you're building frequently
    # doctest = :fix,
    warnonly=true,    # delete when https://github.com/JuliaDocs/Documenter.jl/issues/2541 is fixed
    pages = ["index.md",
             "Basic tutorials" => ["tutorials/invalidations.md", "tutorials/snoop_inference.md", "tutorials/snoop_llvm.md", "tutorials/pgdsgui.md", #="tutorials/jet.md"=#],   # FIXME re-enable jet tutorial when JET supports 1.12
             "Advanced tutorials" => ["tutorials/snoop_inference_analysis.md", "tutorials/snoop_inference_parcel.md"],
             "Explanations" => ["explanations/tools.md", "explanations/gotchas.md", "explanations/fixing_inference.md", "explanations/invalidation_classes.md", "explanations/devs.md"],
             "reference.md",
    ],
)

deploydocs(
    repo = "github.com/timholy/SnoopCompile.jl.git",
    push_preview=true
)
