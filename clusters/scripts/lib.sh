# shellcheck shell=bash
# Shared helpers for bootstrap.sh and destroy.sh. Meant to be sourced, not executed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Path of the flux entrypoints, both relative to the repo root -- which is what
# flux bootstrap --path wants -- and absolute, for walking it locally.
entrypoints_path="clusters/entrypoints"
entrypoints_dir="$repo_root/$entrypoints_path"

# Every clusters/entrypoints/<cluster> directory is a target, printed in the
# form the scripts take as their argument.
discover_targets() {
    local cluster_dir
    for cluster_dir in "$entrypoints_dir"/*/; do
        [[ -d "$cluster_dir" ]] || continue
        basename "$cluster_dir"
    done
}

select_target() {
    local prompt="$1" targets
    targets="$(discover_targets)"

    if [[ -z "$targets" ]]; then
        printf 'error: no targets found under %s\n' "$entrypoints_dir" >&2
        return 1
    fi

    fzf --prompt="$prompt > " --height='~40%' --no-multi <<<"$targets"
}

# Turns a <cluster> argument -- or an interactive pick when it is omitted --
# into the cluster and cluster_kubeconfig the scripts run against.
resolve_target() {
    local arg="$1" prompt="$2" cluster_env

    if [[ -n "$arg" ]]; then
        cluster="$arg"
    else
        cluster="$(select_target "$prompt")" || true
        if [[ -z "$cluster" ]]; then
            printf 'usage: %s <cluster>\n' "$0" >&2
            exit 1
        fi
    fi

    cluster_env="KUBECONFIG_PATH_${cluster//-/_}"
    cluster_kubeconfig="${!cluster_env:-}"

    if [[ -z "$cluster_kubeconfig" ]]; then
        printf 'error: %s is not set (kubeconfig path for cluster %q)\n' "$cluster_env" "$cluster" >&2
        exit 1
    fi
    if [[ ! -f "$cluster_kubeconfig" ]]; then
        printf 'error: kubeconfig for %q not found at %s\n' "$cluster" "$cluster_kubeconfig" >&2
        exit 1
    fi
}

# Prints the "<owner> <repository> <branch>" flux bootstrap pushes to: owner and
# repository off the origin remote, in either the git@github.com:owner/repo.git
# or the https://github.com/owner/repo.git form, and the branch this working
# tree is on. Read it back with:
#   read -r owner repository branch <<<"$(resolve_origin)"
resolve_origin() {
    local url path owner repository branch

    url="$(git -C "$repo_root" remote get-url origin)" || return 1

    if [[ "$url" != *github.com* ]]; then
        printf 'error: origin %q is not a github.com remote, which flux bootstrap github requires\n' "$url" >&2
        return 1
    fi

    path="${url#*github.com}"   # drop the scheme and host
    path="${path#[:/]}"         # scp-like uses ':', url form uses '/'
    path="${path%.git}"

    owner="${path%%/*}"
    repository="${path#*/}"

    if [[ -z "$owner" || -z "$repository" || "$repository" == */* || "$owner" == "$repository" ]]; then
        printf 'error: cannot read owner/repository out of origin url %q\n' "$url" >&2
        return 1
    fi

    branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)" || return 1

    if [[ -z "$branch" || "$branch" == HEAD ]]; then
        printf 'error: cannot determine the current branch of %s (detached HEAD?)\n' "$repo_root" >&2
        return 1
    fi

    printf '%s %s %s\n' "$owner" "$repository" "$branch"
}

log() {
    printf '==> %s\n' "$*"
}

# Both scripts talk to the cluster resolve_target picked, never to the ambient
# kubeconfig context.
kc() {
    kubectl --kubeconfig="$cluster_kubeconfig" "$@"
}

fx() {
    flux --kubeconfig="$cluster_kubeconfig" "$@"
}
