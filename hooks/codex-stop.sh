#!/usr/bin/env bash
# What:  user-level Codex Stop hook — runs a repository's own .quality/stop-validate.sh at turn
#        end, and only for a repository Codex itself treats as a trusted project.
# Where: NOT stamped. Installed once per machine: named by path from the user's own
#        $CODEX_HOME/hooks.json (README, "The Codex turn-end gate").
# Why:   Codex launches a hook with the TURN's working directory and tells it nothing about
#        which project its hooks file was loaded from, and a turn's working directory can be
#        any directory. A hook stamped into a project therefore cannot name that project's
#        script; it can only name "the script of whatever repository the turn stands in". A
#        user-level hook has the same input, so the decision is made here, explicitly: the
#        repository holding the payload's `cwd` must be trusted in the user's Codex config,
#        which that repository cannot write.
#
# Trust is resolved the way Codex resolves it. Read at openai/codex tag rust-v0.162.1:
#   - codex-rs/config/src/loader/mod.rs — find_git_checkout_root, discover_project_root,
#     normalized_project_trust_keys, ProjectTrustContext::decision_for_dir
#   - codex-rs/git-utils/src/trust.rs — resolve_root_git_project_for_trust
# That is: the checkout is the nearest ancestor of `cwd` holding a `.git` entry (a `.git`
# directory with no HEAD is skipped). Its trust is the FIRST `[projects."<key>"]` entry
# carrying a trust_level among: the checkout's canonical path, its path as spelled, and then
# the same two for its main checkout when it is a linked worktree. First match wins, so an
# explicit "untrusted" on a worktree is honoured over a trusted main checkout. A linked
# worktree maps to its main checkout only when the registration under
# <main>/.git/worktrees/<name>/ points back at this checkout and the main checkout owns that
# git directory — files the candidate directory does not control. No git executable is run and
# nothing the candidate says about itself (config, remote, `core.worktree`) is consulted.
# The bound is Codex's own: a writable path that a trusted repository still has registered as
# a worktree counts as that repository.
#
# Narrower than Codex in three places, each of which leaves the gate OFF, never on:
#   - only $CODEX_HOME/config.toml is read. Trust granted by a `-c` override, a managed or a
#     system config layer is invisible here.
#   - a non-default `project_root_markers` is ignored; `.git` is the only marker.
#   - a trust entry on a subdirectory of a checkout is not looked up.
#
# It delegates. stop-validate.sh owns the whole policy (which tree, docs-only skip, runner,
# `exit 2` + stderr as the block protocol, the stop_hook_active release); its exit status and
# stderr pass through untouched. This file only decides whether to run it.
#
# Fail-open on this wrapper's own uncertainty — an unparseable payload, no usable cwd, an
# unreadable config, no Python 3.11 (tomllib): exit 0. Blocking there would wedge every turn
# in every directory on the machine, and pre-commit and CI still gate behind this hook.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"

# `python3 -I`, and the reason is the working directory: `python3 -c` puts the process cwd
# first on sys.path, and this process's cwd is the turn's — the directory not yet judged.
# Isolated mode leaves it (and PYTHON* variables, and user site-packages) out.
read -r -d '' RESOLVE <<'PY' || true
import json, os, sys, tomllib

LIMIT = 64 * 1024  # trust.rs MAX_GIT_METADATA_FILE_BYTES


def canon(path):
    try:
        return os.path.realpath(path, strict=True)
    except OSError:
        return None


def checkout_root(cwd):
    """Nearest ancestor holding a `.git` entry; a `.git` directory without HEAD is not one."""
    here = cwd if os.path.isdir(cwd) else os.path.dirname(cwd)
    while True:
        dot_git = os.path.join(here, ".git")
        if os.path.exists(dot_git) and not (
            os.path.isdir(dot_git) and not os.path.exists(os.path.join(dot_git, "HEAD"))
        ):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def metadata_file(path):
    """Bytes of a small regular file that is not a symlink, else None."""
    try:
        if os.path.islink(path) or not os.path.isfile(path) or os.path.getsize(path) > LIMIT:
            return None
        with open(path, "rb") as handle:
            data = handle.read(LIMIT + 1)
    except OSError:
        return None
    return data if len(data) <= LIMIT else None


def gitdir_pointer(path):
    """Target of a `gitdir: <path>` file, resolved against the file's directory."""
    data = metadata_file(path)
    if data is None or not data.strip().startswith(b"gitdir:"):
        return None
    target = data.strip()[len(b"gitdir:"):].strip()
    if not target:
        return None
    return os.path.normpath(os.path.join(os.path.dirname(path), os.fsdecode(target)))


def main_checkout(root):
    """`root` itself for a primary checkout, its main checkout for a linked worktree whose
    registration validates both ways, None for anything else (a submodule included)."""
    dot_git = os.path.join(root, ".git")
    if os.path.isdir(dot_git):
        return root
    git_dir = gitdir_pointer(dot_git)
    if git_dir is None or os.path.islink(git_dir) or not os.path.isdir(git_dir):
        return None
    real_git_dir = canon(git_dir)
    if real_git_dir is None:
        return None
    worktrees = os.path.dirname(real_git_dir)
    if os.path.basename(worktrees) != "worktrees":
        return None
    common = os.path.dirname(worktrees)
    back = metadata_file(os.path.join(real_git_dir, "gitdir"))
    commondir = metadata_file(os.path.join(real_git_dir, "commondir"))
    if back is None or commondir is None or not back.strip() or not commondir.strip():
        return None
    # The registration must name THIS checkout's .git, and its commondir the same common dir.
    registered = os.path.normpath(os.path.join(real_git_dir, os.fsdecode(back.strip())))
    if os.path.basename(registered) != ".git":
        return None
    here = canon(root)
    if here is None or canon(os.path.dirname(registered)) != here:
        return None
    if canon(os.path.join(real_git_dir, os.fsdecode(commondir.strip()))) != common:
        return None
    # The main checkout keeps the spelling the pointer used (it is the trust key), and must
    # itself own the common dir: directly, or through its own `gitdir:` file.
    main = os.path.dirname(os.path.dirname(os.path.dirname(git_dir)))
    main_dot_git = os.path.join(main, ".git")
    main_git_dir = main_dot_git if os.path.isdir(main_dot_git) else gitdir_pointer(main_dot_git)
    if main_git_dir is None or canon(main_git_dir) != common:
        return None
    return main


def keys(path):
    """Canonical spelling first, then the spelling as given, as Codex looks them up."""
    real = canon(path)
    return [path] if real is None or real == path else [real, path]


try:
    cwd = json.load(sys.stdin).get("cwd")
except Exception:
    sys.exit(1)
if not isinstance(cwd, str) or not os.path.isabs(cwd):
    sys.exit(1)
root = checkout_root(os.path.normpath(cwd))
if root is None:
    sys.exit(1)

home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
try:
    with open(os.path.join(home, "config.toml"), "rb") as handle:
        projects = tomllib.load(handle).get("projects") or {}
    levels = {
        key: entry["trust_level"]
        for key, entry in projects.items()
        if isinstance(entry, dict) and entry.get("trust_level") is not None
    }
except Exception:
    sys.exit(1)

main = main_checkout(root)
candidates = keys(root) + (keys(main) if main is not None else [])
level = next((levels[key] for key in candidates if key in levels), None)
if level != "trusted":
    sys.exit(1)
print(root)
PY

root="$(printf '%s' "$payload" | python3 -I -c "$RESOLVE" 2>/dev/null)" || exit 0
[ -n "$root" ] && [ -d "$root" ] || exit 0

script="$root/.quality/stop-validate.sh"
# Both files: the script alone may be a stray copy, and .quality-kit.json alone is a stamped
# repository whose gate was removed. `-f` as well as `-r`, because a directory or FIFO at that
# path would pass a bare -r and then hang or fail under bash.
[ -f "$script" ] && [ -r "$script" ] && [ -f "$root/.quality-kit.json" ] || exit 0

# cd first, so the script's own git calls see the tree that was judged. A herestring, not a
# pipe: under pipefail a script that exits before draining stdin would turn its real status
# into the writer's 141, and that status is the block protocol.
(cd "$root" && exec bash "$script") <<<"$payload"
