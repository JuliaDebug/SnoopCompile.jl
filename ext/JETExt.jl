module JETExt

@static if isdefined(Base, :get_extension)
    import SnoopCompile: report_callee, report_caller, report_callees
    using SnoopCompile: SnoopCompile, InferenceTrigger, callerinstance
    using Cthulhu: specTypes
    using JET: report_call, get_reports
else
    import ..SnoopCompile: report_callee, report_caller, report_callees
    using ..SnoopCompile: SnoopCompile, InferenceTrigger, callerinstance
    using ..Cthulhu: specTypes
    using ..JET: report_call, get_reports
end

"""
    report_callee(itrig::InferenceTrigger)

Return the `JET.report_call` for the callee in `itrig`.
"""
SnoopCompile.report_callee(itrig::InferenceTrigger; jetconfigs...) = report_call(specTypes(itrig); jetconfigs...)

"""
    report_caller(itrig::InferenceTrigger)

Return the `JET.report_call` for the caller in `itrig`.
"""
SnoopCompile.report_caller(itrig::InferenceTrigger; jetconfigs...) = report_call(specTypes(callerinstance(itrig)); jetconfigs...)

"""
    report_callees(itrigs)

Filter `itrigs` for those with a non-passing `JET` report, returning the list of `itrig => report` pairs.

# Examples

```jldoctest jetfib; setup=(using SnoopCompile, JET), filter=[r"\\d direct children", r"[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?/[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?"]
julia> fib(n::Integer) = n ≤ 2 ? n : fib(n-1) + fib(n-2);

julia> function fib(str::String)
           n = length(str)
           return fib(m)    # error is here
       end
fib (generic function with 2 methods)

julia> fib(::Dict) = 0; fib(::Vector) = 0;

julia> list = [5, "hello"];

julia> mapfib(list) = map(fib, list)
mapfib (generic function with 1 method)

julia> tinf = @snoop_inference try mapfib(list) catch end
InferenceTimingNode: 0.049825/0.071476 on Base.Compiler.Timings.ROOT() with 5 direct children

julia> @report_call mapfib(list)
No errors detected
```

JET did not catch the error because the call to `fib` is hidden behind runtime dispatch.
However, when captured by `@snoop_inference`, we get

```jldoctest jetfib; filter=[r"@ .*", r"REPL\\[\\d+\\]|none"]
julia> report_callees(inference_triggers(tinf))
1-element Vector{Pair{InferenceTrigger, JET.JETCallResult{JET.JETAnalyzer{JET.BasicPass{typeof(JET.basic_function_filter)}}, Base.Pairs{Symbol, Union{}, Tuple{}, NamedTuple{(), Tuple{}}}}}}:
 Inference triggered to call fib(::String) from iterate (./generator.jl:47) inlined into Base.collect_to!(::Vector{Int64}, ::Base.Generator{Vector{Any}, typeof(fib)}, ::Int64, ::Int64) (./array.jl:782) => ═════ 1 possible error found ═════
┌ @ none:3 fib(m)
│ variable `m` is not defined
└──────────
```
"""
function SnoopCompile.report_callees(itrigs; jetconfigs...)
    function rr(itrig)
        rpt = try
            report_callee(itrig; jetconfigs...)
        catch err
            @warn "skipping $itrig due to report_callee error" exception=err
            nothing
        end
        return itrig => rpt
    end
    hasreport((itrig, report)) = report !== nothing && !isempty(get_reports(report))

    return [itrigrpt for itrigrpt in map(rr, itrigs) if hasreport(itrigrpt)]
end

end # module JETExt
