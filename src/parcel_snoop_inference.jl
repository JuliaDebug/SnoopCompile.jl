import FlameGraphs

using Base.StackTraces: StackFrame
using FlameGraphs.LeftChildRightSiblingTrees: Node, addchild
using SnoopCompileCore: InferenceTimingNode, inclusive, exclusive
using AbstractTrees
using Profile

# Wrapper for which we can customize `show`
struct InferenceTiming
    ci::CodeInstance
end
InferenceTiming(node::InferenceTimingNode) = InferenceTiming(node.ci)
InferenceTiming(node::InferenceTiming) = node

Base.convert(::Type{InferenceTiming}, node::InferenceTimingNode) = InferenceTiming(node.ci)

SnoopCompileCore.inclusive(t::InferenceTiming) = inclusive(t.ci)
SnoopCompileCore.exclusive(t::InferenceTiming) = exclusive(t.ci)

const InferenceNode = Union{InferenceTiming,InferenceTimingNode}

const flamegraph = FlameGraphs.flamegraph  # For re-export

const rextest = r"Test\.jl$"       # for detecting calls from a @testset

# While it might be nice to put some of these in SnoopCompileCore,
# SnoopCompileCore guarantees that it doesn't extend any Base function.
Core.MethodInstance(t::InferenceNode) = Core.Compiler.get_ci_mi(t.ci)

Core.Method(x::InferenceNode) = MethodInstance(x).def::Method   # deliberately throw an error if this is a module

isROOT(mi::MethodInstance) = mi === Core.Compiler.Timings.ROOTmi
isROOT(m::Method) = m === Core.Compiler.Timings.ROOTmi.def
isROOT(node::InferenceNode) = isROOT(MethodInstance(node))

getroot(node::InferenceTimingNode) = isdefined(node.parent, :parent) ? getroot(node.parent) : node

# Record instruction pointers we've already looked up (performance optimization)
const lookups = if isdefined(Core.Compiler, :InterpreterIP)
    Dict{Union{UInt, Core.Compiler.InterpreterIP}, Vector{StackTraces.StackFrame}}()
else
    # Julia 1.12+
    Dict{Union{UInt, Base.InterpreterIP}, Vector{StackTraces.StackFrame}}()
end
lookups_key(ip) = ip
lookups_key(ip::Ptr{Nothing}) = UInt(ip)

_showtiming(io, node) = print(io, @sprintf("%8.6f", exclusive(node)), "/", @sprintf("%8.6f", inclusive(node)), " on ")
showmi(io, mi::MethodInstance) = print(io, replace(sprint(show, mi), "MethodInstance for " => ""))
function Base.show(io::IO, node::InferenceTiming)
    print(io, "InferenceTiming: ")
    _showtiming(io, node)
    showmi(io, MethodInstance(node))
end

# This should be in SnoopCompileCore, except that it promises not to specialize Base methods to avoid invalidating other code
function Base.show(io::IO, node::InferenceTimingNode)
    print(io, "InferenceTimingNode: ")
    _showtiming(io, node)
    showmi(io, MethodInstance(node))
    print(io, " with ", string(length(node.children)), " direct children")
end

"""
    flatten(tinf; tmin = 0.0, sortby=exclusive)

Flatten the execution graph of `InferenceTimingNode`s returned from `@snoop_inference` into a Vector of `InferenceTiming`
frames, each encoding the time needed for inference of a single `MethodInstance`.
By default, results are sorted by `exclusive` time (the time for inferring the `MethodInstance` itself, not including
any inference of its callees); other options are `sortedby=inclusive` which includes the time needed for the callees,
or `nothing` to obtain them in the order they were inferred (depth-first order).

# Example

We'll use [`SnoopCompile.flatten_demo`](@ref), which runs `@snoop_inference` on a workload designed to yield reproducible results:

```jldoctest flatten; setup=:(using SnoopCompile), filter=r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?/[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|WARNING: replacing module FlattenDemo\\.\\n)"
julia> tinf = SnoopCompile.flatten_demo()
InferenceTimingNode: 0.002148974/0.002767166 on Base.Compiler.Timings.ROOT() with 1 direct children

julia> using AbstractTrees; print_tree(tinf)
InferenceTimingNode: 0.00242354/0.00303526 on Base.Compiler.Timings.ROOT() with 1 direct children
└─ InferenceTimingNode: 0.000150891/0.000611721 on SnoopCompile.FlattenDemo.packintype(::$Int) with 2 direct children
   ├─ InferenceTimingNode: 0.000105318/0.000105318 on SnoopCompile.FlattenDemo.MyType{$Int}(::$Int) with 0 direct children
   └─ InferenceTimingNode: 9.43e-5/0.000355512 on SnoopCompile.FlattenDemo.dostuff(::SnoopCompile.FlattenDemo.MyType{$Int}) with 2 direct children
      ├─ InferenceTimingNode: 6.6458e-5/0.000124716 on SnoopCompile.FlattenDemo.extract(::SnoopCompile.FlattenDemo.MyType{$Int}) with 2 direct children
      │  ├─ InferenceTimingNode: 3.401e-5/3.401e-5 on getproperty(::SnoopCompile.FlattenDemo.MyType{$Int}, ::Symbol) with 0 direct children
      │  └─ InferenceTimingNode: 2.4248e-5/2.4248e-5 on getproperty(::SnoopCompile.FlattenDemo.MyType{$Int}, x::Symbol) with 0 direct children
      └─ InferenceTimingNode: 0.000136496/0.000136496 on SnoopCompile.FlattenDemo.domath(::$Int) with 0 direct children
```

Note the printing of `getproperty(::SnoopCompile.FlattenDemo.MyType{$Int}, x::Symbol)`: it shows the specific Symbol, here `:x`,
that `getproperty` was inferred with. This reflects constant-propagation in inference.

Then:
```jldoctest flatten; setup=:(using SnoopCompile), filter=[r"[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?/[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?", r"WARNING: replacing module FlattenDemo.*"]
julia> flatten(tinf; sortby=nothing)
8-element Vector{InferenceTiming}:
 InferenceTiming: 0.002423543/0.0030352639999999998 on Base.Compiler.Timings.ROOT()
 InferenceTiming: 0.000150891/0.0006117210000000001 on SnoopCompile.FlattenDemo.packintype(::$Int)
 InferenceTiming: 0.000105318/0.000105318 on SnoopCompile.FlattenDemo.MyType{$Int}(::$Int)
 InferenceTiming: 9.43e-5/0.00035551200000000005 on SnoopCompile.FlattenDemo.dostuff(::SnoopCompile.FlattenDemo.MyType{$Int})
 InferenceTiming: 6.6458e-5/0.000124716 on SnoopCompile.FlattenDemo.extract(::SnoopCompile.FlattenDemo.MyType{$Int})
 InferenceTiming: 3.401e-5/3.401e-5 on getproperty(::SnoopCompile.FlattenDemo.MyType{$Int}, ::Symbol)
 InferenceTiming: 2.4248e-5/2.4248e-5 on getproperty(::SnoopCompile.FlattenDemo.MyType{$Int}, x::Symbol)
 InferenceTiming: 0.000136496/0.000136496 on SnoopCompile.FlattenDemo.domath(::$Int)
```

```
julia> flatten(tinf; tmin=1e-4)                        # sorts by exclusive time (the time before the '/')
4-element Vector{InferenceTiming}:
 InferenceTiming: 0.000105318/0.000105318 on SnoopCompile.FlattenDemo.MyType{$Int}(::$Int)
 InferenceTiming: 0.000136496/0.000136496 on SnoopCompile.FlattenDemo.domath(::$Int)
 InferenceTiming: 0.000150891/0.0006117210000000001 on SnoopCompile.FlattenDemo.packintype(::$Int)
 InferenceTiming: 0.002423543/0.0030352639999999998 on Base.Compiler.Timings.ROOT()

julia> flatten(tinf; sortby=inclusive, tmin=1e-4)      # sorts by inclusive time (the time after the '/')
6-element Vector{InferenceTiming}:
 InferenceTiming: 0.000105318/0.000105318 on SnoopCompile.FlattenDemo.MyType{$Int}(::$Int)
 InferenceTiming: 6.6458e-5/0.000124716 on SnoopCompile.FlattenDemo.extract(::SnoopCompile.FlattenDemo.MyType{$Int})
 InferenceTiming: 0.000136496/0.000136496 on SnoopCompile.FlattenDemo.domath(::$Int)
 InferenceTiming: 9.43e-5/0.00035551200000000005 on SnoopCompile.FlattenDemo.dostuff(::SnoopCompile.FlattenDemo.MyType{$Int})
 InferenceTiming: 0.000150891/0.0006117210000000001 on SnoopCompile.FlattenDemo.packintype(::$Int)
 InferenceTiming: 0.002423543/0.0030352639999999998 on Base.Compiler.Timings.ROOT()
```

As you can see, `sortby` affects not just the order but also the selection of frames; with exclusive times, `dostuff` did
not on its own rise above threshold, but it does when using inclusive times.

See also: [`accumulate_by_source`](@ref).
"""
function flatten(tinf::InferenceTimingNode; tmin = 0.0, sortby::Union{typeof(exclusive),typeof(inclusive),Nothing}=exclusive)
    out = InferenceTiming[]
    flatten!(sortby === nothing ? exclusive : sortby, out, tinf, tmin)
    return sortby===nothing ? out : sort!(out; by=sortby)
end

function flatten!(gettime::Union{typeof(exclusive),typeof(inclusive)}, out, node, tmin)
    time = gettime(node)
    if time >= tmin
        push!(out, InferenceTiming(node))
    end
    for child in node.children
        flatten!(gettime, out, child, tmin)
    end
    return out
end

"""
    accumulate_by_source(flattened; tmin = 0.0, by=exclusive)

Add the inference timings for all `MethodInstance`s of a single `Method` together.
`flattened` is the output of [`flatten`](@ref).
Returns a list of `(t, method)` tuples.

When the accumulated time for a `Method` is large, but each instance is small, it indicates
that it is being inferred for many specializations (which might include specializations with different constants).

# Example

We'll use [`SnoopCompile.flatten_demo`](@ref), which runs `@snoop_inference` on a workload designed to yield reproducible results:

```jldoctest accum1; setup=:(using SnoopCompile), filter=[r"(in|@)", r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|:[0-9]+\\)|at .*/inference_demos.jl:\\d+|at Base\\.jl:\\d+|at compiler/typeinfer\\.jl:\\d+|WARNING: replacing module FlattenDemo\\.\\n)"]
julia> tinf = SnoopCompile.flatten_demo()
InferenceTimingNode: 0.004978/0.005447 on Base.Compiler.Timings.ROOT() with 1 direct children

julia> accumulate_by_source(flatten(tinf))
7-element Vector{Tuple{Float64, Union{Method, Core.MethodInstance}}}:
 (4.6294999999999996e-5, getproperty(x, f::Symbol) @ Base Base.jl:37)
 (5.8965e-5, dostuff(y) @ SnoopCompile.FlattenDemo ~/.julia/dev/SnoopCompile/src/inference_demos.jl:45)
 (6.4141e-5, extract(y::SnoopCompile.FlattenDemo.MyType) @ SnoopCompile.FlattenDemo ~/.julia/dev/SnoopCompile/src/inference_demos.jl:36)
 (8.9997e-5, (var"#ctor-self#"::Type{SnoopCompile.FlattenDemo.MyType{T}} where T)(x) @ SnoopCompile.FlattenDemo ~/.julia/dev/SnoopCompile/src/inference_demos.jl:35)
 (9.2256e-5, domath(x) @ SnoopCompile.FlattenDemo ~/.julia/dev/SnoopCompile/src/inference_demos.jl:41)
 (0.000117514, packintype(x) @ SnoopCompile.FlattenDemo ~/.julia/dev/SnoopCompile/src/inference_demos.jl:37)
 (0.004977755, ROOT() @ Core.Compiler.Timings compiler/typeinfer.jl:79)
```

Compared to the output from [`flatten`](@ref), the two inferences passes on `getproperty` have been consolidated into a single aggregate call.
"""
function accumulate_by_source(::Type{M}, flattened::Vector{InferenceTiming}; tmin = 0.0, by::Union{typeof(exclusive),typeof(inclusive)}=exclusive) where M<:Union{Method,MethodInstance}
    tmp = Dict{Union{M,MethodInstance},Float64}()
    for frame in flattened
        mi = MethodInstance(frame)
        m = mi.def
        if M === Method && isa(m, Method)
            tmp[m] = get(tmp, m, 0.0) + by(frame)
        else
            tmp[mi] = by(frame)    # module-level thunks are stored verbatim
        end
    end
    return sort(Tuple{Float64,Union{M,MethodInstance}}[(t, m) for (m, t) in tmp if t >= tmin]; by=first)
end

accumulate_by_source(flattened::Vector{InferenceTiming}; kwargs...) = accumulate_by_source(Method, flattened; kwargs...)

"""
    list = collect_for(m::Method, tinf::InferenceTimingNode)
    list = collect_for(m::MethodInstance, tinf::InferenceTimingNode)

Collect all `InferenceTimingNode`s (descendants of `tinf`) that match `m`.
"""
collect_for(target::Union{Method,MethodInstance}, tinf::InferenceTimingNode) = collect_for!(InferenceTimingNode[], target, tinf)
function collect_for!(out, target, tinf)
    matches(mi::MethodInstance, node) = MethodInstance(node) == mi
    matches(m::Method, node) = (mi = MethodInstance(node); mi.def == m)

    matches(target, tinf) && push!(out, tinf)
    for child in tinf.children
        collect_for!(out, target, child)
    end
    return out
end

"""
    staleinstances(tinf::InferenceTimingNode)

Return a list of `InferenceTimingNode`s corresponding to `MethodInstance`s that have "stale" code
(specifically, `CodeInstance`s with outdated `max_world` world ages).
These may be a hint that invalidation occurred while running the workload provided to `@snoop_inference`,
and consequently an important origin of (re)inference.

!!! warning
    `staleinstances` only looks *retrospectively* for stale code; it does not distinguish whether the code became
    stale while running `@snoop_inference` from whether it was already stale before execution commenced.

While `staleinstances` is recommended as a useful "sanity check" to run before performing a detailed analysis of inference,
any serious examination of invalidation should use [`@snoop_invalidations`](@ref).

For more information about world age, see https://docs.julialang.org/en/v1/manual/methods/#Redefining-Methods.
"""
staleinstances(root::InferenceTimingNode; min_world_exclude = UInt(1)) = staleinstances!(InferenceTiming[], root, Base.get_world_counter(), UInt(min_world_exclude)::UInt)

stalenodes(root::InferenceTimingNode; min_world_exclude = UInt(1)) = staleinstances!(InferenceTimingNode[], root, Base.get_world_counter(), UInt(min_world_exclude)::UInt)

function staleinstances!(out, node::InferenceTimingNode, world::UInt, min_world_exclude::UInt)
    if hasstaleinstance(MethodInstance(node), world, min_world_exclude)
        push!(out, node)
        last(out) == node && return out   # don't check children if we collected the whole branch
    end
    for child in node.children
        staleinstances!(out, child, world, min_world_exclude)
    end
    return out
end

# Tip: the following is useful in conjunction with MethodAnalysis.methodinstances() to discover pre-existing stale code
function hasstaleinstance(mi::MethodInstance, world::UInt = Base.get_world_counter(), min_world_exclude::UInt = UInt(1))
    m = mi.def
    mod = isa(m, Module) ? m : m.module
    if Base.parentmodule(mod) !== Core                         # Core runs in an old world
        if isdefined(mi, :cache)
            # Check all CodeInstances
            ci = mi.cache
            while true
                if min_world_exclude <= ci.max_world < world   # 0 indicates a CodeInstance loaded from precompile cache
                    return true
                end
                if isdefined(ci, :next)
                    ci = ci.next
                else
                    break
                end
            end
        end
    end
    return false
end

## parcel and supporting infrastructure

"""
    isprecompilable(mod::Module, mi::MethodInstance)
    isprecompilable(mi::MethodInstance; excluded_modules=Set([Main::Module]))

Determine whether `mi` is able to be precompiled within `mod`. This requires
that all the types in `mi`'s specialization signature are "known" to `mod`. See
[`SnoopCompile.known_type`](@ref) for more information.

`isprecompilable(mi)` sets `mod` to the module in which the corresponding method
was defined. If `mod ∈ excluded_modules`, then `isprecompilable` returns
`false`.

If `mi` has been compiled by the time its defining module "closes" (the final
`end` of the module definition) and `isprecompilable(mi)` returns `true`, then
Julia will automatically include this specialization in that module's precompile
cache.

!!! tip If `mi` is a MethodInstance corresponding to `f(::T)`, then calling
    `f(x::T)` before the end of the module definition suffices to force
    compilation of `mi`. Alternatively, use `precompile(f, (T,))`.

If you'd like to cache it but `isprecompilable(mi)` returns `false`, you need to
identify a module `mod` for which `isprecompilable(mod, mi)` returns `true`.
However, just ensuring that `mi` gets compiled within `mod` may not be
sufficient to ensure that it gets retained in the cache: by default, Julia will
omit it from the cache if none of the types are "owned" by that module. (For
example, if `mod` didn't define the method, and all the types in `mi`'s
signature come from other modules imported by `mod`, then `mod` does not "own"
any aspect of `mi`.) To force it to be retained, ensure it gets called (for the
first time) within a `PrecompileTools.@compile_workload` block. (This is the
main purpose of PrecompileTools.)

# Examples

```jldoctest isprecompilable; setup=:(using SnoopCompile)
julia> module A
       a(x) = x
       end
A

julia> module B
       using ..A
       struct BType end    # this type is not known to A
       b(x) = x
       end
B
```

Now let's run these methods to generate some compiled `MethodInstance`s:

```jldoctest isprecompilable
julia> A.a(3.2)          # Float64 is not "owned" by A, but A loads Base so A knows about it
3.2

julia> A.a(B.BType())    # B.BType is not known to A
B.BType()

julia> B.b(B.BType())    # B knows about B.BType
B.BType()

julia> mia1, mia2 = Base.specializations(only(methods(A.a)));

julia> @show mia1 SnoopCompile.isprecompilable(mia1);
mia1 = MethodInstance for A.a(::Float64)
SnoopCompile.isprecompilable(mia1) = true

julia> @show mia2 SnoopCompile.isprecompilable(mia2);
mia2 = MethodInstance for A.a(::B.BType)
SnoopCompile.isprecompilable(mia2) = false

julia> mib = only(Base.specializations(only(methods(B.b))))
MethodInstance for B.b(::B.BType)

julia> SnoopCompile.isprecompilable(mib)
true

julia> SnoopCompile.isprecompilable(A, mib)
false
```
"""
function isprecompilable(mod::Module, mi::MethodInstance)
    m = mi.def
    if isa(m, Method)
        params = Base.unwrap_unionall(mi.specTypes)::DataType
        for p in params.parameters
            if p isa Type
                known_type(mod, p) || return false
            end
        end
        return true
    end
    return false
end
function isprecompilable(mi::MethodInstance; excluded_modules=Set([Main::Module]))
    m = mi.def
    isa(m, Method) || return false
    mod = m.module
    if excluded_modules !== nothing
        mod ∈ excluded_modules && return false
    end
    return isprecompilable(mod, mi)
end

struct Precompiles
    ci::CodeInstance                                      # entrance point to inference (the "root")
    total_time::Float64                                   # total time for the root
    precompiles::Vector{Tuple{Float64,MethodInstance}}    # list of precompilable child MethodInstances with their times
end
Precompiles(node::InferenceTimingNode) = Precompiles(node.ci, inclusive(node), Tuple{Float64,MethodInstance}[])

Core.MethodInstance(pc::Precompiles) = MethodInstance(pc.mi_info)
SnoopCompileCore.inclusive(pc::Precompiles) = pc.total_time
precompilable_time(precompiles::Vector{Tuple{Float64,MethodInstance}}) = sum(first, precompiles; init=0.0)
precompilable_time(precompiles::Dict{MethodInstance,T}) where T = sum(values(precompiles); init=zero(T))
precompilable_time(pc::Precompiles) = precompilable_time(pc.precompiles)

function Base.show(io::IO, pc::Precompiles)
    tpc = precompilable_time(pc)
    print(io, "Precompiles: ", pc.total_time, " for ", MethodInstance(pc),
              " had ", length(pc.precompiles), " precompilable roots reclaiming ", tpc,
              " ($(round(Int, 100*tpc/pc.total_time))%)")
end

function precompilable_roots!(pc, node::InferenceTimingNode, tthresh; excluded_modules=Set([Main::Module]))
    (t = inclusive(node)) >= tthresh || return pc
    mi = MethodInstance(node)
    if isprecompilable(mi; excluded_modules)
        push!(pc.precompiles, (t, mi))
        return pc
    end
    foreach(node.children) do c
        precompilable_roots!(pc, c, tthresh; excluded_modules=excluded_modules)
    end
    return pc
end

function precompilable_roots(node::InferenceTimingNode, tthresh; kwargs...)
    pcs = [precompilable_roots!(Precompiles(child), child, tthresh; kwargs...) for child in node.children if inclusive(node) >= tthresh]
    t_grand_total = sum(inclusive, node.children)
    tpc = precompilable_time.(pcs)
    p = sortperm(tpc)
    return (t_grand_total, pcs[p])
end

function parcel((t_grand_total,pcs)::Tuple{Float64,Vector{Precompiles}})
    # Because the same MethodInstance can be compiled multiple times for different Const values,
    # we just keep the largest time observed per MethodInstance.
    pcdict = Dict{Module,Dict{MethodInstance,Float64}}()
    for pc in pcs
        for (t, mi) in pc.precompiles
            m = mi.def
            mod = isa(m, Method) ? m.module : m
            pcmdict = get!(Dict{MethodInstance,Float64}, pcdict, mod)
            pcmdict[mi] = max(t, get(pcmdict, mi, zero(Float64)))
        end
    end
    pclist = [mod => (precompilable_time(pcmdict), sort!([(t, mi) for (mi, t) in pcmdict]; by=first)) for (mod, pcmdict) in pcdict]
    sort!(pclist; by = pr -> pr.second[1])
    return t_grand_total, pclist
end

"""
    ttot, pcs = SnoopCompile.parcel(tinf::InferenceTimingNode)

Parcel the "root-most" precompilable MethodInstances into separate modules.
These can be used to generate `precompile` directives to cache the results of type-inference,
reducing latency on first use.

Loosely speaking, and MethodInstance is precompilable if the module that owns the method also
has access to all the types it need to precompile the instance.
When the root node of an entrance to inference is not itself precompilable, `parcel` examines the
children (and possibly, children's children...) until it finds the first node on each branch that
is precompilable. `MethodInstances` are then assigned to the module that owns the method.

`ttot` is the total inference time; `pcs` is a list of `module => (tmod, pclist)` pairs. For each module,
`tmod` is the amount of inference time affiliated with methods owned by that module; `pclist` is a list
of `(t, mi)` time/MethodInstance tuples.

See also: [`SnoopCompile.write`](@ref).

# Example

We'll use [`SnoopCompile.itrigs_demo`](@ref), which runs `@snoop_inference` on a workload designed to yield reproducible results:

```jldoctest parceltree; setup=:(using SnoopCompile), filter=r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|WARNING: replacing module ItrigDemo\\.\\n|UInt8|Float64|SnoopCompile\\.ItrigDemo\\.)"
julia> tinf = SnoopCompile.itrigs_demo()
InferenceTimingNode: 0.004490576/0.004711168 on Base.Compiler.Timings.ROOT() with 2 direct children

julia> ttot, pcs = SnoopCompile.parcel(tinf);

julia> ttot
0.000220592

julia> pcs
1-element Vector{Pair{Module, Tuple{Float64, Vector{Tuple{Float64, Core.MethodInstance}}}}}:
 SnoopCompile.ItrigDemo => (0.000220592, [(9.8986e-5, MethodInstance for double(::Float64)), (0.000121606, MethodInstance for double(::UInt8))])
```

Since there was only one module, `ttot` is the same as `tmod`. The `ItrigDemo` module had two precomilable MethodInstances,
each listed with its corresponding inclusive time.
"""
parcel(tinf::InferenceTimingNode; tmin=0.0, kwargs...) = parcel(precompilable_roots(tinf, tmin; kwargs...))

### write

function get_reprs(tmi::Vector{Tuple{Float64,MethodInstance}}; tmin=0.001, kwargs...)
    strs = OrderedSet{String}()
    modgens = Dict{Module, Vector{Method}}()
    tmp = String[]
    twritten = 0.0
    for (t, mi) in reverse(tmi)
        if t >= tmin
            if add_repr!(tmp, modgens, mi; check_eval=false, time=t, kwargs...)
                str = pop!(tmp)
                if !any(rex -> occursin(rex, str), default_exclusions)
                    push!(strs, str)
                    twritten += t
                end
            end
        end
    end
    return strs, twritten
end

function write(io::IO, tmi::Vector{Tuple{Float64,MethodInstance}}; indent::AbstractString="    ", kwargs...)
    strs, twritten = get_reprs(tmi; kwargs...)
    for str in strs
        println(io, indent, str)
    end
    return twritten, length(strs)
end

function write(prefix::AbstractString, pc::Vector{Pair{Module,Tuple{Float64,Vector{Tuple{Float64,MethodInstance}}}}}; ioreport::IO=stdout, header::Bool=true, always::Bool=false, kwargs...)
    if !isdir(prefix)
        mkpath(prefix)
    end
    for (mod, ttmi) in pc
        tmod, tmi = ttmi
        v, twritten = get_reprs(tmi; kwargs...)
        if isempty(v)
            println(ioreport, "$mod: no precompile statements out of $tmod")
            continue
        end
        open(joinpath(prefix, "precompile_$(mod).jl"), "w") do io
            if header
                if any(str->occursin("__lookup", str), v)
                    println(io, lookup_kwbody_str)
                end
                println(io, "function _precompile_()")
                !always && println(io, "    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing")
            end
            for ln in v
                println(io, "    ", ln)
            end
            header && println(io, "end")
        end
        println(ioreport, "$mod: precompiled $twritten out of $tmod")
    end
end

## Profile-guided de-optimization

# These tools can help balance the need for specialization (to achieve good runtime performance)
# against the desire to reduce specialization to reduce latency.

struct MethodLoc
    func::Symbol
    file::Symbol
    line::Int
end
MethodLoc(sf::StackTraces.StackFrame) = MethodLoc(sf.func, sf.file, sf.line)

Base.show(io::IO, ml::MethodLoc) = print(io, ml.func, " at ", ml.file, ':', ml.line, " [inlined and pre-inferred]")

struct PGDSData
    trun::Float64     # runtime cost
    trtd::Float64     # runtime dispatch cost
    tinf::Float64     # inference time  (either exclusive/inclusive depending on settings)
    nspec::Int        # number of specializations
end
PGDSData() = PGDSData(0.0, 0.0, 0.0, 0)

"""
    ridata = runtime_inferencetime(tinf::InferenceTimingNode; consts=true, by=inclusive)
    ridata = runtime_inferencetime(tinf::InferenceTimingNode, profiledata; lidict, consts=true, by=inclusive)

Compare runtime and inference-time on a per-method basis. `ridata[m::Method]` returns `(trun, tinfer, nspecializations)`,
measuring the approximate amount of time spent running `m`, inferring `m`, and the number of type-specializations, respectively.
`trun` is estimated from profiling data, which the user is responsible for capturing before the call.
Typically `tinf` is collected via `@snoop_inference` on the first call (in a fresh session) to a workload,
and the profiling data collected on a subsequent call. In some cases you may need to repeat the workload
several times to collect enough profiling samples.

`profiledata` and `lidict` are obtained from `Profile.retrieve()`.
"""
function runtime_inferencetime(tinf::InferenceTimingNode; kwargs...)
    pdata = Profile.fetch()
    lookup_firstip!(lookups, pdata)
    return runtime_inferencetime(tinf, pdata; lidict=lookups, kwargs...)
end
function runtime_inferencetime(tinf::InferenceTimingNode, pdata;
                               lidict, consts::Bool=true,
                               by::Union{typeof(exclusive),typeof(inclusive)}=inclusive,
                               delay::Float64=ccall(:jl_profile_delay_nsec, UInt64, ())/10^9)
    tf = flatten(tinf)
    tm = accumulate_by_source(Method, tf; by=by)  # this `by` is actually irrelevant, but less confusing this way
    # MethodInstances that get inlined don't have the linfo field. Guess the method from the name/line/file.
    # Filenames are complicated because of variations in how paths are encoded, especially for methods in Base & stdlibs.
    methodlookup = Dict{Tuple{Symbol,Int},Vector{Pair{String,Method}}}()  # (func, line) => [file => method]
    for (_, m) in tm
        isa(m, Method) || continue
        fm = get!(Vector{Pair{String,Method}}, methodlookup, (m.name, Int(m.line)))
        push!(fm, string(m.file) => m)
    end

    function matchloc(loc::MethodLoc)
        fm = get(methodlookup, (loc.func, Int(loc.line)), nothing)
        fm === nothing && return loc
        meths = Set{Method}()
        locfile = string(loc.file)
        for (f, m) in fm
            endswith(locfile, f) && push!(meths, m)
        end
        length(meths) == 1 && return pop!(meths)
        return loc
    end
    matchloc(sf::StackTraces.StackFrame) = matchloc(MethodLoc(sf))

    ridata = Dict{Union{Method,MethodLoc},PGDSData}()
    # Insert the profiling data
    lilists, nselfs, nrtds = select_firstip(pdata, lidict)
    for (sfs, nself, nrtd) in zip(lilists, nselfs, nrtds)
        for sf in sfs
            mi = sf.linfo
            m = isa(mi, MethodInstance) ? mi.def : matchloc(sf)
            if isa(m, Method) || isa(m, MethodLoc)
                d = get(ridata, m, PGDSData())
                ridata[m] = PGDSData(d.trun + nself*delay, d.trtd + nrtd*delay, d.tinf, d.nspec)
            else
                @show typeof(m) m
                error("whoops")
            end
        end
    end
    # Now add inference times & specialization counts. To get the counts we go back to tf rather than using tm.
    if !consts
        for (t, mi) in accumulate_by_source(MethodInstance, tf; by=by)
            isROOT(mi) && continue
            m = mi.def
            if isa(m, Method)
                d = get(ridata, m, PGDSData())
                ridata[m] = PGDSData(d.trun, d.trtd, d.tinf + t, d.nspec + 1)
            end
        end
    else
        for frame in tf
            isROOT(frame) && continue
            t = by(frame)
            m = MethodInstance(frame).def
            if isa(m, Method)
                d = get(ridata, m, PGDSData())
                ridata[m] = PGDSData(d.trun, d.trtd, d.tinf + t, d.nspec + 1)
            end
        end
    end
    # Sort the outputs to try to prioritize opportunities for the developer. Because we have multiple objectives (fast runtime
    # and fast compile time), there's no unique sorting order, nor can we predict the cost to runtime performance of reducing
    # the method specialization. Here we use the following approximation: we naively estimate "what the inference time could be" if
    # there were only one specialization of each method, and the answers are sorted by the estimated savings. This does not
    # even attempt to account for any risk to the runtime. For any serious analysis, looking at the scatter plot with
    # [`specialization_plot`](@ref) is recommended.
    savings(d::PGDSData) = d.tinf * (d.nspec - 1)
    savings(pr::Pair) = savings(pr.second)
    return sort(collect(ridata); by=savings)
end

function lookup_firstip!(lookups, pdata)
    isfirst = true
    for (i, ip) in enumerate(pdata)
        if isfirst
            sfs = get!(()->Base.StackTraces.lookup(ip), lookups, ip)
            if !all(sf -> sf.from_c, sfs)
                isfirst = false
            end
        end
        if ip == 0
            isfirst = true
        end
    end
    return lookups
end
function select_firstip(pdata, lidict)
    counter = Dict{eltype(pdata),Tuple{Int,Int}}()
    isfirst = true
    isrtd = false
    for ip in pdata
        if isfirst
            sfs = lidict[ip]
            if !all(sf -> sf.from_c, sfs)
                n, nrtd = get(counter, ip, (0, 0))
                counter[ip] = (n + 1, nrtd + isrtd)
                isfirst = isrtd = false
            else
                for sf in sfs
                    isrtd |= FlameGraphs.status(sf) & FlameGraphs.runtime_dispatch
                end
            end
        end
        if ip == 0
            isfirst = true
            isrtd = false
        end
    end
    lilists, nselfs, nrtds = valtype(lidict)[], Int[], Int[]
    for (ip, (n, nrtd)) in counter
        push!(lilists, lidict[ip])
        push!(nselfs, n)
        push!(nrtds, nrtd)
    end
    return lilists, nselfs, nrtds
end

## Analysis of inference triggers

"""
    InferenceTrigger(callee::MethodInstance, callerframes::Vector{StackFrame}, btidx::Int, bt)

Organize information about the "triggers" of inference. `callee` is the `MethodInstance` requiring inference,
`callerframes`, `btidx` and `bt` contain information about the caller.
`callerframes` are the frame(s) of call site that triggered inference; it's a `Vector{StackFrame}`, rather than a
single `StackFrame`, due to the possibility that the caller was inlined into something else, in which case the first entry
is the direct caller and the last entry corresponds to the MethodInstance into which it was ultimately inlined.
`btidx` is the index in `bt`, the backtrace collected upon entry into inference, corresponding to `callerframes`.

`InferenceTrigger`s are created by calling [`inference_triggers`](@ref).
See also: [`callerinstance`](@ref) and [`callingframe`](@ref).
"""
struct InferenceTrigger
    node::InferenceTimingNode
    callerframes::Vector{StackTraces.StackFrame}
    btidx::Int   # callerframes = StackTraces.lookup(bt[btidx])
end

function Base.show(io::IO, itrig::InferenceTrigger)
    print(io, "Inference triggered to call ")
    printstyled(io, stripmi(MethodInstance(itrig.node)); color=:yellow)
    if !isempty(itrig.callerframes)
        sf = first(itrig.callerframes)
        print(io, " from ")
        printstyled(io, sf.func; color=:red, bold=true)
        print(io, " (",  sf.file, ':', sf.line, ')')
        caller = itrig.callerframes[end].linfo
        if isa(caller, MethodInstance) || isa(caller, CodeInstance)
            length(itrig.callerframes) == 1 ? print(io, " with specialization ") : print(io, " inlined into ")
            printstyled(io, stripmi(methodinstance(caller)); color=:blue)
            if length(itrig.callerframes) > 1
                sf = itrig.callerframes[end]
                print(io, " (",  sf.file, ':', sf.line, ')')
            end
        elseif isa(caller, Core.CodeInfo)
            print(io, " called from toplevel code ", caller)
        end
    else
        print(io, " called from toplevel")
    end
end

"""
    mi = callerinstance(itrig::InferenceTrigger)

Return the MethodInstance `mi` of the caller in the selected stackframe in `itrig`.
"""
callerinstance(itrig::InferenceTrigger) = methodinstance(itrig.callerframes[end].linfo)

function callerinstances(itrigs::AbstractVector{InferenceTrigger})
    callers = Set{MethodInstance}()
    for itrig in itrigs
        !isempty(itrig.callerframes) && push!(callers, callerinstance(itrig))
    end
    return callers
end

function callermodule(itrig::InferenceTrigger)
    if !isempty(itrig.callerframes)
        m = callerinstance(itrig).def
        return isa(m, Module) ? m : m.module
    end
    return nothing
end

# Select the next (caller) frame that's a Julia (as opposed to C) frame; returns the stackframe and its index in bt, or nothing
function next_julia_frame(bt, idx, Δ=1; methodinstanceonly::Bool=true, methodonly::Bool=true)
    while 1 <= idx+Δ <= length(bt)
        ip = lookups_key(bt[idx+=Δ])
        sfs = get!(()->Base.StackTraces.lookup(ip), lookups, ip)
        sf = sfs[end]
        sf.from_c && continue
        mi = sf.linfo
        if methodinstanceonly
            if isa(mi, CodeInstance)
                mi = methodinstance(mi)
            end
            isa(mi, MethodInstance) || continue
        end
        if isa(mi, MethodInstance)
            m = mi.def
            methodonly && (isa(m, Method) || continue)
            # Exclude frames that are in Core.Compiler
            isa(m, Method) && m.module === Core.Compiler && continue
            if isa(m, Method) && m.name ∈ (:lock, :store_dispatch_backtrace)
                continue
            end
        end
        return sfs, idx
    end
    return nothing
end

SnoopCompileCore.exclusive(itrig::InferenceTrigger) = exclusive(itrig.node)
SnoopCompileCore.inclusive(itrig::InferenceTrigger) = inclusive(itrig.node)

StackTraces.stacktrace(itrig::InferenceTrigger) = stacktrace(itrig.node.bt)

isprecompilable(itrig::InferenceTrigger) = isprecompilable(MethodInstance(itrig.node))

"""
    itrigs = inference_triggers(tinf::InferenceTimingNode; exclude_toplevel=true)

Collect the "triggers" of inference, each a fresh entry into inference via a call dispatched at runtime.
All the entries in `itrigs` are previously uninferred, or are freshly-inferred for specific constant inputs.

`exclude_toplevel` determines whether calls made from the REPL, `include`, or test suites are excluded.


# Example

We'll use [`SnoopCompile.itrigs_demo`](@ref), which runs `@snoop_inference` on a workload designed to yield reproducible results:

```jldoctest triggers; setup=:(using SnoopCompile), filter=r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|.*/inference_demos\\.jl:\\d+|WARNING: replacing module ItrigDemo\\.\\n)"
julia> tinf = SnoopCompile.itrigs_demo()
InferenceTimingNode: 0.004490576/0.004711168 on Base.Compiler.Timings.ROOT() with 2 direct children

julia> itrigs = inference_triggers(tinf)
2-element Vector{InferenceTrigger}:
 Inference triggered to call MethodInstance for double(::UInt8) from calldouble1 (/pathto/SnoopCompile/src/inference_demos.jl:86) inlined into MethodInstance for calldouble2(::Vector{Vector{Any}}) (/pathto/SnoopCompile/src/inference_demos.jl:87)
 Inference triggered to call MethodInstance for double(::Float64) from calldouble1 (/pathto/SnoopCompile/src/inference_demos.jl:86) inlined into MethodInstance for calldouble2(::Vector{Vector{Any}}) (/pathto/SnoopCompile/src/inference_demos.jl:87)
```

```
julia> edit(itrigs[1])     # opens an editor at the spot in the caller

julia> using Cthulhu

julia> ascend(itrigs[2])   # use Cthulhu to inspect the stacktrace (caller is the second item in the trace)
Choose a call for analysis (q to quit):
 >   double(::Float64)
       calldouble1 at /pathto/SnoopCompile/src/inference_demos.jl:86 => calldouble2(::Vector{Vector{Any}}) at /pathto/SnoopCompile/src/inference_demos.jl:87
         calleach(::Vector{Vector{Vector{Any}}}) at /pathto/SnoopCompile/src/inference_demos.jl:88
...
```
"""
function inference_triggers(tinf::InferenceTimingNode; exclude_toplevel::Bool=true)
    function first_julia_frame(bt)
        ret = next_julia_frame(bt, 0)
        if ret === nothing
            return StackTraces.StackFrame[], 0
        end
        return ret
    end

    itrigs = map(tinf.children) do child
        bt = child.bt
        bt === nothing && throw(ArgumentError("it seems you've supplied a child node, but backtraces are collected only at the entrance to inference: $child"))
        InferenceTrigger(child, first_julia_frame(bt)...)
    end
    if exclude_toplevel
        filter!(maybe_internal, itrigs)
    end
    return itrigs
end

function maybe_internal(itrig::InferenceTrigger)
    for sf in itrig.callerframes
        linfo = sf.linfo
        if isa(linfo, MethodInstance)
            m = linfo.def
            if isa(m, Method)
                if m.module === Base
                    m.name === :include_string && return false
                    m.name === :_include_from_serialized && return false
                    m.name === :return_types && return false   # from `@inferred`
                end
                m.name === :eval && return false
            end
        end
        match(rextest, string(sf.file)) !== nothing && return false
    end

    return true
end

"""
    itrigcaller = callingframe(itrig::InferenceTrigger)

"Step out" one layer of the stacktrace, referencing the caller of the current frame of `itrig`.

You can retrieve the proximal trigger of inference with `InferenceTrigger(itrigcaller)`.

# Example

We collect data using the [`SnoopCompile.itrigs_demo`](@ref):

```julia
julia> itrig = inference_triggers(SnoopCompile.itrigs_demo())[1]
Inference triggered to call MethodInstance for double(::UInt8) from calldouble1 (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:762) inlined into MethodInstance for calldouble2(::Vector{Vector{Any}}) (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:763)

julia> itrigcaller = callingframe(itrig)
Inference triggered to call MethodInstance for double(::UInt8) from calleach (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:764) with specialization MethodInstance for calleach(::Vector{Vector{Vector{Any}}})
```
"""
function callingframe(itrig::InferenceTrigger)
    idx = itrig.btidx
    if idx < length(itrig.node.bt)
        ret = next_julia_frame(itrig.node.bt, idx)
        if ret !== nothing
            return InferenceTrigger(itrig.node, ret...)
        end
    end
    return InferenceTrigger(itrig.node, StackTraces.StackFrame[], length(itrig.node.bt)+1)
end

"""
    itrig0 = InferenceTrigger(itrig::InferenceTrigger)

Reset an inference trigger to point to the stackframe that triggered inference.
This can be useful to undo the actions of [`callingframe`](@ref) and [`skiphigherorder`](@ref).
"""
InferenceTrigger(itrig::InferenceTrigger) = InferenceTrigger(itrig.node, next_julia_frame(itrig.node.bt, 1)...)


"""
    itrignew = skiphigherorder(itrig; exact::Bool=false)

Attempt to skip over frames of higher-order functions that take the callee as a function-argument.
This can be useful if you're analyzing inference triggers for an entire package and would prefer to assign
triggers to package-code rather than Base functions like `map!`, `broadcast`, etc.

# Example

We collect data using the [`SnoopCompile.itrigs_higherorder_demo`](@ref):

```julia
julia> itrig = inference_triggers(SnoopCompile.itrigs_higherorder_demo())[1]
Inference triggered to call MethodInstance for double(::Float64) from mymap! (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:706) with specialization MethodInstance for mymap!(::typeof(SnoopCompile.ItrigHigherOrderDemo.double), ::Vector{Any}, ::Vector{Any})

julia> callingframe(itrig)      # step out one (non-inlined) frame
Inference triggered to call MethodInstance for double(::Float64) from mymap (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:710) with specialization MethodInstance for mymap(::typeof(SnoopCompile.ItrigHigherOrderDemo.double), ::Vector{Any})

julia> skiphigherorder(itrig)   # step out to frame that doesn't have `double` as a function-argument
Inference triggered to call MethodInstance for double(::Float64) from callmymap (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:711) with specialization MethodInstance for callmymap(::Vector{Any})
```

!!! warn
    By default `skiphigherorder` is conservative, and insists on being sure that it's the callee being passed to the higher-order function.
    Higher-order functions that do not get specialized (e.g., with `::Function` argument types) will not be skipped over.
    You can pass `exact=false` to allow `::Function` to also be passed over, but keep in mind that this may falsely skip some frames.
"""
function skiphigherorder(itrig::InferenceTrigger; exact::Bool=true)
    ft = Base.unwrap_unionall(Base.unwrap_unionall(MethodInstance(itrig.node).specTypes).parameters[1])
    sfs, idx = itrig.callerframes, itrig.btidx
    while idx < length(itrig.node.bt)
        if !isempty(sfs)
            callermi = methodinstance(sfs[end].linfo)
            if !hasparameter(callermi.specTypes, ft, exact)
                return InferenceTrigger(itrig.node, sfs, idx)
            end
        end
        ret = next_julia_frame(itrig.node.bt, idx)
        ret === nothing && return InferenceTrigger(itrig.node, sfs, idx)
        sfs, idx = ret
    end
    return itrig
end

function hasparameter(@nospecialize(typ), @nospecialize(ft), exact::Bool)
    isa(typ, Type) || return false
    typ = Base.unwrap_unionall(typ)
    typ === ft && return true
    exact || (typ === Function && return true)
    typ === Union{} && return false
    if isa(typ, Union)
        hasparameter(typ.a, ft, exact) && return true
        hasparameter(typ.b, ft, exact) && return true
        return false
    end
    for p in typ.parameters
        hasparameter(p, ft, exact) && return true
    end
    return false
end

"""
    ncallees, ncallers = diversity(itrigs::AbstractVector{InferenceTrigger})

Count the number of distinct MethodInstances among the callees and callers, respectively, among the triggers in `itrigs`.
"""
function diversity(itrigs)
    # Analyze caller => callee argument type diversity
    callees, callers, ncextra = Set{MethodInstance}(), Set{MethodInstance}(), 0
    for itrig in itrigs
        push!(callees, MethodInstance(itrig.node))
        caller = itrig.callerframes[end].linfo
        if isa(caller, MethodInstance) || isa(caller, CodeInstance)
            push!(callers, methodinstance(caller))
        else
            ncextra += 1
        end
    end
    return length(callees), length(callers) + ncextra
end

# Integrations
AbstractTrees.children(tinf::InferenceTimingNode) = tinf.children

InteractiveUtils.edit(itrig::InferenceTrigger) = edit(Location(itrig.callerframes[end]))

# JET integrations are implemented lazily
"To use `report_caller` do `using JET`"
function report_caller end
"To use `report_callee` do `using JET`"
function report_callee end
"To use `report_callees` do `using JET`"
function report_callees end

filtermod(mod::Module, itrigs::AbstractVector{InferenceTrigger}) = filter(==(mod) ∘ callermodule, itrigs)

### inference trigger trees
# good for organizing into "events"

struct TriggerNode
    itrig::Union{Nothing,InferenceTrigger}
    children::Vector{TriggerNode}
    parent::TriggerNode

    TriggerNode() = new(nothing, TriggerNode[])
    TriggerNode(parent::TriggerNode, itrig::InferenceTrigger) = new(itrig, TriggerNode[], parent)
end

function Base.show(io::IO, node::TriggerNode)
    print(io, "TriggerNode for ")
    AbstractTrees.printnode(io, node)
    print(io, " with ", length(node.children), " direct children")
end

AbstractTrees.children(node::TriggerNode) = node.children
function AbstractTrees.printnode(io::IO, node::TriggerNode)
    if node.itrig === nothing
        print(io, "root")
    else
        print(io, stripmi(MethodInstance(node.itrig.node)))
    end
end

function addchild!(node, itrig)
    newnode = TriggerNode(node, itrig)
    push!(node.children, newnode)
    return newnode
end

truncbt(itrig::InferenceTrigger) = itrig.node.bt[max(1, itrig.btidx):end]

function findparent(node::TriggerNode, bt)
    node.itrig === nothing && return node   # this is the root
    btnode = truncbt(node.itrig)
    lbt, lbtnode = length(bt), length(btnode)
    if lbt > lbtnode && view(bt, lbt - lbtnode + 1 : lbt) == btnode
        return node
    end
    return findparent(node.parent, bt)
end

"""
    root = trigger_tree(itrigs)

Organize inference triggers `itrigs` in tree format, grouping items via the call tree.

It is a tree rather than a more general graph due to the fact that caching inference results means that each node gets
visited only once.
"""
function trigger_tree(itrigs::AbstractVector{InferenceTrigger})
    root = node = TriggerNode()
    for itrig in itrigs
        thisbt = truncbt(itrig)
        node = findparent(node, thisbt)
        node = addchild!(node, itrig)
    end
    return root
end

flatten(node::TriggerNode) = flatten!(InferenceTrigger[], node)
function flatten!(itrigs, node::TriggerNode)
    if node.itrig !== nothing
        push!(itrigs, node.itrig)
    end
    for child in node.children
        flatten!(itrigs, child)
    end
    return itrigs
end

InteractiveUtils.edit(node::TriggerNode) = edit(node.itrig)
Base.stacktrace(node::TriggerNode) = stacktrace(node.itrig)

### tagged trigger lists
# good for organizing a collection of related triggers

struct TaggedTriggers{TT}
    tag::TT
    itrigs::Vector{InferenceTrigger}
end

const MethodTriggers = TaggedTriggers{Method}

"""
    mtrigs = accumulate_by_source(Method, itrigs::AbstractVector{InferenceTrigger})

Consolidate inference triggers via their caller method. `mtrigs` is a vector of `Method=>list`
pairs, where `list` is a list of `InferenceTrigger`s.
"""
function accumulate_by_source(::Type{Method}, itrigs::AbstractVector{InferenceTrigger})
    cs = Dict{Method,Vector{InferenceTrigger}}()
    for itrig in itrigs
        isempty(itrig.callerframes) && continue
        mi = callerinstance(itrig)
        m = mi.def
        if isa(m, Method)
            list = get!(Vector{InferenceTrigger}, cs, m)
            push!(list, itrig)
        end
    end
    return sort!([MethodTriggers(m, list) for (m, list) in cs]; by=methtrig->length(methtrig.itrigs))
end

function Base.show(io::IO, methtrigs::MethodTriggers)
    ncallees, ncallers = diversity(methtrigs.itrigs)
    print(io, methtrigs.tag, " (", ncallees, " callees from ", ncallers, " callers)")
end

"""
    modtrigs = filtermod(mod::Module, mtrigs::AbstractVector{MethodTriggers})

Select just the method-based triggers arising from a particular module.
"""
filtermod(mod::Module, mtrigs::AbstractVector{MethodTriggers}) = filter(mtrig -> mtrig.tag.module === mod, mtrigs)

"""
    modtrigs = SnoopCompile.parcel(mtrigs::AbstractVector{MethodTriggers})

Split method-based triggers into collections organized by the module in which the methods were defined.
Returns a `module => list` vector, with the module having the most `MethodTriggers` last.
"""
function parcel(mtrigs::AbstractVector{MethodTriggers})
    bymod = Dict{Module,Vector{MethodTriggers}}()
    for mtrig in mtrigs
        m = mtrig.tag
        modlist = get!(valtype(bymod), bymod, m.module)
        push!(modlist, mtrig)
    end
    sort!(collect(bymod); by=pr->length(pr.second))
end

InteractiveUtils.edit(mtrigs::MethodTriggers) = edit(mtrigs.tag)

### inference trigger locations
# useful for analyzing patterns at the level of Methods rather than MethodInstances

struct Location  # essentially a LineNumberNode + function name
    func::Symbol
    file::Symbol
    line::Int
end
Location(sf::StackTraces.StackFrame) = Location(sf.func, sf.file, sf.line)
function Location(itrig::InferenceTrigger)
    isempty(itrig.callerframes) && return Location(:from_c, :from_c, 0)
    return Location(itrig.callerframes[1])
end

Base.show(io::IO, loc::Location) = print(io, loc.func, " at ", loc.file, ':', loc.line)
InteractiveUtils.edit(loc::Location) = edit(Base.fixup_stdlib_path(string(loc.file)), loc.line)

const LocationTriggers = TaggedTriggers{Location}

diversity(loctrigs::LocationTriggers) = diversity(loctrigs.itrigs)

function Base.show(io::IO, loctrigs::LocationTriggers)
    ncallees, ncallers = diversity(loctrigs)
    print(io, loctrigs.tag, " (", ncallees, " callees from ", ncallers, " callers)")
end

InteractiveUtils.edit(loctrig::LocationTriggers) = edit(loctrig.tag)

"""
    loctrigs = accumulate_by_source(itrigs::AbstractVector{InferenceTrigger})

Aggregate inference triggers by location (function, file, and line number) of the caller.

# Example

We collect data using the [`SnoopCompile.itrigs_demo`](@ref):

```julia
julia> itrigs = inference_triggers(SnoopCompile.itrigs_demo())
2-element Vector{InferenceTrigger}:
 Inference triggered to call MethodInstance for double(::UInt8) from calldouble1 (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:762) inlined into MethodInstance for calldouble2(::Vector{Vector{Any}}) (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:763)
 Inference triggered to call MethodInstance for double(::Float64) from calldouble1 (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:762) inlined into MethodInstance for calldouble2(::Vector{Vector{Any}}) (/pathto/SnoopCompile/src/parcel_snoop_inference.jl:763)

julia> accumulate_by_source(itrigs)
1-element Vector{SnoopCompile.LocationTriggers}:
    calldouble1 at /pathto/SnoopCompile/src/parcel_snoop_inference.jl:762 (2 callees from 1 callers)
```
"""
function accumulate_by_source(itrigs::AbstractVector{InferenceTrigger}; bycallee::Bool=true)
    cs = IdDict{Any,Vector{InferenceTrigger}}()
    for itrig in itrigs
        lockey = bycallee ? location_key(itrig) : Location(itrig)
        itrigs_loc = get!(Vector{InferenceTrigger}, cs, lockey)
        push!(itrigs_loc, itrig)
    end
    loctrigs = [LocationTriggers(lockey isa Location ? lockey : lockey[1], itrigs_loc) for (lockey, itrigs_loc) in cs]
    return sort!(loctrigs; by=loctrig->length(loctrig.itrigs))
end

function location_key(itrig::InferenceTrigger)
    # Identify a trigger by both its location and what it calls, since some lines can have multiple callees
    loc = Location(itrig)
    callee = MethodInstance(itrig.node)
    tt = Base.unwrap_unionall(callee.specTypes)
    isempty(tt.parameters) && return loc, callee.def  # MethodInstance thunk
    ft = tt.parameters[1]
    return loc, ft
end

filtermod(mod::Module, loctrigs::AbstractVector{LocationTriggers}) = filter(loctrigs) do loctrig
    any(==(mod) ∘ callermodule, loctrig.itrigs)
end

function linetable_match(linetable, sffile::String, sffunc::String, sfline::Int)
    idxs = Int[]
    for (idx, line) in enumerate(linetable)
        line = last(line)   # the linetable is a vector of vectors
        (line.line == sfline && funcname(line) == sffunc) || continue
        # filename matching is a bit troublesome because of differences in naming of Base & stdlibs, defer it
        # in case there is only one match
        push!(idxs, idx)
    end
    length(idxs) == 1 && return idxs
    # Look at the filename too
    delidxs = Int[]
    for (i, idx) in enumerate(idxs)
        line = last(linetable[idx])
        endswith(sffile, String(line.file)) || push!(delidxs, i)
    end
    deleteat!(idxs, delidxs)
    return idxs
end
linetable_match(linetable, sf::StackTraces.StackFrame) =
    linetable_match(linetable, String(sf.file)::String, String(sf.func)::String, Int(sf.line)::Int)

### suggestions

@enum Suggestion begin
    UnspecCall     # a call with unspecified argtypes
    UnspecType     # type-call (constructor) that is not fully specified
    Invoke         # an "invoked" call, i.e., what should normally be an inferrable call
    CalleeVariable # for f(args...) when f is a runtime variable
    CallerVararg   # the caller is a varargs function
    CalleeVararg   # the callee is a varargs function
    InvokedCalleeVararg  # callee is varargs and it was an invoked call
    ErrorPath      # inference aborted because this is on a path guaranteed to throw an exception
    FromTestDirect # directly called from a @testset
    FromTestCallee # one step removed from @testset
    CallerInlineable  # the caller is inlineworthy
    NoCaller       # no caller could be determined (e.g., @async)
    FromInvokeLatest   # called via `Base.invokelatest`
    FromInvoke     # called via `invoke`
    MaybeFromC     # no plausible Julia caller could be identified, but possibly due to a @ccall (e.g., finalizers)
    HasCoreBox     # has a Core.Box slot or ssavalue
end

struct Suggested
    itrig::InferenceTrigger
    categories::Vector{Suggestion}
end
Suggested(itrig::InferenceTrigger) = Suggested(itrig, Suggestion[])

function Base.show(io::IO, s::Suggested)
    if !isempty(s.itrig.callerframes)
        sf = s.itrig.callerframes[1]
        print(io, sf.file, ':', sf.line, ": ")
        sf = s.itrig.callerframes[end]
    else
        sf = "<none>"
    end
    rtcallee = MethodInstance(s.itrig.node)
    show_suggest(io, s.categories, rtcallee, sf)
end

Base.haskey(s::Suggested, k::Suggestion) = k in s.categories

function show_suggest(io::IO, categories, rtcallee, sf)
    showcaller = true
    showvahint = showannotate = false
    handled = false
    if HasCoreBox ∈ categories
        coreboxmsg(io)
        return nothing
    end
    if categories == [FromTestDirect]
        printstyled(io, "called by Test"; color=:cyan)
        print(io, " (ignore)")
        return nothing
    end
    if ErrorPath ∈ categories
        printstyled(io, "error path"; color=:cyan)
        print(io, " (deliberately uninferred, ignore)")
        showcaller = false
    elseif NoCaller ∈ categories
        printstyled(io, "unknown caller"; color=:cyan)
        print(io, ", possibly from a Task")
        showcaller = false
    elseif FromInvokeLatest ∈ categories
        printstyled(io, "called by invokelatest"; color=:cyan)
        print(io, " (ignore)")
        showcaller = false
    elseif FromInvoke ∈ categories
        printstyled(io, "called by invoke"; color=:cyan)
        print(io, " (ignore)")
        showcaller = false
    elseif MaybeFromC ∈ categories
        printstyled(io, "no plausible Julia caller could be identified, but possibly due to a @ccall"; color=:cyan)
        print(io, " (ignore)")
        showcaller = false
    else
        if FromTestCallee ∈ categories && CallerInlineable ∈ categories && CallerVararg ∈ categories && !any(unspec, categories)
            printstyled(io, "inlineable varargs called from Test"; color=:cyan)
            print(io, " (ignore, it's likely to be inferred from a function)")
            showcaller = false
            handled = true
        elseif categories == [FromTestCallee, CallerInlineable, UnspecType]
            printstyled(io, "inlineable type-specialization called from Test"; color=:cyan)
            print(io, " (ignore, it's likely to be inferred from a function)")
            showcaller = false
            handled = true
        elseif CallerVararg ∈ categories && CalleeVararg ∈ categories
            printstyled(io, "vararg caller and callee"; color=:cyan)
            any(unspec, categories) && printstyled(io, " (uninferred)"; color=:cyan)
            showvahint = true
            showcaller = false
            handled = true
        elseif CallerInlineable ∈ categories && CallerVararg ∈ categories && any(unspec, categories)
            printstyled(io, "uninferred inlineable vararg caller"; color=:cyan)
            print(io, " (options: add relevant specialization, ignore)")
            handled = true
        elseif InvokedCalleeVararg ∈ categories
            printstyled(io, "invoked callee is varargs"; color=:cyan)
            showvahint = true
        end
        if !handled
            if UnspecCall ∈ categories
                printstyled(io, "non-inferrable or unspecialized call"; color=:cyan)
                CallerVararg ∈ categories && printstyled(io, " with vararg caller"; color=:cyan)
                CalleeVararg ∈ categories && printstyled(io, " with vararg callee"; color=:cyan)
                showannotate = true
            end
            if UnspecType ∈ categories
                printstyled(io, "partial type call"; color=:cyan)
                CallerVararg ∈ categories && printstyled(io, " with vararg caller"; color=:cyan)
                CalleeVararg ∈ categories && printstyled(io, " with vararg callee"; color=:cyan)
                showannotate = true
            end
            if Invoke ∈ categories
                printstyled(io, "invoked callee"; color=:cyan)
                # if FromTestCallee ∈ categories || FromTestDirect ∈ categories
                #     print(io, " (consider precompiling ", sf, ")")
                # else
                    print(io, " (", sf, " may fail to precompile)")
                # end
                showcaller = false
            end
            if CalleeVariable ∈ categories
                printstyled(io, "variable callee"; color=:cyan)
                print(io, ", if possible avoid assigning function to variable;\n  perhaps use `cond ? f(a) : g(a)` rather than `func = cond ? f : g; func(a)`")
            end
            if isempty(categories) || categories ⊆ [FromTestDirect, FromTestCallee, CallerVararg, CalleeVararg, CallerInlineable]
                printstyled(io, "Unspecialized or unknown"; color=:cyan)
                print(io, " for ", stripmi(rtcallee), " consider `stacktrace(itrig)` or `ascend(itrig)` to investigate more deeply")
                showcaller = false
            end
        end
    end
    if showvahint
        print(io, " (options: ignore, homogenize the arguments, declare an umbrella type, or force-specialize the callee ", rtcallee, " in the caller)")
    end
    if showannotate
        if CallerVararg ∈ categories
            print(io, ", ignore or perhaps annotate ", sf, " with result type of ", stripmi(rtcallee))
        else
            print(io, ", perhaps annotate ", sf, " with result type of ", stripmi(rtcallee))
        end
        print(io, "\nIf a noninferrable argument is a type or function, Julia's specialization heuristics may be responsible.")
    end
    # if showcaller
    #     idx = s.itrig.btidx
    #     ret = next_julia_frame(s.itrig.node.bt, idx; methodonly=false)
    #     if ret !== nothing
    #         sfs, idx = ret
    #         # if categories != [Inlineable]
    #         #     println(io, "\nimmediate caller(s):")
    #         #     show(io, MIME("text/plain"), sfs)
    #         # end
    #         # if categories == [Inlineable]
    #         #     print(io, "inlineable (ignore this one)")
    #         # if (UnspecCall ∈ categories || UnspecType ∈ categories || CallerVararg ∈ categories) && Inlineable ∈ categories
    #         #     print(io, "\nNote: all callers were inlineable and this was called from a Test. You should be able to ignore this.")
    #         # end
    #     end
    #     # See if we can extract a Test line
    #     ret = next_julia_frame(s.itrig.node.bt, idx; methodonly=false)
    #     while ret !== nothing
    #         sfs, idx = ret
    #         itest = findfirst(sf -> match(rextest, String(sf.file)) !== nothing, sfs)
    #         if itest !== nothing && itest > 1
    #             print(io, "\nFrom test at ", sfs[itest-1])
    #             break
    #         end
    #         ret = next_julia_frame(s.itrig.node.bt, idx; methodonly=false)
    #     end
    # end
end

function coreboxmsg(io::IO)
    printstyled(io, "has Core.Box"; color=:red)
    print(io, " (fix this before tackling other problems, see https://timholy.github.io/SnoopCompile.jl/stable/snoop_invalidations/#Fixing-Core.Box)")
end

"""
    isignorable(s::Suggested)

Returns `true` if `s` is unlikely to be an inference problem in need of fixing.
"""
isignorable(s::Suggestion) = !unspec(s)
isignorable(s::Suggested) = all(isignorable, s.categories)

unspec(s::Suggestion) = s ∈ (UnspecCall, UnspecType, CalleeVariable)
unspec(s::Suggested)  = any(unspec, s.categories)

Base.stacktrace(s::Suggested) = stacktrace(s.itrig)
InteractiveUtils.edit(s::Suggested) = edit(s.itrig)

"""
    suggest(itrig::InferenceTrigger)

Analyze `itrig` and attempt to suggest an interpretation or remedy. This returns a structure of type `Suggested`;
the easiest thing to do with the result is to `show` it; however, you can also filter a list of suggestions.

# Example

```julia
julia> itrigs = inference_triggers(tinf);

julia> sugs = suggest.(itrigs);

julia> sugs_important = filter(!isignorable, sugs)    # discard the ones that probably don't need to be addressed
```

!!! warning
    Suggestions are approximate at best; most often, the proposed fixes should not be taken literally,
    but instead taken as a hint about the "outcome" of a particular runtime dispatch incident.
    The suggestions target calls made with non-inferrable argumets, but often the best place to fix the problem
    is at an earlier stage in the code, where the argument was first computed.

    You can get much deeper insight via `ascend` (and Cthulhu generally), and even `stacktrace` is often useful.
    Suggestions are intended to be a quick and easier-to-comprehend first pass at analyzing an inference trigger.
"""
function suggest(itrig::InferenceTrigger)
    s = Suggested(itrig)

    # Did this call come from a `@testset`?
    fromtest = false
    ret = next_julia_frame(itrig.node.bt, 1; methodinstanceonly=false, methodonly=false)
    if ret !== nothing
        sfs, idx = ret
        itest = findfirst(sf -> match(rextest, String(sf.file)) !== nothing, sfs)
        if itest !== nothing && itest > 1
            fromtest = true
            push!(s.categories, FromTestDirect)
        end
    end
    if !fromtest
        # Also keep track of inline-worthy caller from Test---these would have been OK had they been called from a function
        ret = next_julia_frame(itrig.node.bt, itrig.btidx; methodinstanceonly=false, methodonly=false)
        if ret !== nothing
            sfs, idx = ret
            itest = findfirst(sf -> match(rextest, String(sf.file)) !== nothing, sfs)
            if itest !== nothing && itest > 1
                push!(s.categories, FromTestCallee)
                # It's not clear that the following is useful
                tt = Base.unwrap_unionall(spectypes(itrig.callerframes[end].linfo))::DataType
                cts = Base.code_typed_by_type(tt; debuginfo=:source)
                if length(cts) == 1 && (cts[1][1]::CodeInfo).inlineable
                    push!(s.categories, CallerInlineable)
                end
            end
        end
    end

    if isempty(itrig.callerframes)
        push!(s.categories, NoCaller)
        return s
    end
    if any(frame -> frame.func === :invokelatest, itrig.callerframes)  # this probably never triggers; invokelatest is now a builtin
        push!(s.categories, FromInvokeLatest)
    end
    sf = itrig.callerframes[end]
    tt = Base.unwrap_unionall(spectypes(sf.linfo))::DataType
    cts = Base.code_typed_by_type(tt; debuginfo=:source)
    rtcallee = MethodInstance(itrig.node)

    if Base.isvarargtype(tt.parameters[end])
        push!(s.categories, CallerVararg)
    end
    maybec = false
    for (ct::CodeInfo, _) in cts
        # Check for Core.Box
        if hascorebox(ct)
            push!(s.categories, HasCoreBox)
        end
        stmtidxs = linetable_match(CodeTracking.linetable_scopes(ct, sf.linfo.def), itrig.callerframes[1])
        rtcalleename = isa(rtcallee.def, Method) ? (rtcallee.def::Method).name : nothing
        for stmtidx in stmtidxs
            stmt = ct.code[stmtidx]
            if isa(stmt, Expr)
                if stmt.head === :invoke
                    mi = (stmt.args[1]::CodeInstance).def
                    if mi == MethodInstance(itrig.node)
                        if mi.def.isva
                            push!(s.categories, InvokedCalleeVararg)
                        else
                            push!(s.categories, Invoke)
                        end
                    end
                elseif stmt.head === :call
                    callee = stmt.args[1]
                    if isa(callee, Core.SSAValue)
                        callee = unwrapconst(ct.ssavaluetypes[callee.id])
                        if callee === Any
                            push!(s.categories, CalleeVariable)
                            # return s
                        end
                    elseif isa(callee, Core.Argument)
                        callee = unwrapconst(ct.slottypes[callee.n])
                        if callee === Any
                            push!(s.categories, CalleeVariable)
                            # return s
                        end
                    end
                    # argtyps = stmt.args[2]
                    # First, check if this is an error path
                    skipme = false
                    if stmtidx + 2 <= length(ct.code)
                        chkstmt = ct.code[stmtidx + 2]
                        if isa(chkstmt, Core.ReturnNode) && !isdefined(chkstmt, :val)
                            push!(s.categories, ErrorPath)
                            unique!(s.categories)
                            return s
                        end
                    end
                    calleef = nothing
                    rtm = rtcallee.def::Method
                    isssa = false
                    if isa(callee, GlobalRef) && isa(rtcallee.def, Method)
                        calleef = getfield(callee.mod, callee.name)
                        if calleef === Core._apply_iterate
                            callee = stmt.args[3]
                            calleef, isssa = getcalleef(callee, ct)
                            # argtyps = stmt.args[4]
                        elseif calleef === Base.invoke
                            push!(s.categories, FromInvoke)
                            callee = stmt.args[2]
                            calleef, isssa = getcalleef(callee, ct)
                        end
                    elseif isa(callee, Function) || isa(callee, UnionAll)
                        calleef = callee
                    end
                    if calleef === Any
                        push!(s.categories, CalleeVariable)
                    end
                    if isa(calleef, Function)
                        if calleef === invokelatest
                            push!(s.categories, FromInvokeLatest)
                        end
                        nameof(calleef) == rtcalleename || continue
                        # if isa(argtyps, Core.Argument)
                        #     argtyps = unwrapconst(ct.slottypes[argtyps.n])
                        # elseif isa(argtyps, Core.SSAValue)
                        #     argtyps = unwrapconst(ct.ssavaluetypes[argtyps.id])
                        # end
                        meths = methods(calleef)
                        if rtm ∈ meths
                            if rtm.isva
                                push!(s.categories, CalleeVararg)
                            end
                            push!(s.categories, UnspecCall)
                        elseif isempty(meths) && isssa
                            push!(s.categories, CalleeVariable)
                        elseif isssa
                            error("unhandled ssa condition on ", itrig)
                        elseif isempty(meths)
                            if isa(calleef, Core.Builtin)
                            else
                                error("unhandled meths are empty with calleef ", calleef, " on ", itrig)
                            end
                        end
                    elseif isa(calleef, UnionAll)
                        tt = Base.unwrap_unionall(calleef)
                        if tt <: Type
                            T = tt.parameters[1]
                        else
                            T = tt
                        end
                        if (Base.unwrap_unionall(T)::DataType).name.name === rtcalleename
                            push!(s.categories, UnspecType)
                        end
                    end
                elseif stmt.head === :foreigncall
                    maybec = true
                end
            end
        end
    end
    if isempty(s.categories) && maybec
        push!(s.categories, MaybeFromC)
    end
    unique!(s.categories)
    return s
end

function unwrapconst(@nospecialize(arg))
    if isa(arg, Core.Const)
        return arg.val
    elseif isa(arg, Core.PartialStruct)
        return arg.typ
    elseif @static isdefined(Core.Compiler, :MaybeUndef) ? isa(arg, Core.Compiler.MaybeUndef) : false
        return arg.typ
    end
    return arg
end

function getcalleef(@nospecialize(callee), ct)
    if isa(callee, GlobalRef)
        return getfield(callee.mod, callee.name), false
    elseif isa(callee, Function) || isa(callee, Type)
        return callee, false
    elseif isa(callee, Core.SSAValue)
        return unwrapconst(ct.ssavaluetypes[callee.id]), true
    elseif isa(callee, Core.Argument)
        return unwrapconst(ct.slottypes[callee.n]), false
    end
    error("unhandled callee ", callee, " with type ", typeof(callee))
end

function hascorebox(@nospecialize(typ))
    if isa(typ, CodeInfo)
        ct = typ
        for typlist in (ct.slottypes, ct.ssavaluetypes)
            for typ in typlist
                if hascorebox(typ)
                    return true
                end
            end
        end
    end
    typ = unwrapconst(typ)
    isa(typ, Type) || return false
    typ === Core.Box && return true
    typ = Base.unwrap_unionall(typ)
    typ === Union{} && return false
    if isa(typ, Union)
        return hascorebox(typ.a) | hascorebox(typ.b)
    end
    for p in typ.parameters
        hascorebox(p) && return true
    end
    return false
end

function Base.summary(io::IO, mtrigs::MethodTriggers)
    callers = callerinstances(mtrigs.itrigs)
    m = mtrigs.tag
    println(io, m, " had ", length(callers), " specializations")
    hascb = false
    for mi in callers
        tt = Base.unwrap_unionall(mi.specTypes)::DataType
        mlist = Base._methods_by_ftype(tt, -1, Base.get_world_counter())
        if length(mlist) < 10
            cts = Base.code_typed_by_type(tt; debuginfo=:source)
            for (ct::CodeInfo, _) in cts
                if hascorebox(ct)
                    hascb = true
                    print(io, mi, " ")
                    coreboxmsg(io)
                    println(io)
                    break
                end
            end
        else
            @warn "not checking $mi for Core.Box, too many methods"
        end
        hascb && break
    end
    loctrigs = accumulate_by_source(mtrigs.itrigs)
    sort!(loctrigs; by=loctrig->loctrig.tag.line)
    println(io, "Triggering calls:")
    for loctrig in loctrigs
        itrig = loctrig.itrigs[1]
        ft = (Base.unwrap_unionall(MethodInstance(itrig.node).specTypes)::DataType).parameters[1]
        loc = loctrig.tag
        if loc.func == m.name
            print(io, "Line ", loctrig.tag.line)
        else
            print(io, "Inlined ", loc)
        end
        println(io, ": calling ", ft2f(ft), " (", length(loctrig.itrigs), " instances)")
    end
end
Base.summary(mtrigs::MethodTriggers) = summary(stdout, mtrigs)

struct ClosureF
    ft
end
function Base.show(io::IO, cf::ClosureF)
    lnns = [LineNumberNode(Int(m.line), m.file) for m in methods(cf.ft)]
    print(io, "closure ", cf.ft, " at ")
    if length(lnns) == 1
        print(io, lnns[1])
    else
        sort!(lnns; by=lnn->(lnn.file, lnn.line))
        # avoid the repr with #= =#
        print(io, '[')
        for (i, lnn) in enumerate(lnns)
            print(io, lnn.file, ':', lnn.line)
            i < length(lnns) && print(io, ", ")
        end
        print(io, ']')
    end
end

function ft2f(@nospecialize(ft))
    if isa(ft, DataType)
        return ft <: Type ? #= Type{T} =# ft.parameters[1] :
               isdefined(ft, :instance) ? #= Function =# ft.instance : #= closure =# ClosureF(ft)
    end
    error("unhandled: ", ft)
end

function Base.summary(io::IO, loctrig::LocationTriggers)
    ncallees, ncallers = diversity(loctrig)
    if ncallees > ncallers
        callees = unique([Method(itrig.node) for itrig in loctrig.itrigs])
        println(io, ncallees, " callees from ", ncallers, " callers, consider despecializing the callee(s):")
        show(io, MIME("text/plain"), callees)
        println(io, "\nor improving inferrability of the callers")
    else
        cats_callee_sfs = unique(first, [(suggest(itrig).categories, MethodInstance(itrig.node), itrig.callerframes) for itrig in loctrig.itrigs])
        println(io, ncallees, " callees from ", ncallers, " callers, consider improving inference in the caller(s). Recommendations:")
        for (catg, callee, sfs) in cats_callee_sfs
            show_suggest(io, catg, callee, isempty(sfs) ? "<none>" : sfs[end])
        end
    end
end
Base.summary(loctrig::LocationTriggers) = summary(stdout, loctrig)

struct SuggestNode
    s::Union{Nothing,Suggested}
    children::Vector{SuggestNode}
end
SuggestNode(s::Union{Nothing,Suggested}) = SuggestNode(s, SuggestNode[])
AbstractTrees.children(node::SuggestNode) = node.children

function suggest(node::TriggerNode)
    stree = node.itrig === nothing ? SuggestNode(nothing) : SuggestNode(suggest(node.itrig))
    suggest!(stree, node)
end
function suggest!(stree, node)
    for child in node.children
        newnode = SuggestNode(suggest(child.itrig))
        push!(stree.children, newnode)
        suggest!(newnode, child)
    end
    return stree
end

function Base.show(io::IO, node::SuggestNode)
    if node.s === nothing
        print(io, "no inference trigger")
    else
        show(io, node.s)
    end
    print(" (", string(length(node.children)), " children)")
end

function strip_prefix(io::IO, obj, prefix)
    print(io, obj)
    str = String(take!(io))
    return startswith(str, prefix) ? str[length(prefix)+1:end] : str
end
strip_prefix(obj, prefix) = strip_prefix(IOBuffer(), obj, prefix)

stripmi(args...) = strip_prefix(args..., "MethodInstance for ")
stripifi(args...) = strip_prefix(args..., "InferenceFrameInfo for ")

## Flamegraph creation

"""
    flamegraph(tinf::InferenceTimingNode; include_llvm=true, tmin=0.0, excluded_modules=Set([Main]), mode=nothing)

Convert the call tree of inference timings returned from `@snoop_inference` into
a FlameGraph. Returns a FlameGraphs.FlameGraph structure that represents the
timing trace recorded for type inference and, if `include_llvm` is `true`, LLVM
compilation.

Frames that take less than `tmin` seconds of inclusive time will not be included
in the resultant FlameGraph (meaning total time including it and all of its
children). This can be helpful if you have a very big profile, to save on
processing time.

Non-precompilable frames are marked in reddish colors. `excluded_modules` can be
used to mark methods defined in modules to which you cannot or do not wish to
add precompiles.

`mode` controls how frames are named in tools like ProfileView. `nothing` uses
the default of just the qualified function name, whereas `mode=:spec` will print
the full specialization of each MethodInstance. Supplying a pre-populated
`mode=Dict(method => count)` will cause `count` to be included in the frame name
of the corresponding `method`. This can be used, for example, to display the
number of specializations of each method.

# Example

We'll use [`SnoopCompile.flatten_demo`](@ref), which runs `@snoop_inference` on
a workload designed to yield reproducible results:

```jldoctest flamegraph; setup=:(using SnoopCompile), filter=r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?/[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|at.*typeinfer\\.jl:\\d+|0:\\d+|WARNING: replacing module FlattenDemo\\.\\n)"
julia> tinf = SnoopCompile.flatten_demo()
InferenceTimingNode: 0.002148974/0.002767166 on Base.Compiler.Timings.ROOT() with 1 direct children

julia> fg = flamegraph(tinf)
Node(FlameGraphs.NodeData(ROOT() at typeinfer.jl:75, 0x00, 0:3334431))
```

```
julia> ProfileView.view(fg);  # Display the FlameGraph in a package that supports it
```

You should be able to reconcile the resulting flamegraph to `print_tree(tinf)`
(see [`flatten`](@ref)).

The empty horizontal periods in the flamegraph correspond to times when
something other than inference is running. The total width of the flamegraph is
set from the `ROOT` node.
"""
function FlameGraphs.flamegraph(tinf::InferenceTimingNode; include_llvm::Bool=true, tmin = 0.0, excluded_modules=Set([Main::Module]), mode=nothing)
    duration(node) = inclusive(node; include_llvm)

    isROOT(tinf) && isempty(tinf.children) && @warn "Empty profile: no compilation was recorded."
    ctimes = pushfirst!(cumsum(duration.(tinf.children)), 0)
    if duration(tinf) > ctimes[end]
        push!(ctimes, duration(tinf))
    end
    io = IOBuffer()
    # Compute a "root" frame for the top-level node, to cover the whole profile
    node_data, _ = _flamegraph_frame(duration, io, tinf, 0, false, excluded_modules, mode; stop_secs=ctimes[end])
    root = Node(node_data)
    if !isROOT(tinf)
        node_data, child_check_precompilable = _flamegraph_frame(duration, io, tinf, 0, true, excluded_modules, mode)
        root = addchild(root, node_data)
    end
    return _build_flamegraph!(duration, root, io, tinf, ctimes, tmin, true, excluded_modules, mode)
end
function _build_flamegraph!(duration, root, io::IO, node::InferenceTimingNode, ctimes, tmin, check_precompilable, excluded_modules, mode)
    start_secs = first(ctimes)
    for (i, child) in pairs(node.children)
        if duration(child) > tmin
            node_data, child_check_precompilable = _flamegraph_frame(duration, io, child, ctimes[i], check_precompilable, excluded_modules, mode)
            node = addchild(root, node_data)
            if !isempty(child.children)
                newtimes = pushfirst!(cumsum(duration.(child.children)), 0) .+ start_secs
                _build_flamegraph!(duration, node, io, child, newtimes, tmin, child_check_precompilable, excluded_modules, mode)
            end
        end
    end
    return root
end

# Create a profile frame for this node
function _flamegraph_frame(duration, io::IO, node::InferenceTimingNode, start_secs, check_precompilable::Bool, excluded_modules, mode; stop_secs=nothing)
    function func_name(mi::MethodInstance, ::Nothing)
        m = mi.def
        return isa(m, Method) ? string(m.module, '.', m.name) : string(m, '.', "thunk")
    end
    function func_name(mi::MethodInstance, methcounts::AbstractDict{Method})
        str = func_name(mi, nothing)
        m = mi.def
        if isa(m, Method)
            n = get(methcounts, m, nothing)
            if n !== nothing
                str = string(str, " (", n, ')')
            end
        end
        return str
    end
    function func_name(io::IO, node::InferenceTimingNode, mode)
        if mode === :slots
            error("unsupported in Julia 1.12")
        elseif mode === :spec
            return frame_name(io, MethodInstance(node))
        else
            return func_name(MethodInstance(node), mode)
        end
    end

    mistr = Symbol(func_name(io, node, mode))
    mi = MethodInstance(node)
    m = mi.def
    sf = isa(m, Method) ? StackFrame(mistr, mi.def.file, mi.def.line, mi, false, false, UInt64(0x0)) :
                          StackFrame(mistr, :unknown, 0, mi, false, false, UInt64(0x0))
    status = 0x0   # "default" status -- see FlameGraphs.jl
    if check_precompilable
        mod = isa(m, Method) ? m.module : m
        ispc = isprecompilable(mi; excluded_modules)
        check_precompilable = !ispc
        if !ispc
            status |= FlameGraphs.runtime_dispatch
        end
    end
    # Check for const-propagation
    if hasconstprop(InferenceTiming(node))
        status |= FlameGraphs.gc_event
    end
    if stop_secs === nothing
        stop_secs = duration(node) + start_secs
    end
    range = round(Int, start_secs*1e9) : round(Int, (stop_secs - start_secs)*1e9)
    return FlameGraphs.NodeData(sf, status, range), check_precompilable
end

hasconstprop(node) = false    # FIXME
isconstant(@nospecialize(t)) = isa(t, Core.Const) && !isa(t.val, Union{Type,Function})

function frame_name(io::IO, mi::MethodInstance)
    m = mi.def
    isa(m, Module) && return "thunk"
    return frame_name(io, m.name, mi.specTypes)
end
# Special printing for Type Tuples so they're less ugly in the FlameGraph
function frame_name(io::IO, name, @nospecialize(tt::Type{<:Tuple}))
    try
        Base.show_tuple_as_call(io, name, tt)
        v = String(take!(io))
        return v
    catch e
        e isa InterruptException && rethrow()
        @warn "Error displaying frame: $e"
        return name
    end
end

# NOTE: The "root" node doesn't cover the whole profile, because it's only the _complement_
# of the inference times (so it's missing the _overhead_ from the measurement).
# SO we need to manually create a root node that covers the whole thing.
function max_end_time(node::InferenceTimingNode, recursive::Bool=false, tmax=-one(node.start_time))
    # It's possible that node is already the longest-reaching node.
    t_end = node.start_time + inclusive(node)
    # It's also possible that the last child extends past the end of node. (I think this is
    # possible because of the small unmeasured overhead in computing these measurements.)
    last_node = isempty(node.children) ? node : node.children[end]
    child_end = last_node.start_time + inclusive(last_node)
    # Return the maximum end time to make sure the top node covers the entire graph.
    tmax = max(t_end, child_end, tmax)
    if recursive
        for child in node.children
            tmax = max_end_time(child, true, tmax)
        end
    end
    return tmax
end

for IO in (IOContext{Base.TTY}, IOContext{IOBuffer}, IOBuffer)
    for T = (InferenceTimingNode, InferenceTrigger, Precompiles, MethodLoc, MethodTriggers, Location, LocationTriggers)
        @warnpcfail precompile(show, (IO, T))
    end
end
@warnpcfail precompile(flamegraph, (InferenceTimingNode,))
@warnpcfail precompile(inference_triggers, (InferenceTimingNode,))
@warnpcfail precompile(flatten, (InferenceTimingNode,))
@warnpcfail precompile(accumulate_by_source, (Vector{InferenceTiming},))
@warnpcfail precompile(isprecompilable, (MethodInstance,))
@warnpcfail precompile(parcel, (InferenceTimingNode,))
