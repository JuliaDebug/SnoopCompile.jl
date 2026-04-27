module PkgF

using PkgE

# Transitive caller: calls PkgE.direct_caller. When PkgE.callee gets a more specific
# method and direct_caller's CI is C-level invalidated (max_world=0), loading this
# package triggers a verify_methods logedge entry with direct_caller as the cause.
transitive_caller(x::Integer) = PkgE.direct_caller(x)

precompile(transitive_caller, (Int,))

end # module PkgF
