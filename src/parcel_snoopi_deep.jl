import FlameGraphs

using Base.StackTraces: StackFrame
using FlameGraphs.LeftChildRightSiblingTrees: Node, addchild
using Core.Compiler.Timings: Timing, InferenceFrameInfo
using Profile

const flamegraph = FlameGraphs.flamegraph  # For re-export

isROOT(mi_info::InferenceFrameInfo) = isROOT(mi_info.mi)
isROOT(mi::MethodInstance) = mi === Core.Compiler.Timings.ROOTmi
isROOT(m::Method) = m === Core.Compiler.Timings.ROOTmi.def

Core.MethodInstance(mi_info::InferenceFrameInfo) = mi_info.mi
Core.MethodInstance(t::Timing) = MethodInstance(t.mi_info)

# Record instruction pointers we've already looked up (performance optimization)
const lookups = Dict{Union{Ptr{Nothing}, Core.Compiler.InterpreterIP}, Vector{StackTraces.StackFrame}}()

struct InclusiveTiming
    mi_info::InferenceFrameInfo
    inclusive_time::UInt64
    start_time::UInt64
    children::Vector{InclusiveTiming}
end

"""
    flatten_times(timing::Core.Compiler.Timings.Timing; tmin_secs = 0.0)

Flatten the execution graph of Timings returned from `@snoopi_deep` into a Vector of pairs,
with the exclusive time for each invocation of type inference, skipping any frames that
took less than `tmin_secs` seconds. Results are sorted by time.

`ROOT` is a dummy element whose time corresponds to the sum of time spent outside inference. It's
the total time of the operation minus the total time for inference. You can run `sum(first.(result[1:end-1]))`
to get the total inference time, and `sum(first.(result))` to get the total time overall.
"""
function flatten_times(timing::Union{Timing,InclusiveTiming}; tmin_secs = 0.0)
    out = Pair{Float64,InferenceFrameInfo}[]
    frontier = [timing]
    while !isempty(frontier)
        t = popfirst!(frontier)
        time = floattime(t)
        if time >= tmin_secs
            push!(out, time => t.mi_info)
        end
        append!(frontier, t.children)
    end
    return sort(out; by=first)
end

floattime(t::Timing) = t.time / 1e9
floattime(it::InclusiveTiming) = it.inclusive_time / 1e9

"""
    accumulate_by_source(pairs; tmin_secs = 0.0)

Add the inference timings for all `MethodInstance`s of a single `Method` together.
`pairs` is the output of [`flatten_times`](@ref).
Returns a list of `t => method` pairs.

When the accumulated time for a `Method` is large, but each instance is small, it indicates
that it is being inferred for many specializations (which might include specializations with different constants).

# Example

```julia
julia> tinf = @snoopi_deep sort(Float16[1, 2, 3]);

julia> tm = accumulate_by_source(flatten_times(tinf); tmin_secs=0.0005)
6-element Vector{Pair{Float64, Method}}:
 0.000590579 => _copyto_impl!(dest::Array, doffs::Integer, src::Array, soffs::Integer, n::Integer) in Base at array.jl:307
 0.000616788 => partition!(v::AbstractVector{T} where T, lo::Integer, hi::Integer, o::Base.Order.Ordering) in Base.Sort at sort.jl:578
 0.000634394 => sort!(v::AbstractVector{T} where T, lo::Integer, hi::Integer, ::Base.Sort.InsertionSortAlg, o::Base.Order.Ordering) in Base.Sort at sort.jl:527
 0.000720815 => Vector{T}(::UndefInitializer, m::Int64) where T in Core at boot.jl:448
 0.001157551 => getindex(::Type{T}, x, y, z) where T in Base at array.jl:394
 0.046509861 => ROOT() in Core.Compiler.Timings at compiler/typeinfer.jl:75
```

`ROOT` is a dummy element whose time corresponds to the sum of time spent on everything *except* inference.
"""
function accumulate_by_source(::Type{M}, pairs::Vector{Pair{Float64,InferenceFrameInfo}}; tmin_secs = 0.0) where M<:Union{Method,MethodInstance}
    tmp = Dict{Union{M,MethodInstance},Float64}()
    for (t, info) in pairs
        mi = info.mi
        if M === Method && isa(mi.def, Method)
            m = mi.def::Method
            tmp[m] = get(tmp, m, 0.0) + t
        else
            tmp[mi] = t    # module-level thunks are stored verbatim
        end
    end
    return sort([t=>m for (m, t) in tmp if t >= tmin_secs]; by=first)
end

accumulate_by_source(pairs::Vector{Pair{Float64,InferenceFrameInfo}}; kwargs...) = accumulate_by_source(Method, pairs; kwargs...)

Core.MethodInstance(it::InclusiveTiming) = MethodInstance(it.mi_info)

Base.show(io::IO, t::InclusiveTiming) = print(io, "InclusiveTiming: ", t.inclusive_time/10^9, " for ", MethodInstance(t), " with ", length(t.children), " direct children")

inclusive_time(t::InclusiveTiming) = t.inclusive_time

"""
    tinc = SnoopCompile.build_inclusive_times(t::Core.Compiler.Timings.Timing)

Calculate times for inference for a node and all its children. `tinc.inclusive_time` records this time for
node `tinc`; `tinc.children` gives you access to the children of this node.
"""
function build_inclusive_times(t::Timing)
    child_times = InclusiveTiming[
        build_inclusive_times(child)
        for child in t.children
    ]
    incl_time = t.time + sum(inclusive_time, child_times; init=UInt64(0))
    return InclusiveTiming(t.mi_info, incl_time, t.start_time, child_times)
end

## parcel and supporting infrastructure

function isprecompilable(mi::MethodInstance; excluded_modules=Set([Main::Module]))
    m = mi.def
    if isa(m, Method)
        mod = m.module
        can_eval = excluded_modules === nothing || mod ∉ excluded_modules
        if can_eval
            params = Base.unwrap_unionall(mi.specTypes)::DataType
            for p in params.parameters
                if !known_type(mod, p)
                    can_eval = false
                    break
                end
            end
        end
        return can_eval
    end
    return false
end

struct Precompiles
    mi_info::InferenceFrameInfo
    total_time::UInt64
    precompiles::Vector{Tuple{UInt64,MethodInstance}}
end
Precompiles(it::InclusiveTiming) = Precompiles(it.mi_info, it.inclusive_time, Tuple{UInt64,MethodInstance}[])

Core.MethodInstance(pc::Precompiles) = MethodInstance(pc.mi_info)
inclusive_time(pc::Precompiles) = pc.total_time
precompilable_time(precompiles::Vector{Tuple{UInt64,MethodInstance}}) where T = sum(first, precompiles; init=zero(UInt64))
precompilable_time(precompiles::Dict{MethodInstance,T}) where T = sum(values(precompiles); init=zero(T))
precompilable_time(pc::Precompiles) = precompilable_time(pc.precompiles)

function Base.show(io::IO, pc::Precompiles)
    tpc = precompilable_time(pc)
    print(io, "Precompiles: ", pc.total_time/10^9, " for ", MethodInstance(pc),
              " had ", length(pc.precompiles), " precompilable roots reclaiming ", tpc/10^9,
              " ($(round(Int, 100*tpc/pc.total_time))%)")
end

function precompilable_roots!(pc, t::InclusiveTiming, tthresh; excluded_modules=Set([Main::Module]))
    t.inclusive_time >= tthresh || return pc
    mi = MethodInstance(t)
    if isprecompilable(mi; excluded_modules)
        push!(pc.precompiles, (t.inclusive_time, mi))
        return pc
    end
    foreach(t.children) do c
        precompilable_roots!(pc, c, tthresh; excluded_modules=excluded_modules)
    end
    return pc
end

precompilable_roots(t::Timing, tthresh; kwargs...) = precompilable_roots(build_inclusive_times(t), tthresh; kwargs...)
function precompilable_roots(t::InclusiveTiming, tthresh; kwargs...)
    pcs = [precompilable_roots!(Precompiles(it), it, tthresh; kwargs...) for it in t.children if t.inclusive_time >= tthresh]
    t_grand_total = sum(inclusive_time, t.children)
    tpc = precompilable_time.(pcs)
    p = sortperm(tpc)
    return (t_grand_total, pcs[p])
end

function parcel((t_grand_total,pcs)::Tuple{UInt64,Vector{Precompiles}})
    tosecs(mit::Pair{MethodInstance,UInt64}) = (mit.second/10^9, mit.first)
    # Because the same MethodInstance can be compiled multiple times for different Const values,
    # we just keep the largest time observed per MethodInstance.
    pcdict = Dict{Module,Dict{MethodInstance,UInt64}}()
    for pc in pcs
        for (t, mi) in pc.precompiles
            m = mi.def
            mod = isa(m, Method) ? m.module : m
            pcmdict = get!(Dict{MethodInstance,UInt64}, pcdict, mod)
            pcmdict[mi] = max(t, get(pcmdict, mi, zero(UInt64)))
        end
    end
    pclist = [mod => (precompilable_time(pcmdict)/10^9, sort!(tosecs.(collect(pcmdict)); by=first)) for (mod, pcmdict) in pcdict]
    sort!(pclist; by = pr -> pr.second[1])
    return t_grand_total/10^9, pclist
end

function parcel(t::InclusiveTiming; tmin=0.0, kwargs...)
    tthresh = round(UInt64, tmin * 10^9)
    parcel(precompilable_roots(t, tthresh; kwargs...))
end
parcel(t::Timing; kwargs...) = parcel(build_inclusive_times(t); kwargs...)

### write

function get_reprs(tmi::Vector{Tuple{Float64,MethodInstance}}; tmin=0.001)
    strs = OrderedSet{String}()
    modgens = Dict{Module, Vector{Method}}()
    tmp = String[]
    twritten = 0.0
    for (t, mi) in reverse(tmi)
        if t >= tmin
            if add_repr!(tmp, modgens, mi; check_eval=false, time=t)
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

## Profile-guided optimization

# These tools can help balance the need for specialization (to achieve good runtime performance)
# against the desire to reduce specialization to reduce latency.

struct MethodLoc
    func::Symbol
    file::Symbol
    line::Int
end
MethodLoc(sf::StackTraces.StackFrame) = MethodLoc(sf.func, sf.file, sf.line)

Base.show(io::IO, ml::MethodLoc) = print(io, ml.func, " at ", ml.file, ':', ml.line, " [inlined and pre-inferred]")

"""
    ridata = runtime_inferencetime(tinf::Timing)
    ridata = runtime_inferencetime(tinf::Timing, profiledata; lidict)

Compare runtime and inference-time on a per-method basis. `ridata[m::Method]` returns `(trun, tinfer, nspecializations)`,
measuring the approximate amount of time spent running `m`, inferring `m`, and the number of type-specializations, respectively.
`trun` is estimated from profiling data, which the user is responsible for capturing before the call.
Typically `tinf` is collected via `@snoopi_deep` on the first call (in a fresh session) to a workload,
and the profiling data collected on a subsequent call. In some cases you may want to repeat the workload
several times to collect enough profiling samples.
"""
function runtime_inferencetime(tinf::Timing; kwargs...)
    pdata, lidict = Profile.retrieve()
    return runtime_inferencetime(tinf, pdata; lidict=lidict, kwargs...)
end
function runtime_inferencetime(tinf::Timing, pdata; lidict, consts::Bool=true, delay=ccall(:jl_profile_delay_nsec, UInt64, ())/10^9)
    lilist, nsamples, nselfs, totalsamples = Profile.parse_flat(StackTraces.StackFrame, pdata, lidict, false)
    tf = flatten_times(tinf)
    tm = accumulate_by_source(tf)
    # MethodInstances that get inlined don't have the linfo field. Guess the method from the name/line/file.
    # Filenames are complicated because of variations in how paths are encoded, especially for methods in Base & stdlibs.
    methodlookup = Dict{Tuple{Symbol,Int},Vector{Pair{String,Method}}}()  # (func, line) => [file => method]
    for (_, m) in tm
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

    ridata = Dict{Union{Method,MethodLoc},Tuple{Float64,Float64,Int}}()
    # Insert the profiling data
    for (sf, nself) in zip(lilist, nselfs)
        mi = sf.linfo
        m = isa(mi, MethodInstance) ? mi.def : matchloc(sf)
        if isa(m, Method) || isa(m, MethodLoc)
            trun, tinfer, nspecializations = get(ridata, m, (0.0, 0.0, 0))
            ridata[m] = (trun + nself*delay, tinfer, nspecializations)
        else
            @show typeof(m) m
            error("whoops")
        end
    end
    @assert all(ttn -> ttn[2] == 0.0, values(ridata))
    # Now add inference times & specialization counts. To get the counts we go back to tf rather than using tm.
    if !consts
        tf = accumulate_by_source(MethodInstance, tf)
    end
    getmi(mi::MethodInstance) = mi
    getmi(mi_info::InferenceFrameInfo) = mi_info.mi
    for (t, info) in tf
        isROOT(info) && continue
        m = getmi(info).def
        if isa(m, Method)
            trun, tinfer, nspecializations = get(ridata, m, (0.0, 0.0, 0))
            ridata[m] = (trun, tinfer + t, nspecializations + 1)
        end
    end
    # Sort the outputs to try to prioritize opportunities for the developer. Because we have multiple objectives (fast runtime
    # and fast compile time), there's no unique sorting order, nor can we predict the cost to runtime performance of reducing
    # the method specialization. Here we use the following approximation: we naively estimate "what the inference time could be" if
    # there were only one specialization of each method, and the answers are sorted by the estimated savings. This does not
    # even attempt to account for any risk to the runtime. For any serious analysis, looking at the scatter plot with
    # [`specialization_plot`](@ref) is recommended.
    savings((trun, tinfer, nspec)::Tuple{Float64,Float64,Int}) = tinfer * (nspec - 1)
    savings(pr::Pair) = savings(pr.second)
    return sort(collect(ridata); by=savings)
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
"""
struct InferenceTrigger
    callee::MethodInstance
    callerframes::Vector{StackTraces.StackFrame}
    btidx::Int   # callerframes = StackTraces.lookup(bt[btidx])
    bt::Vector{Union{Ptr{Nothing}, Core.Compiler.InterpreterIP}}
end

function Base.show(io::IO, itrig::InferenceTrigger)
    sf = first(itrig.callerframes)
    print(io, "Inference triggered to call ")
    printstyled(io, itrig.callee; color=:yellow)
    print(io, " from ")
    printstyled(io, sf.func; color=:red, bold=true)
    print(io, " (",  sf.file, ':', sf.line, ')')
    caller = itrig.callerframes[end].linfo
    if isa(caller, MethodInstance)
        length(itrig.callerframes) == 1 ? print(io, " with specialization ") : print(io, " inlined into ")
        printstyled(io, caller; color=:blue)
    elseif isa(caller, Core.CodeInfo)
        print(io, " called from toplevel code ", caller)
    end
end

callerinstance(itrig::InferenceTrigger) = itrig.callerframes[end].linfo

InteractiveUtils.edit(itrig::InferenceTrigger) = edit(callerinstance(itrig))

# Select the next (caller) frame that's a Julia (as opposed to C) frame; returns the stackframe and its index in bt, or nothing
function next_julia_frame(bt, idx)
    while idx < length(bt)
        ip = bt[idx+=1]
        sfs = get!(()->Base.StackTraces.lookup(ip), lookups, ip)
        sf = sfs[end]
        sf.from_c && continue
        mi = sf.linfo
        isa(mi, Core.MethodInstance) || continue
        m = mi.def
        isa(m, Method) || continue
        m.module === Core.Compiler && continue
        return sfs, idx
    end
    return nothing
end

"""
    itrigs = inference_triggers(t::Timing, [tinc::InclusiveTiming=build_inclusive_times(t)]; exclude_toplevel=true)

Collect the "triggers" of inference, each a fresh entry into inference via a call dispatched at runtime.
All the entries in `itrigs` are previously uninferred, or are freshly-inferred for specific constant inputs.

`exclude_toplevel` determines whether calls made from the REPL, `include`, or test suites are excluded.

# Example

In a fresh Julia session, `sqrt(::Int)` has not been inferred:

```julia
julia> using SnoopCompile, MethodAnalysis

julia> methodinstance(sqrt, (Int,))

```

However, if we do the following,

```julia
julia> c = (1, 2)
(1, 2)

julia> tinf = @snoopi_deep map(sqrt, c);

julia> itrigs = inference_triggers(tinf)
SnoopCompile.InferenceTrigger[]
```

we get no output. Let's see them all:

```julia
julia> itrigs = inference_triggers(tinf; exclude_toplevel=false)
1-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.000706839s: dispatch MethodInstance for map(::typeof(sqrt), ::Tuple{Int64, Int64}) from eval at ./boot.jl:360
```

This output indicates that `map(::typeof(sqrt), ::Tuple{Int64, Int64})` was runtime-dispatched as a call from `eval`, and that the cost
of inferring it and all of its callees was about 0.7ms. `sqrt(::Int)` does not appear because it was inferred from `map`:

```julia
julia> mi = methodinstance(sqrt, (Int,))    # now this is an inferred MethodInstance
MethodInstance for sqrt(::Int64)

julia> terminal_backedges(mi)
1-element Vector{Core.MethodInstance}:
 MethodInstance for map(::typeof(sqrt), ::Tuple{Int64, Int64})
```

If we change `c` to a `Vector{Int}`, we get more examples of runtime dispatch:

```julia
julia> c = [1, 2];

julia> tinf = @snoopi_deep map(sqrt, c);

julia> itrigs = inference_triggers(tinf)
2-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.000656328s: dispatch MethodInstance for Base.Generator(::typeof(sqrt), ::Vector{Int64}) from map at ./abstractarray.jl:2282
 Inference break costing 0.0196351s: dispatch MethodInstance for collect_similar(::Vector{Int64}, ::Base.Generator{Vector{Int64}, typeof(sqrt)}) from map at ./abstractarray.jl:2282
```

These are not inferrable from `map` because `map(f, ::AbstractArray)` does not specialize on `f`, whereas it does for tuples.
"""
function inference_triggers(t::Timing; exclude_toplevel::Bool=true)
    function first_julia_frame(bt)
        ret = next_julia_frame(bt, 1)
        if ret === nothing
            return StackTraces.StackFrame[], 0
        end
        return ret
    end

    itrigs = map(t.children) do tc
        InferenceTrigger(MethodInstance(tc), first_julia_frame(tc.bt)..., tc.bt)
    end
    if exclude_toplevel
        filter!(maybe_internal, itrigs)
    end
    return itrigs
end

const rextest = r"stdlib.*Test.jl$"
function maybe_internal(itrig::InferenceTrigger)
    for sf in itrig.callerframes
        linfo = sf.linfo
        if isa(linfo, MethodInstance)
            m = linfo.def
            if isa(m, Method)
                m.module === Base && m.name === :include_string && return false
                m.name === :eval && return false
            end
        end
        match(rextest, string(sf.file)) !== nothing && return false
    end
    return true
end

"""
    itrigcaller = callingframe(itrig::InferenceTrigger)

"Step out" one layer, returning data on the caller triggering `itrig`.

# Example

```julia
julia> mymap(f, container) = map(f, container)
mymap (generic function with 1 method)

julia> container = [1 2 3]
1×3 Matrix{Int64}:
 1  2  3

julia> mymap(identity, container)
1×3 Matrix{Int64}:
 1  2  3

julia> tinf = @snoopi_deep mymap(x->x^2, container);

# The inference triggers (here because this function wasn't called previously) are attributed to `map`
julia> itrigs = inference_triggers(tinf)
2-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.000351368s: dispatch MethodInstance for Base.Generator(::var"#5#6", ::Matrix{Int64}) from map at ./abstractarray.jl:2282
 Inference break costing 0.004153674s: dispatch MethodInstance for collect_similar(::Matrix{Int64}, ::Base.Generator{Matrix{Int64}, var"#5#6"}) from map at ./abstractarray.jl:2282

# But we can see that `map` was called by `mymap`:
julia> callingframe.(itrigs)
2-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.000351368s: dispatch MethodInstance for Base.Generator(::var"#5#6", ::Matrix{Int64}) from mymap at ./REPL[2]:1
 Inference break costing 0.004153674s: dispatch MethodInstance for collect_similar(::Matrix{Int64}, ::Base.Generator{Matrix{Int64}, var"#5#6"}) from mymap at ./REPL[2]:1
```
"""
function callingframe(itrig::InferenceTrigger)
    idx = itrig.btidx
    if idx < length(itrig.bt)
        ret = next_julia_frame(itrig.bt, idx)
        if ret !== nothing
            return InferenceTrigger(itrig.callee, ret..., itrig.bt)
        end
    end
    return itrig
end

struct Location  # essentially a LineNumberNode + function name
    func::Symbol
    file::Symbol
    line::Int
end
function Location(itrig::InferenceTrigger)
    isempty(itrig.callerframes) && return Location(:from_c, :from_c, 0)
    sf = itrig.callerframes[1]
    return Location(sf.func, sf.file, sf.line)
end

Base.show(io::IO, loc::Location) = print(io, loc.func, " at ", loc.file, ':', loc.line)

struct LocationTrigger
    loc::Location
    itrigs::Vector{InferenceTrigger}
end

function Base.show(io::IO, loctrigs::LocationTrigger)
    # Analyze caller => callee argument type diversity
    callees, callers, ncextra = Set{MethodInstance}(), Set{MethodInstance}(), 0
    for itrig in loctrigs.itrigs
        push!(callees, itrig.callee)
        caller = itrig.callerframes[end].linfo
        if isa(caller, MethodInstance)
            push!(callers, caller)
        else
            ncextra += 1
        end
    end
    ncallees, ncallers = length(callees), length(callers) + ncextra
    print(io, loctrigs.loc, " (", ncallees, " callees from ", ncallers, " callers)")
end

InteractiveUtils.edit(loctrig::LocationTrigger) = edit(string(loctrig.loc.file), loctrig.loc.line)

"""
    loctrigs = accumulate_by_source(itrigs::AbstractVector{InferenceTrigger})

Aggregate inference triggers by location (function, file, and line number) of the caller.

# Example

```julia
julia> c = Any[1, 1.0, 0x01, Float16(1)];

julia> tinf = @snoopi_deep map(sqrt, c);

julia> itrigs = inference_triggers(tinf)
9-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.000243905s: dispatch MethodInstance for sqrt(::Int64) from iterate at ./generator.jl:47
 Inference break costing 0.000259601s: dispatch MethodInstance for sqrt(::UInt8) from iterate at ./generator.jl:47
 Inference break costing 0.000353063s: dispatch MethodInstance for Base.Generator(::typeof(sqrt), ::Vector{Any}) from map at ./abstractarray.jl:2282
 Inference break costing 0.000411542s: dispatch MethodInstance for _similar_for(::Vector{Any}, ::Type{Float64}, ::Base.Generator{Vector{Any}, typeof(sqrt)}, ::Base.HasShape{1}) from _collect at ./array.jl:682
 Inference break costing 0.000568054s: dispatch MethodInstance for sqrt(::Float16) from iterate at ./generator.jl:47
 Inference break costing 0.002503302s: dispatch MethodInstance for collect_to_with_first!(::Vector{Float64}, ::Float64, ::Base.Generator{Vector{Any}, typeof(sqrt)}, ::Int64) from _collect at ./array.jl:682
 Inference break costing 0.002741125s: dispatch MethodInstance for collect_to!(::Vector{AbstractFloat}, ::Base.Generator{Vector{Any}, typeof(sqrt)}, ::Int64, ::Int64) from collect_to! at ./array.jl:718
 Inference break costing 0.003836296s: dispatch MethodInstance for collect_similar(::Vector{Any}, ::Base.Generator{Vector{Any}, typeof(sqrt)}) from map at ./abstractarray.jl:2282
 Inference break costing 0.010411171s: dispatch MethodInstance for setindex_widen_up_to(::Vector{Float64}, ::Float16, ::Int64) from collect_to! at ./array.jl:717

julia> loctrigs = accumulate_by_source(itrigs)
5-element Vector{Pair{Float64, SnoopCompile.LocationTrigger}}:
            0.00107156 => iterate at ./generator.jl:47 (3 instances)
           0.002741125 => collect_to! at ./array.jl:718 (1 instances)
 0.0029148439999999998 => _collect at ./array.jl:682 (2 instances)
           0.004189359 => map at ./abstractarray.jl:2282 (2 instances)
           0.010411171 => collect_to! at ./array.jl:717 (1 instances)
```

`iterate` accounted for 3 inference triggers, yet the aggregate cost of these was still dwarfed by one made from `collect_to!`.
Let's see what this call was:

```julia
julia> loctrigs[end][2].itrigs
1-element Vector{SnoopCompile.InferenceTrigger}:
 Inference break costing 0.010411171s: dispatch MethodInstance for setindex_widen_up_to(::Vector{Float64}, ::Float16, ::Int64) from collect_to! at ./array.jl:717
```

So inferring `setindex_widen_up_to` was much more expensive than inferring 3 calls of `sqrt`.
"""
function accumulate_by_source(itrigs::AbstractVector{InferenceTrigger})
    cs = Dict{Location,Vector{InferenceTrigger}}()
    for itrig in itrigs
        loc = Location(itrig)
        itrigs_loc = get!(Vector{InferenceTrigger}, cs, loc)
        push!(itrigs_loc, itrig)
    end
    return sort([LocationTrigger(loc, itrigs_loc) for (loc, itrigs_loc) in cs]; by=loctrig->length(loctrig.itrigs))
end

"""
    flamegraph(t::Core.Compiler.Timings.Timing; tmin_secs=0.0)
    flamegraph(t::SnoopCompile.InclusiveTiming; tmin_secs=0.0)

Convert the call tree of inference timings returned from `@snoopi_deep` into a FlameGraph.
Returns a FlameGraphs.FlameGraph structure that represents the timing trace recorded for
type inference.

Frames that take less than `tmin_secs` seconds of _inclusive time_ will not be included
in the resultant FlameGraph (meaning total time including it and all of its children).
This can be helpful if you have a very big profile, to save on processing time.

# Examples
```julia
julia> timing = @snoopi_deep begin
           @eval sort(rand(100))  # Evaluate some code and profile julia's type inference
       end;

julia> fg = flamegraph(timing)
Node(FlameGraphs.NodeData(ROOT() at typeinfer.jl:70, 0x00, 0:15355670))

julia> ProfileView.view(fg);  # Display the FlameGraph in a package that supports it

julia> fg = flamegraph(timing; tmin_secs=0.0001)  # Skip very tiny frames
Node(FlameGraphs.NodeData(ROOT() at typeinfer.jl:70, 0x00, 0:15355670))
```

NOTE: This function must touch every frame in the provided `Timing` to build inclusive
timing information (`InclusiveTiming`). If you have a very large profile, and you plan to
call this function multiple times (say with different values for `tmin_secs`), you can save
some intermediate time by first calling [`SnoopCompile.build_inclusive_times(t)`](@ref), only once,
and then passing in the `InclusiveTiming` object for all subsequent calls.
"""
function FlameGraphs.flamegraph(t::Timing; tmin_secs = 0.0)
    it = build_inclusive_times(t)
    flamegraph(it; tmin_secs=tmin_secs)
end

function FlameGraphs.flamegraph(to::InclusiveTiming; tmin_secs = 0.0)
    tmin_ns = UInt64(round(tmin_secs * 1e9))

    # Compute a "root" frame for the top-level node, to cover the whole profile
    node_data = _flamegraph_frame(to, to.start_time; toplevel=true)
    root = Node(node_data)
    return _build_flamegraph!(root, to, to.start_time, tmin_ns)
end
function _build_flamegraph!(root, to::InclusiveTiming, start_ns, tmin_ns)
    for child in to.children
        if child.inclusive_time > tmin_ns
            node_data = _flamegraph_frame(child, start_ns; toplevel=false)
            node = addchild(root, node_data)
            _build_flamegraph!(node, child, start_ns, tmin_ns)
        end
    end
    return root
end

function frame_name(mi_info::InferenceFrameInfo)
    frame_name(mi_info.mi::MethodInstance)
end
function frame_name(mi::MethodInstance)
    m = mi.def
    isa(m, Module) && return "thunk"
    return frame_name(m.name, mi.specTypes)
end
# Special printing for Type Tuples so they're less ugly in the FlameGraph
function frame_name(name, @nospecialize(tt::Type{<:Tuple}))
    try
        io = IOBuffer()
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
function max_end_time(t::InclusiveTiming)
    # It's possible that t is already the longest-reaching node.
    t_end = UInt64(t.start_time + t.inclusive_time)
    # It's also possible that the last child extends past the end of t. (I think this is
    # possible because of the small unmeasured overhead in computing these measurements.)
    last_node = length(t.children) > 0 ? t.children[end] : t
    child_end = last_node.start_time + last_node.inclusive_time
    # Return the maximum end time to make sure the top node covers the entire graph.
    return max(t_end, child_end)
end

# Make a flat frame for this Timing
function _flamegraph_frame(to::InclusiveTiming, start_ns; toplevel)
    mi = MethodInstance(to)
    tt = Symbol(frame_name(to.mi_info))
    m = mi.def
    sf = isa(m, Method) ? StackFrame(tt, mi.def.file, mi.def.line, mi, false, false, UInt64(0x0)) :
                          StackFrame(tt, :unknown, 0, mi, false, false, UInt64(0x0))
    status = 0x0  # "default" status -- See FlameGraphs.jl
    start = to.start_time - start_ns
    if toplevel
        # Compute a range over the whole profile for the top node.
        range = Int(start) : Int(max_end_time(to) - start_ns)
    else
        range = Int(start) : Int(start + to.inclusive_time)
    end
    return FlameGraphs.NodeData(sf, status, range)
end
