module SCPrettyTablesExt

using SnoopCompile
using SnoopCompile: countchildren
import PrettyTables

function SnoopCompile.report_invalidations(io::IO = stdout;
        invalidations,
        n_rows::Int = 10,
        process_filename::Function = x -> x,
    )
    @assert n_rows ≥ 0
    trees = reverse(invalidation_trees(invalidations))
    n_total_invalidations = length(uinvalidated(invalidations))
    # TODO: Merge `@info` statement with one below
    invs_per_method = map(trees) do methinvs
        countchildren(methinvs)
    end
    n_invs_total = length(invs_per_method)
    if n_invs_total == 0
        @info "Zero invalidations! 🎉"
        return nothing
    end
    nr = n_rows == 0 ? n_invs_total : n_rows
    truncated_invs = nr < n_invs_total
    sum_invs = sum(invs_per_method)
    invs_per_method = invs_per_method[1:min(nr, n_invs_total)]
    trees = trees[1:min(nr, n_invs_total)]
    trunc_msg = truncated_invs ? " (showing $nr functions) " : ""
    @info "$n_total_invalidations methods invalidated for $n_invs_total functions$trunc_msg"
    n_invalidations_percent = map(invs_per_method) do inv
        Float16(100 * inv / sum_invs)
    end
    meth_name = map(trees) do inv
        isnothing(inv.method) ? "unknown" : "$(inv.method.name)"
    end
    fileinfo = map(trees) do inv
        isnothing(inv.method) ? "unknown" : "$(process_filename(string(inv.method.file))):$(inv.method.line)"
    end

    table_data = hcat(
        fileinfo,
        meth_name,
        invs_per_method,
        n_invalidations_percent,
    )

    @static if pkgversion(PrettyTables).major == 2
        header = (
            ["<file name>:<line number>", "Function Name", "Invalidations", "Invalidations %"],
            ["", "", "", "(xᵢ/∑x)"],
        )

        PrettyTables.pretty_table(
            io,
            table_data;
            header,
            formatters = PrettyTables.ft_printf("%s", 2:2),
            header_crayon = PrettyTables.crayon"yellow bold",
            subheader_crayon = PrettyTables.crayon"green bold",
            crop = :none,
            alignment = [:l, :c, :c, :c],
        )
    else
        column_labels = [
            ["<file name>:<line number>", "Function Name", "Invalidations", "Invalidations %"],
            ["", "", "", "(xᵢ/∑x)"],
        ]

        style = PrettyTables.TextTableStyle(
            first_line_column_label = PrettyTables.crayon"yellow bold",
            column_label = PrettyTables.crayon"green bold",
        )

        PrettyTables.pretty_table(
            io,
            table_data;
            column_labels,
            alignment = [:l, :c, :c, :c],
            fit_table_in_display_horizontally = false,
            fit_table_in_display_vertically = false,
            formatters = [PrettyTables.fmt__printf("%s", [2])],
            style
        )
    end
end

end
