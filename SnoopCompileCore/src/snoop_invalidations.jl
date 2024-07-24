export @snoop_invalidations

"""
    invs = @snoop_invalidations expr

Capture method cache invalidations triggered by evaluating `expr`.
`invs` is a sequence of invalidated `Core.MethodInstance`s together with "explanations," consisting
of integers (encoding depth) and strings (documenting the source of an invalidation).

Unless you are working at a low level, you essentially always want to pass `invs`
directly to [`SnoopCompile.invalidation_trees`](@ref).

# Extended help

`invs` is in a format where the "reason" comes after the items.
Method deletion results in the sequence

    [zero or more (mi, "invalidate_mt_cache") pairs..., zero or more (depth1 tree, loctag) pairs..., method, loctag] with loctag = "jl_method_table_disable"

where `mi` means a `MethodInstance`. `depth1` means a sequence starting at `depth=1`.

Method insertion results in the sequence

    [zero or more (depth0 tree, sig) pairs..., same info as with delete_method except loctag = "jl_method_table_insert"]

The authoritative reference is Julia's own `src/gf.c` file.
"""
macro snoop_invalidations(expr)
    quote
        local invs = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
        Expr(:tryfinally,
            $(esc(expr)),
            ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
        )
        invs
    end
end
