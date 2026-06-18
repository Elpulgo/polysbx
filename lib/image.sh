# image.sh — assemble a concrete Dockerfile from the base template + the modules
# selected in config (languages + integrations). Pure bash so module fragments'
# backslash line-continuations survive (awk -v / sed would mangle them).
[[ -n "${_POLYSBX_IMAGE:-}" ]] && return 0
_POLYSBX_IMAGE=1

# Echo the ordered module list implied by the current config.
selected_modules() {
    local m
    for m in $LANGUAGES; do
        case "$m" in dotnet|go|python|rust) printf '%s\n' "$m" ;;
            *) die "unknown language module: $m" ;; esac
    done
    [[ "${ADO_ENABLED:-0}" == 1 ]] && printf '%s\n' azure-cli
    [[ "${GH_ENABLED:-0}"  == 1 ]] && printf '%s\n' gh
}

# assemble_dockerfile <base-template> <output-file>
# Replaces the marker line `# >>> POLYSBX_MODULES <<<` with the selected fragments.
assemble_dockerfile() {
    local tmpl="$1" out="$2" line m frag
    : > "$out"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *'# >>> POLYSBX_MODULES <<<'* ]]; then
            while IFS= read -r m; do
                [[ -z "$m" ]] && continue
                frag="$POLYSBX_ROOT/image/modules/$m.dockerfile"
                [[ -f "$frag" ]] || die "missing module fragment: $frag"
                printf '\n# ──── module: %s ────\n' "$m" >> "$out"
                cat "$frag" >> "$out"
                printf '\n' >> "$out"
            done < <(selected_modules)
        else
            printf '%s\n' "$line" >> "$out"
        fi
    done < "$tmpl"
}
