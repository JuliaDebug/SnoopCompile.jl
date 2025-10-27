export uinvalidated, invalidation_trees, filtermod, findcaller

function from_corecompiler(mi::MethodInstance)
    fn = fullname(mi.def.module)
    length(fn) < 2 && return false
    fn[1] === :Core || return false
    return fn[2] === :Compiler
end

"""
    umis = uinvalidated(invlist)

Return the unique invalidated MethodInstances. `invlist` is obtained from [`SnoopCompileCore.@snoop_invalidations`](@ref).
This is similar to `filter`ing for `MethodInstance`s in `invlist`, except that it discards any tagged
`"invalidate_mt_cache"`. These can typically be ignored because they are nearly inconsequential:
they do not invalidate any compiled code, they only transiently affect an optimization of runtime dispatch.
"""
function uinvalidated(invlist::AbstractVector; exclude_corecompiler::Bool=true)
    umis = Set{MethodInstance}()
    i, ilast = firstindex(invlist), lastindex(invlist)
    while i <= ilast
        item = invlist[i]
        if isa(item, Core.MethodInstance)
            if i < lastindex(invlist)
                if invlist[i+1] == "invalidate_mt_cache"
                    i += 2
                    continue
                end
                if invlist[i+1] == "verify_methods"
                    # Skip over the cause, which can also be a MethodInstance
                    # These may be superseded, but they aren't technically invalidated
                    # (e.g., could still be called via `invoke`)
                    i += 2
                end
            end
            if !exclude_corecompiler || !from_corecompiler(item)
                push!(umis, item)
            end
        end
        i += 1
    end
    return umis
end
uinvalidated(invlist::InvalidationLists; kwargs...) = uinvalidated(vcat(invlist.logmeths, invlist.logedges); kwargs...)

# Variable names:
# - `node`, `root`, `leaf`, `parent`, `child`: all `InstanceNode`s, a.k.a. nodes in a MethodInstance tree
# - `methinvs::MethodInvalidations`: the set of invalidations that occur from inserting or deleting a method
# - `trees`: a list of `methinvs`

dummy() = nothing
dummy()
const dummyinstance = first(specializations(which(dummy, ())))

mutable struct InstanceNode
    mi::MethodInstance
    depth::Int32
    children::Vector{InstanceNode}
    parent::InstanceNode

    # Create a new tree. Creates the `root`, but returns the `leaf` holding `mi`.
    # `root == leaf` if `depth = 0`, otherwise parent "dummy" nodes are inserted until
    # the root is created at `depth` 0.
    function InstanceNode(mi::MethodInstance, depth)
        leaf = new(mi, depth, InstanceNode[])
        child = leaf
        while depth > 0
            depth -= 1
            parent = new(dummyinstance, depth, InstanceNode[])
            push!(parent.children, child)
            child.parent = parent
            child = parent
        end
        return leaf
    end
    function InstanceNode(mi::MethodInstance, children::Vector{InstanceNode})
        # re-parent "children"
        root = new(mi, 0, children)
        for child in children
            child.parent = root
        end
        return root
    end
    # Create child with a given `parent`. Checks that the depths are consistent.
    function InstanceNode(mi::MethodInstance, parent::InstanceNode, depth=parent.depth+Int32(1))
        depth !== nothing && @assert parent.depth + Int32(1) == depth
        child = new(mi, depth, InstanceNode[], parent)
        push!(parent.children, child)
        return child
    end
    # Creating a tree, starting with the leaves (omits `parent`)
    function InstanceNode(node::InstanceNode, newchildren::Vector{InstanceNode})
        return new(node.mi, node.depth, newchildren)
    end
end

InstanceNode(ci::CodeInstance, depth) = InstanceNode(ci.def, depth)
InstanceNode(ci::CodeInstance, children::Vector{InstanceNode}) = InstanceNode(ci.def, children)
InstanceNode(ci::CodeInstance, parent::InstanceNode, args...) = InstanceNode(ci.def, parent, args...)

isdummy(node::InstanceNode) = node.mi === dummyinstance

Core.MethodInstance(node::InstanceNode) = node.mi
Base.convert(::Type{MethodInstance}, node::InstanceNode) = node.mi
AbstractTrees.children(node::InstanceNode) = node.children

function getroot(node::InstanceNode)
    while isdefined(node, :parent)
        node = node.parent
    end
    return node
end

function Base.any(f, node::InstanceNode)
    f(node) && return true
    return any(f, node.children)
end

function Base.sort!(node::InstanceNode)
    sort!(node.children; by=countchildren)
    for child in node.children
        sort!(child)
    end
end

# TODO: deprecate this in favor of `AbstractTrees.print_tree`, and limit it to one layer (e.g., like `:showchildren=>false`)
function Base.show(io::IO, node::InstanceNode; methods=false, maxdepth::Int=5, minchildren::Int=round(Int, sqrt(countchildren(node))))
    if get(io, :limit, false)
        print(io, node.mi, " at depth ", node.depth, " with ", countchildren(node), " children")
    else
        nc = map(countchildren, node.children)
        s = sum(nc) + length(node.children)
        indent = " "^Int(node.depth)
        print(io, indent, methods ? node.mi.def : node.mi)
        println(io, " (", s, " children)")
        if get(io, :showchildren, true)::Bool
            p = sortperm(nc)
            skipped = false
            for i in p
                child = node.children[i]
                if child.depth <= maxdepth && nc[i] >= minchildren
                    show(io, child; methods=methods, maxdepth=maxdepth, minchildren=minchildren)
                else
                    skipped = true
                end
            end
            if skipped
                println(io, indent, "⋮")
                return nothing
            end
        end
    end
end
Base.show(node::InstanceNode; kwargs...) = show(stdout, node; kwargs...)

function copybranch(node::InstanceNode)
    children = InstanceNode[copybranch(child) for child in node.children]
    newnode = InstanceNode(node, children)
    for child in children
        child.parent = newnode
    end
    return newnode
end

function countchildren(node::InstanceNode)
    n = length(node.children)
    for child in node.children
        n += countchildren(child)
    end
    return n
end

function adjust_depth!(node::InstanceNode, Δdepth)
    node.depth += Δdepth
    for child in node.children
        adjust_depth!(child, Δdepth)
    end
    return node
end

const BackedgeMT = Pair{Union{DataType,Binding},InstanceNode}  # sig=>root

abstract type AbstractMethodInvalidations end

struct MethodInvalidations <: AbstractMethodInvalidations
    method::Union{Method, Binding, Nothing}
    reason::Symbol   # :inserting, :deleting, or :rebinding
    mt_backedges::Vector{BackedgeMT}
    backedges::Vector{InstanceNode}
    mt_cache::Vector{MethodInstance}
    mt_disable::Vector{MethodInstance}
end
methinv_storage() = Pair{Type,InstanceNode}[], InstanceNode[], MethodInstance[], MethodInstance[]
function MethodInvalidations(method, reason::Symbol)
    MethodInvalidations(method, reason, methinv_storage()...)
end

Base.isempty(methinvs::MethodInvalidations) = isempty(methinvs.mt_backedges) && isempty(methinvs.backedges)  # ignore mt_cache

function Base.:(==)(methinvs1::MethodInvalidations, methinvs2::MethodInvalidations)
    methinvs1.method == methinvs2.method || return false
    methinvs1.reason == methinvs2.reason || return false
    methinvs1.mt_backedges == methinvs2.mt_backedges || return false
    methinvs1.backedges == methinvs2.backedges || return false
    methinvs1.mt_cache == methinvs2.mt_cache || return false
    methinvs1.mt_disable == methinvs2.mt_disable || return false
    return true
end

countchildren(sigtree::BackedgeMT) = countchildren(sigtree.second)
countchildren(::MethodInstance) = 1

countchildren(mmi::AbstractMethodInvalidations) = sum(countchildren, mmi.backedges; init=0) + sum(countchildren, mmi.mt_backedges; init=0)

function Base.sort!(methinvs::AbstractMethodInvalidations)
    sort!(methinvs.mt_backedges; by=countchildren)
    sort!(methinvs.backedges; by=countchildren)
    # recursive
    for (sig, root) in methinvs.mt_backedges
        sort!(root)
    end
    for root in methinvs.backedges
        sort!(root)
    end
    return methinvs
end

# We could use AbstractTrees here, but typically one is not interested in the full tree,
# just the top method and the number of children it has
function Base.show(io::IO, methinvs::MethodInvalidations)
    iscompact = get(io, :compact, false)::Bool

    print(io, methinvs.reason, " ")
    printstyled(io, methinvs.method, color = :light_magenta)
    println(io, " invalidated:")
    indent = iscompact ? "" : "   "
    if !isempty(methinvs.mt_backedges)
        print(io, indent, "mt_backedges: ")
        showlist(io, methinvs.mt_backedges, length(indent)+length("mt_backedges")+2)
    end
    if !isempty(methinvs.backedges)
        print(io, indent, "backedges: ")
        showlist(io, methinvs.backedges, length(indent)+length("backedges")+2)
    end
    if !isempty(methinvs.mt_disable)
        print(io, indent, "mt_disable: ")
        println(io, first(methinvs.mt_disable))
        if length(methinvs.mt_disable) > 1
            println(io, indent, " "^12, "+", length(methinvs.mt_disable)-1, " more")
        end
    end
    if !isempty(methinvs.mt_cache)
        println(io, indent, length(methinvs.mt_cache), " mt_cache")
    end
    iscompact && print(io, ';')
end

function showlist(io::IO, treelist, indent::Int=0)
    iscompact = get(io, :compact, false)::Bool

    n = length(treelist)
    nd = ndigits(n)
    for i = 1:n
        print(io, lpad(i, nd), ": ")
        root = treelist[i]
        sig = nothing
        if isa(root, Pair)
            print(io, "signature ")
            sig = root.first
            if isa(sig, MethodInstance)
                # "insert_backedges_callee"/"insert_backedges" (delayed) invalidations
                printstyled(io, try which(sig.specTypes) catch _ "(unavailable)" end, color = :light_cyan)
                print(io, " (formerly ", sig.def, ')')
            elseif isa(sig, Binding)
                printstyled(io, sig.globalref, color = :light_red)
            else
                # `sig` (immediate) invalidations
                printstyled(io, sig, color = :light_cyan)
            end
            print(io, " triggered ")
            sig = root.first
            root = root.second
        elseif isa(root, Tuple)
            printstyled(IOContext(io, :showchildren=>false), root[end-1], color = :light_yellow)
            print(io, " blocked ")
            printdata(io, root[end])
            root = nothing
        else
            print(io, "superseding ")
            printstyled(io, convert(MethodInstance, root).def , color = :light_cyan)
            print(io, " with ")
            sig = root.mi.def.sig
        end
        if root !== nothing
            printstyled(io, convert(MethodInstance, root), color = :light_yellow)
            print(io, " (", countchildren(root), " children)")
        end
        if iscompact
            i < n && print(io, ", ")
        else
            print(io, '\n')
            i < n && print(io, " "^indent)
        end
    end
end

new_backedge_table() = Dict{Union{Int32,MethodInstance},Union{Tuple{Any,Vector{Any}},InstanceNode}}()

"""
    report_invalidations(
        io::IO = stdout;
        invalidations,
        n_rows::Int = 10,
        process_filename::Function = x -> x,
    )

Print a tabular summary of invalidations given:

 - `invalidations` the output of [`SnoopCompileCore.@snoop_invalidations`](@ref)

and (optionally)

 - `io::IO` IO stream. Defaults to `stdout`
 - `n_rows::Int` the number of rows to be displayed in the
   truncated table. A value of 0 indicates no truncation.
   A positive value will truncate the table to the specified
   number of rows.
 - `process_filename(::String)::String` a function to post-process
   each filename, where invalidations are found

# Example usage

```julia
import SnoopCompileCore
invalidations = SnoopCompileCore.@snoop_invalidations begin

    # load packages & define any additional methods

end;

using SnoopCompile
using PrettyTables # to load report_invalidations
report_invalidations(;invalidations)
```

Using `report_invalidations` requires that you first load the `PrettyTables.jl` package.
"""
function report_invalidations end

function invalidation_trees_logmeths(list; exclude_corecompiler::Bool=true)
    methodinvs = MethodInvalidations[]
    mt_backedges, backedges, mt_cache, mt_disable = methinv_storage()
    reason = parent = nothing
    i = 0
    while i < length(list)
        item = list[i+=1]
        if isa(item, MethodInstance)
            mi = item
            item = list[i+=1]
            if isa(item, Int32)
                depth = item
                if iszero(depth)
                    # starting a new mt_backedges
                    @assert parent === nothing  # these should come first in each Method-block
                    parent = InstanceNode(mi, depth)
                elseif depth == Int32(1)
                    if parent === nothing
                        parent = InstanceNode(mi, depth)  # starts a new backedge
                    else
                        parent = InstanceNode(mi, getroot(parent), depth)  # attaches to the current root
                    end
                else
                    @assert parent !== nothing
                    while depth < parent.depth + 1 # && isdefined(parent, :parent)
                        parent = parent.parent
                    end
                    parent = InstanceNode(mi, parent, depth)
                end
            elseif isa(item, String)
                if item == "invalidate_mt_cache"
                    push!(mt_cache, mi)
                else
                    # finish a backedges
                    reason = checkreason(reason, item)
                    if parent !== nothing
                        @assert isdummy(getroot(parent))
                    end
                    root = parent === nothing ? InstanceNode(mi, 0) : InstanceNode(mi, getroot(parent).children)
                    push!(backedges, root)
                    parent = nothing
                end
            end
        elseif isa(item, Type) && item <: Tuple
            # finish an mt_backedges
            rootsig = item
            root = getroot(parent)
            @assert !isdummy(root)
            push!(mt_backedges, rootsig=>root)
            parent = nothing
        elseif isa(item, Method)
            meth = item
            item = list[i+=1]
            @assert isa(item, String)
            reason = checkreason(reason, item)
            methinv = MethodInvalidations(meth, reason, mt_backedges, backedges, mt_cache, mt_disable)
            push!(methodinvs, methinv)
            parent = reason = nothing
            mt_backedges, backedges, mt_cache, mt_disable = methinv_storage()
        end
    end
    return methodinvs
end

const EdgeNodeType = Union{DataType, Binding, MethodInstance, CodeInstance}

struct MultiMethodInvalidations <: AbstractMethodInvalidations
    methods::Union{Binding,Vector{Method}}
    reason::Symbol   # :inserting, :deleting, or :rebinding
    mt_backedges::Vector{BackedgeMT}
    backedges::Vector{InstanceNode}
end
MultiMethodInvalidations(methods, reason) = MultiMethodInvalidations(methods, reason, BackedgeMT[], InstanceNode[])

function Base.show(io::IO, methinvs::MultiMethodInvalidations)
    iscompact = get(io, :compact, false)::Bool

    print(io, "Invalidating methods: ")
    ms = methinvs.methods
    if isa(ms, Vector{Method})
        firstm = true
        for m in methinvs.methods
            firstm || print(io, ", ")
            printstyled(io, m, color = :light_magenta)
            firstm = false
        end
    else
        printstyled(io, ms.globalref, color = :light_red)
    end
    println(io)
    indent = iscompact ? "" : "   "
    if !isempty(methinvs.mt_backedges)
        print(io, indent, "mt_backedges: ")
        showlist(io, methinvs.mt_backedges, length(indent)+length("mt_backedges")+2)
    end
    if !isempty(methinvs.backedges)
        print(io, indent, "backedges: ")
        showlist(io, methinvs.backedges, length(indent)+length("backedges")+2)
    end
    iscompact && print(io, ';')
end

Base.isempty(methinvs::MultiMethodInvalidations) = isempty(methinvs.backedges) && isempty(methinvs.mt_backedges)

function invalidation_trees_logedges(list; exclude_corecompiler::Bool=true)
    mminvs = MultiMethodInvalidations[]
    mmibad = MultiMethodInvalidations(Method[], :unknown)
    calleedict = Dict{Union{CodeInstance,MethodInstance},InstanceNode}()

    i, mmi = 0, nothing
    while i + 2 < length(list)
        tag = list[i+2]::String
        if tag == "method_globalref"
            def, target = list[i+1]::Method, list[i+3]::CodeInstance
            i += 4
            error("implement me")
        elseif tag == "insert_backedges_callee"
            edge, target, matches = list[i+1]::EdgeNodeType, list[i+3]::CodeInstance, list[i+4]::Vector{Any}
            i += 4
            reason = !isempty(matches) ? :inserting :
                     isa(edge, Binding) ? :rebinding : :deleting
            matches = reason === :rebinding ? edge : convert(Vector{Method}, matches)
            mmi = MultiMethodInvalidations(matches, reason)
            push!(mminvs, mmi)
            if edge isa Type || edge isa Binding
                node = InstanceNode(target, 0)
                calleedict[target] = node
                push!(mmi.mt_backedges, edge=>node)
            else
                root = get(calleedict, edge, nothing)
                if root === nothing
                    root = InstanceNode(edge, 0)
                    push!(mmi.backedges, root)
                    calleedict[edge] = root
                end
                node = InstanceNode(target, root)
                calleedict[target] = node
            end
        elseif tag == "verify_methods"
            caller, callee = list[i+1]::CodeInstance, list[i+3]::CodeInstance
            i += 3
            caller == callee && continue
            node = get(calleedict, callee, nothing)
            if node === nothing
                node = InstanceNode(callee, 0)
                push!(mmibad.backedges, node)
                calleedict[callee] = node
            end
            node = InstanceNode(caller, node)
            calleedict[caller] = node
        else
            error("tag ", tag, " unknown")
        end
    end
    if !isempty(mmibad)
        push!(mminvs, mmibad)
    end
    sort!(mminvs; by=countchildren)
    return mminvs
end

"""
    trees = invalidation_trees(list; consolidate=true)

Parse `list`, as captured by [`SnoopCompileCore.@snoop_invalidations`](@ref),
into a set of invalidation trees, where parents nodes were called by their
children.

# Example

```julia
julia> f(x::Int)  = 1
f (generic function with 1 method)

julia> f(x::Bool) = 2
f (generic function with 2 methods)

julia> applyf(container) = f(container[1])
applyf (generic function with 1 method)

julia> callapplyf(container) = applyf(container)
callapplyf (generic function with 1 method)

julia> c = Any[1]
1-element Array{Any,1}:
 1

julia> callapplyf(c)
1

julia> trees = invalidation_trees(@snoop_invalidations f(::AbstractFloat) = 3)
1-element Array{SnoopCompile.MethodInvalidations,1}:
 inserting f(::AbstractFloat) in Main at REPL[36]:1 invalidated:
   mt_backedges: 1: signature Tuple{typeof(f),Any} triggered MethodInstance for applyf(::Array{Any,1}) (1 children) more specific
```

There are two sources of invalidation: method insertion/deletion (new code
invalidating old code) and edge validation (package import validating against
the existing session). By default, these two are combined into a single set of
trees, but you can disable this by passing `consolidate=false`. One potential
advantage of not consolidating is that edge-validation can bundle multiple
methods together into a single invalidation tree, which might reduce the number
of trees if a package creates many methods for a single function.

For more information, see the tutorials in the online documentation.
"""
function invalidation_trees(list::InvalidationLists; consolidate::Bool=true, kwargs...)
    mtrees = invalidation_trees_logmeths(list.logmeths; kwargs...)
    etrees = invalidation_trees_logedges(list.logedges; kwargs...)
    if !consolidate
        trees = [mtrees; etrees]
    else
        trees = mtrees
        mindex = Dict{Union{Method,Binding},Int}(tree.method => i for (i, tree) in enumerate(mtrees))  # map method to index in mtrees
        for etree in etrees
            if etree.reason === :unknown
                push!(trees, MethodInvalidations(
                        nothing,
                        :unknown,
                        etree.mt_backedges,
                        etree.backedges,
                        MethodInstance[],  # mt_cache
                        MethodInstance[]   # mt_disable
                    ))
                continue
            end
            if etree.reason === :deleting
                @assert isempty(etree.backedges)  # should not have any backedges
                # Determine whether any of the deleted methods cover this
                covered = false
                for (edge, node) in etree.mt_backedges
                    for mtree in mtrees
                        mtree.reason === :deleting || continue
                        isnothing(mtree.method) && continue
                        mtree.method.sig <: edge || continue
                        # This edge is covered by the deleted method
                        join_invalidations!(mtree.mt_backedges, edge => node)
                        covered = true
                    end
                    covered && continue
                    # Try to find a deleted method that's applicable
                    # The challenge is we don't know any world information
                    methodtable = @static isdefinedglobal(Core, :methodtable) ? Core.methodtable : Core.GlobalMethods
                    methmatches = Method[]
                    Base.visit(methodtable) do m
                        if iszero(m.dispatch_status) && m.sig <: edge
                            push!(methmatches, m)
                        end
                    end
                    m = length(methmatches) == 1 ? first(methmatches) : nothing
                    push!(trees, MethodInvalidations(
                        m,
                        :deleting,
                        BackedgeMT[edge => node],
                        InstanceNode[],  # backedges
                        MethodInstance[],  # mt_cache
                        MethodInstance[]   # mt_disable
                    ))
                end
            end
            methods = etree.methods
            if isa(methods, Vector{Method})
                for method in methods
                    # Check if this method already exists in mtrees
                    idx = get(mindex, method, nothing)
                    if idx !== nothing
                        # Merge the trees
                        join_invalidations!(trees[idx].mt_backedges, etree.mt_backedges)
                        join_invalidations!(trees[idx].backedges, etree.backedges)
                    else
                        # Otherwise just add it to the list
                        push!(trees, MethodInvalidations(
                            method,
                            :inserting,
                            copy(etree.mt_backedges),
                            copy(etree.backedges),
                            MethodInstance[],  # mt_cache
                            MethodInstance[]   # mt_disable
                        ))
                        mindex[method] = length(trees)
                    end
                end
            else
                b = methods::Binding
                idx = get(mindex, b, nothing)
                if idx !== nothing
                    # Merge the trees
                    join_invalidations!(trees[idx].mt_backedges, etree.mt_backedges)
                    join_invalidations!(trees[idx].backedges, etree.backedges)
                else
                    # Otherwise just add it to the list
                    push!(trees, MethodInvalidations(
                        b,
                        :rebinding,
                        copy(etree.mt_backedges),
                        copy(etree.backedges),
                        MethodInstance[],  # mt_cache
                        MethodInstance[]   # mt_disable
                    ))
                    mindex[b] = length(trees)
                end
            end
        end
    end
    for tree in trees
        sort!(tree)
    end
    sort!(trees; by=countchildren)
    return trees
end

# These make testing a lot easier
function firstmatch(trees::AbstractVector{MethodInvalidations}, m::Method)
    for tree in trees
        tree.method === m && return tree
    end
    error("no tree found for method ", m)
end

function firstmatch(mt_backedges::AbstractVector{BackedgeMT}, @nospecialize(sig::Type))
    for (_sig, root) in mt_backedges
        _sig === sig && return sig, root
    end
    error("no root found for signature ", sig)
end

function firstmatch(backedges::AbstractVector{InstanceNode}, mi::MethodInstance)
    for root in backedges
        root.mi === mi && return root
    end
    error("no node found for MethodInstance ", mi)
end

function firstmatch(backedges::AbstractVector{InstanceNode}, @nospecialize(sig::Type))
    for root in backedges
        root.mi.specTypes === sig && return root
    end
    error("no node found for signature ", sig)
end

function firstmatch(backedges::AbstractVector{InstanceNode}, m::Method)
    for root in backedges
        root.mi.def === m && return root
    end
    error("no node found for Method ", m)
end

function add_method_trigger!(methodinvs, method::Method, reason::Symbol, mt_backedges, backedges, mt_cache, mt_disable)
    found = false
    for tree in methodinvs
        if tree.method == method && tree.reason == reason
            join_invalidations!(tree.mt_backedges, mt_backedges)
            join_invalidations!(tree.backedges, backedges)
            append!(tree.mt_cache, mt_cache)
            append!(tree.mt_disable, mt_disable)
            found = true
            break
        end
    end
    found || push!(methodinvs, sort!(MethodInvalidations(method, reason, mt_backedges, backedges, mt_cache, mt_disable)))
    return methodinvs
end

# for backedges
function join_invalidations!(list::AbstractVector{InstanceNode}, items::AbstractVector{InstanceNode}, depth=Int32(1))
    for node in items
        if node.depth == 0 || node.mi === dummyinstance
            node ∉ list && push!(list, node)
            continue
        end
        @assert node.depth == depth
        mi = node.mi
        found = false
        for parent in list
            mi2 = parent.mi
            if mi2 == mi
                join_invalidations!(parent.children, node.children, depth+Int32(1))
                found = true
                break
            end
        end
        if !found
            adjust_depth!(node, -depth+Int32(1))
            push!(list, node)
        end
    end
    return list
end

# for mt_backedges
function join_invalidations!(list::AbstractVector{<:Pair}, items::AbstractVector{<:Pair})
    for (key, root) in items
        found = false
        node, mi = isa(root, MethodInstance) ? (InstanceNode(root, 0), root) : (root, root.mi)
        for (key2, root2) in list
            key2 == key || continue
            mi2 = root2.mi
            if mi2 == mi
                # Find the first branch that isn't shared
                join_branches!(node, root2)
                found = true
                break
            end
        end
        found || push!(list, key => node)
    end
    return list
end

function join_branches!(to, from)
    for cfrom in from.children
        found = false
        for cto in to.children
            if cfrom.mi == cto.mi
                join_branches!(cto, cfrom)
                found = true
                break
            end
        end
        found || push!(to.children, cfrom)
    end
    return to
end

function checkreason(reason, loctag)
    if loctag == "jl_method_table_disable"
        @assert reason === nothing || reason === :deleting
        reason = :deleting
    elseif loctag == "jl_method_table_insert"
        @assert reason === nothing || reason === :inserting
        reason = :inserting
    else
        error("unexpected reason ", loctag)
    end
    return reason
end

"""
    thinned = filtermod(module, trees::AbstractVector{MethodInvalidations}; recursive=false)

Select just the cases of invalidating a method defined in `module`.

If `recursive` is false, only the roots of trees are examined (i.e., the proximal source of
the invalidation must be in `module`). If `recursive` is true, then `thinned` contains
all routes to a method in `module`.
"""
function filtermod(mod::Module, trees::AbstractVector{MethodInvalidations}; kwargs...)
    # We don't just broadcast because we want to filter at all levels
    thinned = MethodInvalidations[]
    for methinvs in trees
        _invs = filtermod(mod, methinvs; kwargs...)
        isempty(_invs) || push!(thinned, _invs)
    end
    return sort!(thinned; by=countchildren)
end

hasmod(mod::Module, node::InstanceNode) = hasmod(mod, MethodInstance(node))
hasmod(mod::Module, mi::MethodInstance) = mi.def.module === mod

function filtermod(mod::Module, methinvs::MethodInvalidations; recursive::Bool=false)
    if recursive
        out = MethodInvalidations(methinvs.method, methinvs.reason)
        for (sig, node) in methinvs.mt_backedges
            newnode = filtermod(mod, node)
            if newnode !== nothing
                push!(out.mt_backedges, sig => newnode)
            end
        end
        for node in methinvs.backedges
            newnode = filtermod(mod, node)
            if newnode !== nothing
                push!(out.backedges, newnode)
            end
        end
        return out
    end
    mt_backedges = filter(pr->hasmod(mod, pr.second), methinvs.mt_backedges)
    backedges = filter(root->hasmod(mod, root), methinvs.backedges)
    return MethodInvalidations(methinvs.method, methinvs.reason, mt_backedges, backedges,
                               copy(methinvs.mt_cache), copy(methinvs.mt_disable))
end

function filterbranch(f, node::InstanceNode, storage=nothing)
    if !isempty(node.children)
        newchildren = InstanceNode[]
        for child in node.children
            newchild = filterbranch(f, child, storage)
            if newchild !== nothing
                push!(newchildren, newchild)
            end
        end
        if !isempty(newchildren)
            newnode = InstanceNode(node, newchildren)
            for child in newchildren
                child.parent = newnode
            end
            return newnode
        end
    end
    if f(node)
        storage !== nothing && push!(storage, convert(eltype(storage), node))
        return copybranch(node)
    end
    return nothing
end
function filterbranch(f, node::MethodInstance, storage=nothing)
    if f(node)
        storage !== nothing && push!(storage, convert(eltype(storage), node))
        return node
    end
    return nothing
end

filtermod(mod::Module, node::InstanceNode) = filterbranch(n -> hasmod(mod, n), node)

function filtermod(mod::Module, mi::MethodInstance)
    m = mi.def
    if isa(m, Method)
        return m.module == mod ? mi : nothing
    end
    return m == mod ? mi : nothing
end

"""
    methinvs = findcaller(method::Method, trees)

Find a path through `trees` that reaches `method`. Returns a single `MethodInvalidations` object.

# Examples

Suppose you know that loading package `SomePkg` triggers invalidation of `f(data)`.
You can find the specific source of invalidation as follows:

```
f(data)                             # run once to force compilation
m = @which f(data)
using SnoopCompile
trees = invalidation_trees(@snoop_invalidations using SomePkg)
methinvs = findcaller(m, trees)
```

If you don't know which method to look for, but know some operation that has had added latency,
you can look for methods using `@snoopi`. For example, suppose that loading `SomePkg` makes the
next `using` statement slow. You can find the source of trouble with

```
julia> using SnoopCompile

julia> trees = invalidation_trees(@snoop_invalidations using SomePkg);

julia> tinf = @snoopi using SomePkg            # this second `using` will need to recompile code invalidated above
1-element Array{Tuple{Float64,Core.MethodInstance},1}:
 (0.08518409729003906, MethodInstance for require(::Module, ::Symbol))

julia> m = tinf[1][2].def
require(into::Module, mod::Symbol) in Base at loading.jl:887

julia> findcaller(m, trees)
inserting ==(x, y::SomeType) in SomeOtherPkg at /path/to/code:100 invalidated:
   backedges: 1: superseding ==(x, y) in Base at operators.jl:83 with MethodInstance for ==(::Symbol, ::Any) (16 children) more specific
```
"""
function findcaller(meth::Method, trees::AbstractVector{MethodInvalidations})
    for methinvs in trees
        ret = findcaller(meth, methinvs)
        ret === nothing || return ret
    end
    return nothing
end

function findcaller(meth::Method, methinvs::MethodInvalidations)
    function newtree(vectree)
        root0 = pop!(vectree)
        root = InstanceNode(root0.mi, root0.depth)
        return newtree!(root, vectree)
    end
    function newtree!(parent, vectree)
        isempty(vectree) && return getroot(parent)
        child = pop!(vectree)
        newchild = InstanceNode(child.mi, parent, child.depth)   # prune all branches except the one leading through child.mi
        return newtree!(newchild, vectree)
    end

    for (sig, node) in methinvs.mt_backedges
        ret = findcaller(meth, node)
        ret === nothing && continue
        return MethodInvalidations(methinvs.method, methinvs.reason, [Pair{Any,InstanceNode}(sig, newtree(ret))], InstanceNode[],
                                   copy(methinvs.mt_cache), copy(methinvs.mt_disable))
    end
    for node in methinvs.backedges
        ret = findcaller(meth, node)
        ret === nothing && continue
        return MethodInvalidations(methinvs.method, methinvs.reason, Pair{Any,InstanceNode}[], [newtree(ret)],
                                   copy(methinvs.mt_cache), copy(methinvs.mt_disable))
    end
    return nothing
end

function findcaller(meth::Method, node::InstanceNode)
    meth === node.mi.def && return [node]
    for child in node.children
        ret = findcaller(meth, child)
        if ret !== nothing
            push!(ret, node)
            return ret
        end
    end
    return nothing
end

findcaller(meth::Method, mi::MethodInstance) = mi.def == meth ? mi : nothing
