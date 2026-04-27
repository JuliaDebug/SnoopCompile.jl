module PkgE

callee(x::Integer) = 0
# Direct caller of callee — precompiled so its CI is in memory when callee gets a more
# specific method inserted, triggering a C-level (logmeths) invalidation.
direct_caller(x::Integer) = callee(x)

precompile(direct_caller, (Int,))

end # module PkgE
