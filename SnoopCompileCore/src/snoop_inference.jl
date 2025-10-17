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
    addchildren!(root, cis, backedges, miidx, backtraces)
    return root
end

function addchildren!(parent::InferenceTimingNode, handled::Set{CodeInstance}, miidx)
    for ci in parent.ci.edges
        ci isa CodeInstance || continue
        haskey(miidx, methodinstance(ci)) || continue
        ci ∈ handled && continue
        child = InferenceTimingNode(ci, nothing, parent)
        push!(handled, ci)
        addchildren!(child, handled, miidx)
    end
    return parent
end

function addchildren!(parent::InferenceTimingNode, cis, backedges, miidx, backtraces)
    handled = Set{CodeInstance}()
    for (i, ci) in pairs(cis)
        ci ∈ handled && continue
        # Follow the backedges to the root
        j = i
        be = ci
        while true
            found = false
            for k in backedges[j]
                k ≤ j && continue   # don't get caught in cycles
                be = cis[k]
                if be ∉ handled
                    j = k
                    found = true
                    break
                end
            end
            found || break  # quit when no unhandled backedge found
        end
        be ∈ handled && continue
        # bt1, bt2 = get(backtraces, Core.Compiler.get_ci_mi(be), (nothing, nothing))
        # child = InferenceTimingNode(be, make_stacktrace(bt1, bt2), parent)
        child = InferenceTimingNode(be, get(backtraces, be, nothing), parent)
        push!(handled, be)
        addchildren!(child, handled, miidx)
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
