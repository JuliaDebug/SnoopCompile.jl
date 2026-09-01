export @snoop_inference

const snoop_inference_lock = ReentrantLock()
const newly_inferred = CodeInstance[]
const inference_entrance_backtraces = []

function start_tracking()
    iszero(snoop_inference_lock.reentrancy_cnt) || throw(ConcurrencyViolationError("already tracking inference (cannot nest `@snoop_inference` blocks)"))
    lock(snoop_inference_lock)
    empty!(newly_inferred)
    empty!(inference_entrance_backtraces)
    ccall(:jl_set_newly_inferred, Cvoid, (Any,), newly_inferred)
    ccall(:jl_set_inference_entrance_backtraces, Cvoid, (Any,), inference_entrance_backtraces)
    return nothing
end

function stop_tracking()
    Base.assert_havelock(snoop_inference_lock)
    ccall(:jl_set_newly_inferred, Cvoid, (Any,), nothing)
    ccall(:jl_set_inference_entrance_backtraces, Cvoid, (Any,), nothing)
    unlock(snoop_inference_lock)
    return nothing
end

"""
    tinf = @snoop_inference commands;

Produce a profile of julia's type inference, recording the amount of time spent
inferring every `MethodInstance` processed while executing `commands`. Each
fresh entrance to type inference (whether executed directly in `commands` or
because a call was made by runtime-dispatch) also collects a backtrace so the
caller can be identified.

`tinf` is a tree, each node containing data on a particular inference "frame"
(the method, argument-type specializations, parameters, and even any
constant-propagated values). Each reports the
[`exclusive`](@ref)/[`inclusive`](@ref) times, where the exclusive time
corresponds to the time spent inferring this frame in and of itself, whereas the
inclusive time includes the time needed to infer all the callees of this frame.

The top-level node in this profile tree is `ROOT`. Uniquely, its exclusive time
corresponds to the time spent _not_ in julia's type inference (codegen,
llvm_opt, runtime, etc).

Working with `tinf` effectively requires loading `SnoopCompile`.

!!! warning
    Note the semicolon `;` at the end of the `@snoop_inference` macro call.
    Because `SnoopCompileCore` is not permitted to invalidate any code, it cannot define
    the `Base.show` methods that pretty-print `tinf`. Defer inspection of `tinf`
    until `SnoopCompile` has been loaded.

# Example

```jldoctest; setup=:(using SnoopCompileCore), filter=r"([0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?/[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?|\\d direct)"
julia> tinf = @snoop_inference begin
           sort(rand(100))  # Evaluate some code and profile julia's type inference
       end;
```
"""
macro snoop_inference(cmd)
    return esc(quote
        local backtrace_log = $(SnoopCompileCore.start_tracking)()
        try
            $cmd
        finally
            $(SnoopCompileCore.stop_tracking)()
        end
        $timingtree($(SnoopCompileCore.newly_inferred), copy($(SnoopCompileCore.inference_entrance_backtraces)))
    end)
end

struct InferenceTimingNode
    ci::CodeInstance
    children::Vector{InferenceTimingNode}
    bt
    parent::InferenceTimingNode

    function InferenceTimingNode(ci::CodeInstance, st) # for creating the root
        return new(ci, InferenceTimingNode[], st)
    end
    function InferenceTimingNode(ci::CodeInstance, st, parent)
        child = new(ci, InferenceTimingNode[], st, parent)
        push!(parent.children, child)
        return child
    end
end

function timingtree(cis, _backtraces::Vector{Any})
    root = InferenceTimingNode(Core.Compiler.Timings.ROOTmi.cache, nothing)
    # the cis are added in the order children-before-parents, we need to be able to reverse that
    # We index on MethodInstance rather than CodeInstance, because constprop can result in a distinct
    # (and uncached) CodeInstance for the same MethodInstance
    miidx = Dict([methodinstance(ci) for ci in cis] .=> eachindex(cis))
    backedges = [Int[] for _ in eachindex(cis)]
    for (i, ci) in pairs(cis)
        for e in ci.edges
            e isa CodeInstance || continue
            eidx = get(miidx, methodinstance(e), nothing)
            if eidx !== nothing
                push!(backedges[eidx], i)
            end
        end
    end
    backtraces = Dict{CodeInstance,Vector{Union{Ptr{Nothing}, Base.InterpreterIP}}}()
    for i = 1:2:length(_backtraces)
        ci, trace = _backtraces[i], _backtraces[i+1]
        bt = Base._reformat_bt(trace[1], trace[2])
        backtraces[ci] = bt
    end
    # Only a fresh entrance to inference, which is a frame carrying a backtrace, belongs
    # directly below ROOT. A frame with neither a caller nor a backtrace is missing an edge:
    # when inference resolves a recursive cycle, the call that closes the cycle is recorded
    # only in the callee's MethodInstance backedges (issue #456).
    supplement = Dict{Int,Int}()          # frame => the caller recovered for it
    for i in eachindex(cis)
        (isempty(backedges[i]) && !haskey(backtraces, cis[i])) || continue
        mi = methodinstance(cis[i])
        isdefined(mi, :backedges) || continue
        for b in mi.backedges
            k = callerindex(b, miidx)
            (k === nothing || k == i) && continue
            supplement[i] = k
            break
        end
    end
    addchildren!(root, cis, backedges, supplement, miidx, backtraces)
    return root
end

"""
    i = callerindex(backedge, miidx)

Return the index of the frame `backedge` refers to, or `nothing` if that frame was not
collected or `backedge` does not name one (an `invoke` signature, for instance).
"""
function callerindex(@nospecialize(backedge), miidx)
    mi = backedge isa CodeInstance ? methodinstance(backedge) :
         backedge isa MethodInstance ? backedge : return nothing
    return get(miidx, mi, nothing)
end

"""
    j = enclosingframe(backedges, supplement, i)

Return the index of the caller that encloses frame `i`, or 0 if the frame starts its own
inference tree. `backedges[i]` lists the frames that call frame `i`.
"""
function enclosingframe(backedges, supplement, i::Int)
    # Frames are collected children-before-parents, so a caller collected later is the one
    # that encloses this frame.
    for k in backedges[i]
        k > i && return k
    end
    return get(supplement, i, 0)
end

"""
    root_of = rootframes(backedges, supplement)

Return, for each frame, the index of the frame at the top of its chain of callers.
"""
function rootframes(backedges, supplement)
    root_of = zeros(Int, length(backedges))   # 0 = not yet resolved, -1 = on the path being walked
    path = Int[]
    for i in eachindex(backedges)
        root_of[i] == 0 || continue
        empty!(path)
        j, r = i, 0
        while true
            push!(path, j)
            root_of[j] = -1
            k = enclosingframe(backedges, supplement, j)
            if k == 0                   # `j` tops its chain
                r = j
                break
            elseif root_of[k] != 0      # already resolved, or `k` closes a cycle back onto the path
                r = root_of[k] > 0 ? root_of[k] : k
                break
            end
            j = k
        end
        for k in path
            root_of[k] = r
        end
    end
    return root_of
end

function addchildren!(parent::InferenceTimingNode, handled::Set{CodeInstance}, cis, recovered, miidx)
    for ci in parent.ci.edges
        ci isa CodeInstance || continue
        haskey(miidx, methodinstance(ci)) || continue
        ci ∈ handled && continue
        child = InferenceTimingNode(ci, nothing, parent)
        push!(handled, ci)
        addchildren!(child, handled, cis, recovered, miidx)
    end
    # Callees reached only through the MethodInstance backedges
    i = get(miidx, methodinstance(parent.ci), nothing)
    if i !== nothing
        for j in get(recovered, i, ())
            ci = cis[j]
            ci ∈ handled && continue
            child = InferenceTimingNode(ci, nothing, parent)
            push!(handled, ci)
            addchildren!(child, handled, cis, recovered, miidx)
        end
    end
    return parent
end

function addchildren!(parent::InferenceTimingNode, cis, backedges, supplement, miidx, backtraces)
    root_of = rootframes(backedges, supplement)
    recovered = Dict{Int,Vector{Int}}()       # caller => the frames recovered for it
    for (i, k) in supplement
        push!(get!(Vector{Int}, recovered, k), i)
    end
    handled = Set{CodeInstance}()
    for (i, ci) in pairs(cis)
        ci ∈ handled && continue
        # Jump to the precomputed root
        r = root_of[i]
        be = cis[r]
        be ∈ handled && continue
        child = InferenceTimingNode(be, get(backtraces, be, nothing), parent)
        push!(handled, be)
        addchildren!(child, handled, cis, recovered, miidx)
    end
    return parent
end

methodinstance(ci::CodeInstance) = Core.Compiler.get_ci_mi(ci)

# make_stacktrace(bt1::Vector{Ptr{Cvoid}}, bt2::Vector{Any}) = Base._reformat_bt(bt1, bt2)
# make_stacktrace(::Nothing, ::Nothing) = nothing

## API functions

"""
    inclusive(ci::InferenceTimingNode; include_llvm::Bool=true)

Return the time spent inferring `ci` and its callees.
If `include_llvm` is true, the LLVM compilation time is added as well.
"""
inclusive(ci::CodeInstance; include_llvm::Bool=true) = Float64(reinterpret(Float16, ci.time_infer_total)) +
    include_llvm * Float64(reinterpret(Float16, ci.time_compile))
function inclusive(node::InferenceTimingNode; kwargs...)
    t = inclusive(node.ci; kwargs...)
    for child in node.children
        t += inclusive(child; kwargs...)
    end
    return t
end

"""
    exclusive(ci::InferenceTimingNode; include_llvm::Bool=true)

Return the time spent inferring `ci`, not including the time needed for any of its callees.
If `include_llvm` is true, the LLVM compilation time is added.
"""
exclusive(ci::CodeInstance; include_llvm::Bool=true) = Float64(reinterpret(Float16, ci.time_infer_self)) +
    include_llvm * Float64(reinterpret(Float16, ci.time_compile))
exclusive(node::InferenceTimingNode; kwargs...) = exclusive(node.ci; kwargs...)


precompile(start_tracking, ())
precompile(stop_tracking, ())
precompile(timingtree, (Vector{CodeInstance}, Vector{Any}))
