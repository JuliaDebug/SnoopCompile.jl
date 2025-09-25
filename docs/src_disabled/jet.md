# Tutorial on JET integration

[JET](https://github.com/aviatesk/JET.jl) is a powerful tool for analyzing your code.
As described [elsewhere](@ref JET), some of its functionality overlaps SnoopCompile, but its mechanism of action is very different. The combination JET and SnoopCompile provides capabilities that neither package has on its own.
Specifically, one can use SnoopCompile to collect data on the full callgraph and JET to perform the exhaustive analysis of individual nodes.

The integration between the two packages is bundled into SnoopCompile, specifically [`report_callee`](@ref),
[`report_callees`](@ref), and [`report_caller`](@ref). These take [`InferenceTrigger`](@ref) (see the page on [inference failures](@ref inferrability)) and use them to generate JET reports. These tools focus on error-analysis rather than optimization, as SnoopCompile can already identify runtime dispatch.

We can demonstrate both the need and use of these tools with a simple extended example.

## JET usage

As a basic introduction to JET, let's analyze the following call from JET's own documentation:

```jldoctest jet; filter=[r"@ reduce.*", r"(in|@)", r"(REPL\[\d+\]|none)"]
julia> using JET

julia> list = Any[1,2,3];

julia> sum(list)
6

julia> @report_call sum(list)
═════ 1 possible error found ═════
┌ sum(a::Vector{Any}) @ Base ./reducedim.jl:1010
│┌ sum(a::Vector{Any}; dims::Colon, kw::@Kwargs{}) @ Base ./reducedim.jl:1010
││┌ _sum(a::Vector{Any}, ::Colon) @ Base ./reducedim.jl:1014
│││┌ _sum(a::Vector{Any}, ::Colon; kw::@Kwargs{}) @ Base ./reducedim.jl:1014
││││┌ _sum(f::typeof(identity), a::Vector{Any}, ::Colon) @ Base ./reducedim.jl:1015
│││││┌ _sum(f::typeof(identity), a::Vector{Any}, ::Colon; kw::@Kwargs{}) @ Base ./reducedim.jl:1015
││││││┌ mapreduce(f::typeof(identity), op::typeof(Base.add_sum), A::Vector{Any}) @ Base ./reducedim.jl:357
│││││││┌ mapreduce(f::typeof(identity), op::typeof(Base.add_sum), A::Vector{Any}; dims::Colon, init::Base._InitialValue) @ Base ./reducedim.jl:357
││││││││┌ _mapreduce_dim(f::typeof(identity), op::typeof(Base.add_sum), ::Base._InitialValue, A::Vector{Any}, ::Colon) @ Base ./reducedim.jl:365
│││││││││┌ _mapreduce(f::typeof(identity), op::typeof(Base.add_sum), ::IndexLinear, A::Vector{Any}) @ Base ./reduce.jl:432
││││││││││┌ mapreduce_empty_iter(f::typeof(identity), op::typeof(Base.add_sum), itr::Vector{Any}, ItrEltype::Base.HasEltype) @ Base ./reduce.jl:380
│││││││││││┌ reduce_empty_iter(op::Base.MappingRF{typeof(identity), typeof(Base.add_sum)}, itr::Vector{Any}, ::Base.HasEltype) @ Base ./reduce.jl:384
││││││││││││┌ reduce_empty(op::Base.MappingRF{typeof(identity), typeof(Base.add_sum)}, ::Type{Any}) @ Base ./reduce.jl:361
│││││││││││││┌ mapreduce_empty(::typeof(identity), op::typeof(Base.add_sum), T::Type{Any}) @ Base ./reduce.jl:372
││││││││││││││┌ reduce_empty(::typeof(Base.add_sum), ::Type{Any}) @ Base ./reduce.jl:352
│││││││││││││││┌ reduce_empty(::typeof(+), ::Type{Any}) @ Base ./reduce.jl:343
││││││││││││││││┌ zero(::Type{Any}) @ Base ./missing.jl:106
│││││││││││││││││ MethodError: no method matching zero(::Type{Any}): Base.throw(Base.MethodError(zero, tuple(Base.Any)::Tuple{DataType})::MethodError)
││││││││││││││││└────────────────────
```

The final line reveals that while `sum` happened to work for the specific `list` we provided, it nevertheless has a "gotcha" for the types we supplied: if `list` happens to be empty, `sum` depends on the ability to generate `zero(T)` for the element-type `T` of `list`, but because we constructed `list` to have an element-type of `Any`, there is no such method and `sum(Any[])` throws an error:

```jldoctest
julia> sum(Int[])
0

julia> sum(Any[])
ERROR: MethodError: no method matching zero(::Type{Any})
[...]
```

(This can be circumvented with `sum(Any[]; init=0)`.)

This is the kind of bug that can lurk undetected for a long time, and JET excels at exposing them.

## JET limitations

JET is a *static* analyzer, meaning that it works from the argument types provided, and that has an important consequence: if a particular callee can't be inferred, JET can't analyze it. We can illustrate that quite easily:

```jldoctest jet
julia> callsum(listcontainer) = sum(listcontainer[1])
callsum (generic function with 1 method)

julia> lc = Any[list];   # "hide" `list` inside a Vector{Any}

julia> callsum(lc)
6

julia> @report_call callsum(lc)
No errors detected
```

Because we "hid" the type of `list` from inference, JET couldn't tell what specific instance of `sum` was going to be called, so it was unable to detect any errors.

## JET/SnoopCompile integration

A resolution to this problem is to use SnoopCompile to do the "data collection" and JET to do the analysis.
The key reason is that SnoopCompile is a dynamic analyzer, and is capable of bridging across runtime dispatch.
As always, you need to do the data collection in a fresh session where the calls have not previously been inferred.
After restarting Julia, we can do this:

```julia
julia> using SnoopCompileCore

julia> list = Any[1,2,3];

julia> lc = Any[list];   # "hide" `list` inside a Vector{Any}

julia> callsum(listcontainer) = sum(listcontainer[1]);

julia> tinf = @snoop_inference callsum(lc);

julia> using SnoopCompile, JET, Cthulhu

julia> tinf.children
2-element Vector{SnoopCompileCore.InferenceTimingNode}:
 InferenceTimingNode: 0.000869/0.000869 on callsum(::Vector{Any}) with 0 direct children
 InferenceTimingNode: 0.000196/0.006685 on sum(::Vector{Any}) with 1 direct children

julia> report_callees(inference_triggers(tinf))
1-element Vector{Pair{InferenceTrigger, JET.JETCallResult{JET.JETAnalyzer{JET.BasicPass}, Base.Pairs{Symbol, Union{}, Tuple{}, @NamedTuple{}}}}}:
 Inference triggered to call sum(::Vector{Any}) from callsum (./REPL[5]:1) with specialization callsum(::Vector{Any}) => ═════ 1 possible error found ═════
┌ sum(a::Vector{Any}) @ Base ./reducedim.jl:1010
│┌ sum(a::Vector{Any}; dims::Colon, kw::@Kwargs{}) @ Base ./reducedim.jl:1010
││┌ _sum(a::Vector{Any}, ::Colon) @ Base ./reducedim.jl:1014
│││┌ _sum(a::Vector{Any}, ::Colon; kw::@Kwargs{}) @ Base ./reducedim.jl:1014
││││┌ _sum(f::typeof(identity), a::Vector{Any}, ::Colon) @ Base ./reducedim.jl:1015
│││││┌ _sum(f::typeof(identity), a::Vector{Any}, ::Colon; kw::@Kwargs{}) @ Base ./reducedim.jl:1015
││││││┌ mapreduce(f::typeof(identity), op::typeof(Base.add_sum), A::Vector{Any}) @ Base ./reducedim.jl:357
│││││││┌ mapreduce(f::typeof(identity), op::typeof(Base.add_sum), A::Vector{Any}; dims::Colon, init::Base._InitialValue) @ Base ./reducedim.jl:357
││││││││┌ _mapreduce_dim(f::typeof(identity), op::typeof(Base.add_sum), ::Base._InitialValue, A::Vector{Any}, ::Colon) @ Base ./reducedim.jl:365
│││││││││┌ _mapreduce(f::typeof(identity), op::typeof(Base.add_sum), ::IndexLinear, A::Vector{Any}) @ Base ./reduce.jl:432
││││││││││┌ mapreduce_empty_iter(f::typeof(identity), op::typeof(Base.add_sum), itr::Vector{Any}, ItrEltype::Base.HasEltype) @ Base ./reduce.jl:380
│││││││││││┌ reduce_empty_iter(op::Base.MappingRF{typeof(identity), typeof(Base.add_sum)}, itr::Vector{Any}, ::Base.HasEltype) @ Base ./reduce.jl:384
││││││││││││┌ reduce_empty(op::Base.MappingRF{typeof(identity), typeof(Base.add_sum)}, ::Type{Any}) @ Base ./reduce.jl:361
│││││││││││││┌ mapreduce_empty(::typeof(identity), op::typeof(Base.add_sum), T::Type{Any}) @ Base ./reduce.jl:372
││││││││││││││┌ reduce_empty(::typeof(Base.add_sum), ::Type{Any}) @ Base ./reduce.jl:352
│││││││││││││││┌ reduce_empty(::typeof(+), ::Type{Any}) @ Base ./reduce.jl:343
││││││││││││││││┌ zero(::Type{Any}) @ Base ./missing.jl:106
│││││││││││││││││ MethodError: no method matching zero(::Type{Any}): Base.throw(Base.MethodError(zero, tuple(Base.Any)::Tuple{DataType})::MethodError)
││││││││││││││││└────────────────────
```

Because SnoopCompileCore collected the runtime-dispatched `sum` call, we can pass it to JET.
`report_callees` filters those calls which generate JET reports, allowing you to focus on potential errors.

!!! note
    JET integration is enabled only if JET.jl _and_ Cthulhu.jl have been loaded into your main session.
    This is why there's the `using JET, Cthulhu` statement included in the example given.
