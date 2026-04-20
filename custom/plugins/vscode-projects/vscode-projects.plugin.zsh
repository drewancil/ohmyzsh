#
# vscode-projects.plugin.zsh
# tab-completable launcher for VS Code Project Manager projects on macOS
# Enhanced with fzf TUI, colors, borders, and preview (inspired by zsh-ssh)
# Sagebrush Heavy Industries 2026

# default project manager storage location on macOS
# if you use Cursor or VSCodium, you can override VSCODE_PROJECTS_FILE in ~/.zshrc
: ${VSCODE_PROJECTS_FILE:="$HOME/Library/Application Support/Code/User/globalStorage/alefragnani.project-manager/projects.json"}

# Editor command to launch (override with VSCODE_PROJECTS_EDITOR)
: ${VSCODE_PROJECTS_EDITOR:=code}

# Write the preview helper script to a cache file so fzf can invoke it
# (fzf runs --preview in a plain sh subprocess that can't see zsh functions)
_VSCODE_PROJECTS_PREVIEW_SCRIPT="${ZSH_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/oh-my-zsh}/_vscode_project_preview.py"
command mkdir -p "${_VSCODE_PROJECTS_PREVIEW_SCRIPT:h}" 2>/dev/null
cat > "$_VSCODE_PROJECTS_PREVIEW_SCRIPT" <<'PREVIEW_PY'
#!/usr/bin/env python3
import json, sys, os
from datetime import datetime

CYAN    = "\033[36m"
GREEN   = "\033[32m"
YELLOW  = "\033[33m"
BLUE    = "\033[34m"
MAGENTA = "\033[35m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RESET   = "\033[0m"

json_path = os.environ.get("VSCODE_PROJECTS_FILE", "")
wanted = sys.argv[1] if len(sys.argv) > 1 else ""

if not json_path or not wanted:
    sys.exit(1)

try:
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = data.get("projects", [])
else:
    items = []

candidate_keys = ["fullPath", "rootPath", "path", "workspace", "workspacePath"]

for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") != wanted:
        continue

    name = item.get("name", "")
    enabled = item.get("enabled", True)
    tags = item.get("tags", [])

    proj_path = ""
    for key in candidate_keys:
        value = item.get(key)
        if value:
            proj_path = os.path.expanduser(value)
            break

    home = os.path.expanduser("~")
    display_path = proj_path.replace(home, "~", 1) if proj_path else "\u2014"

    print(f"{BOLD}{CYAN}\u256d{'\u2500' * 38}\u256e{RESET}")
    print(f"{BOLD}{CYAN}\u2502{RESET}  {BOLD}\U0001f4c1 {name}{RESET}")
    print(f"{BOLD}{CYAN}\u2570{'\u2500' * 38}\u256f{RESET}")
    print()
    print(f"  {BOLD}Path:{RESET}     {GREEN}{display_path}{RESET}")
    print(f"  {BOLD}Enabled:{RESET}  {'\u2714 Yes' if enabled else '\u2718 No'}")

    if isinstance(tags, list) and tags:
        print(f"  {BOLD}Tags:{RESET}     {YELLOW}{', '.join(str(t) for t in tags)}{RESET}")

    if proj_path and os.path.exists(proj_path):
        # Workspace files (.code-workspace) are files, not directories
        is_workspace_file = os.path.isfile(proj_path)
        scan_dir = os.path.dirname(proj_path) if is_workspace_file else proj_path

        st = os.stat(proj_path)
        mtime = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
        print(f"  {BOLD}Modified:{RESET} {DIM}{mtime}{RESET}")

        if is_workspace_file:
            print(f"  {BOLD}Type:{RESET}     {MAGENTA}VS Code Workspace{RESET}")

        indicators = []
        checks = {
            "package.json": "Node.js", "Cargo.toml": "Rust", "go.mod": "Go",
            "pyproject.toml": "Python", "setup.py": "Python", "Gemfile": "Ruby",
            "pom.xml": "Java/Maven", "build.gradle": "Java/Gradle",
            ".git": "Git repo", "Makefile": "Makefile", "CMakeLists.txt": "CMake",
            "docker-compose.yml": "Docker Compose", "Dockerfile": "Docker",
            ".devcontainer": "Dev Container",
        }
        for filename, label in checks.items():
            if os.path.exists(os.path.join(scan_dir, filename)):
                indicators.append(label)

        if indicators:
            print()
            print(f"  {BOLD}Detected:{RESET}")
            for ind in indicators:
                print(f"    {MAGENTA}\u25cf{RESET} {ind}")

        print()
        print(f"  {BOLD}Contents:{RESET}")
        try:
            entries = sorted(os.listdir(scan_dir))
            dirs = [e + "/" for e in entries if os.path.isdir(os.path.join(scan_dir, e)) and not e.startswith(".")]
            files = [e for e in entries if os.path.isfile(os.path.join(scan_dir, e)) and not e.startswith(".")]
            hidden = [e for e in entries if e.startswith(".")]

            shown = 0
            max_show = 15
            for d in dirs[:max_show]:
                print(f"    {BLUE}{d}{RESET}")
                shown += 1
            for ff in files[:max(0, max_show - shown)]:
                print(f"    {DIM}{ff}{RESET}")
                shown += 1
            remaining = len(entries) - shown
            if remaining > 0:
                print(f"    {DIM}\u2026 and {remaining} more{RESET}")
            if hidden:
                print(f"    {DIM}({len(hidden)} hidden){RESET}")
        except PermissionError:
            print(f"    {DIM}(permission denied){RESET}")
    elif proj_path:
        print()
        print(f"  {YELLOW}\u26a0  Path does not exist{RESET}")

    sys.exit(0)

print(f"{YELLOW}Project not found{RESET}", file=sys.stderr)
sys.exit(1)
PREVIEW_PY
command chmod +x "$_VSCODE_PROJECTS_PREVIEW_SCRIPT"


# Parse the projects JSON and emit tab-delimited rows for fzf.
# Format: rawname<TAB>colored_name  colored_path  colored_tags
# First two lines are headers (empty field before tab for --with-nth=2).
# Columns are aligned in Python so we don't need the 'column' command.
_vscode_project_list() {
  [[ -f "$VSCODE_PROJECTS_FILE" ]] || return 1

  python3 - "$VSCODE_PROJECTS_FILE" <<'PY'
import json, sys, os

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = data.get("projects", [])
else:
    items = []

CYAN    = "\033[36m"
GREEN   = "\033[32m"
YELLOW  = "\033[33m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RESET   = "\033[0m"

candidate_keys = ["fullPath", "rootPath", "path", "workspace", "workspacePath"]
home = os.path.expanduser("~")
GAP = "  "

rows = []
for item in items:
    if not isinstance(item, dict):
        continue
    name = item.get("name", "")
    if not name:
        continue
    if not item.get("enabled", True):
        continue

    proj_path = ""
    for key in candidate_keys:
        value = item.get(key)
        if value:
            proj_path = os.path.expanduser(value)
            break

    display_path = proj_path.replace(home, "~", 1) if proj_path else "\u2014"

    tags_raw = item.get("tags", [])
    tags_text = ", ".join(str(t) for t in tags_raw) if isinstance(tags_raw, list) and tags_raw else "\u2014"

    rows.append((name, display_path, tags_text))

if not rows:
    sys.exit(0)

rows.sort(key=lambda x: x[0].lower())

max_name = max(max(len(r[0]) for r in rows), 7)   # "Project"
max_path = max(max(len(r[1]) for r in rows), 4)   # "Path"

# Header lines (empty raw-name field before tab, consumed by --with-nth=2)
print(f"\t{BOLD}{'Project':<{max_name}}{RESET}{GAP}{BOLD}{'Path':<{max_path}}{RESET}{GAP}{BOLD}Tags{RESET}")
print(f"\t{DIM}{'\u2500' * max_name}{GAP}{'\u2500' * max_path}{GAP}\u2500\u2500\u2500\u2500{RESET}")

# Data lines: rawname<TAB>display
for name, display_path, tags_text in rows:
    npad = " " * (max_name - len(name))
    ppad = " " * (max_path - len(display_path))
    ct = f"{YELLOW}{tags_text}{RESET}" if tags_text != "\u2014" else f"{DIM}\u2014{RESET}"
    print(f"{name}\t{CYAN}{name}{RESET}{npad}{GAP}{GREEN}{display_path}{RESET}{ppad}{GAP}{ct}")
PY
}

# Return just project names (plain text, for completion)
_vscode_project_names() {
  [[ -f "$VSCODE_PROJECTS_FILE" ]] || return 1

  python3 - "$VSCODE_PROJECTS_FILE" <<'PY'
import json, sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = data.get("projects", [])
else:
    items = []

for item in items:
    if isinstance(item, dict):
        name = item.get("name")
        enabled = item.get("enabled", True)
        if name and enabled:
            print(name)
PY
}

# Resolve a project name to its filesystem path
_vscode_project_target() {
  local project_name="$1"
  [[ -f "$VSCODE_PROJECTS_FILE" ]] || return 1

  python3 - "$VSCODE_PROJECTS_FILE" "$project_name" <<'PY'
import json, sys, os

json_path = sys.argv[1]
wanted = sys.argv[2]

try:
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = data.get("projects", [])
else:
    items = []

candidate_keys = [
    "fullPath", "rootPath", "path",
    "workspace", "workspacePath",
]

for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") != wanted:
        continue

    for key in candidate_keys:
        value = item.get(key)
        if value:
            print(os.path.expanduser(value))
            sys.exit(0)

sys.exit(1)
PY
}

# Launch fzf picker and return the selected key + project name.
# Output: two lines — key (enter/alt-enter) then raw project name.
# Used by both cprojf and the ZLE widget.
_vscode_fzf_pick_project() {
  local query="$1"
  local project_list result key selection selected_name

  project_list=$(_vscode_project_list)
  [[ -z "$project_list" ]] && return 1

  result=$(echo "$project_list" | fzf \
    --height 50% \
    --ansi \
    --border \
    --cycle \
    --info=inline \
    --header-lines=2 \
    --reverse \
    --prompt='VS Code Project > ' \
    --no-separator \
    --query="$query" \
    --delimiter=$'\t' \
    --with-nth=2 \
    --bind 'shift-tab:up,tab:down,bspace:backward-delete-char/eof' \
    --preview 'VSCODE_PROJECTS_FILE="'"$VSCODE_PROJECTS_FILE"'" python3 "'"$_VSCODE_PROJECTS_PREVIEW_SCRIPT"'" "$(cut -f1 <<< {})"' \
    --preview-window=right:45% \
    --expect=alt-enter,enter \
  )

  [[ -z "$result" ]] && return 1

  key=${result%%$'\n'*}
  if [[ "$key" == "$result" ]]; then
    selection="$result"
    key=""
  else
    selection=${result#*$'\n'}
  fi

  [[ -z "$selection" ]] && return 1

  # Extract raw project name from the hidden first tab-delimited field
  selected_name=$(cut -f1 <<< "$selection")
  [[ -z "$selected_name" ]] && return 1

  # Return key and name via stdout (newline-separated)
  echo "$key"
  echo "$selected_name"
}

# Main command: cproj "Project Name"
cproj() {
  local name="$*"

  if [[ -z "$name" ]]; then
    echo "Usage: cproj <project name>" >&2
    return 2
  fi

  if [[ ! -f "$VSCODE_PROJECTS_FILE" ]]; then
    echo "VS Code Project Manager file not found:" >&2
    echo "  $VSCODE_PROJECTS_FILE" >&2
    return 1
  fi

  local target
  target="$(_vscode_project_target "$name")" || {
    echo "Project not found: $name" >&2
    return 1
  }

  command ${VSCODE_PROJECTS_EDITOR} "$target"
}

# Enhanced fuzzy picker with TUI-like display
cprojf() {
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not installed – install from https://github.com/junegunn/fzf" >&2
    return 1
  fi

  if [[ ! -f "$VSCODE_PROJECTS_FILE" ]]; then
    echo "VS Code Project Manager file not found:" >&2
    echo "  $VSCODE_PROJECTS_FILE" >&2
    return 1
  fi

  local pick_result key selected_name target

  pick_result=$(_vscode_fzf_pick_project "") || return

  key=$(head -1 <<< "$pick_result")
  selected_name=$(tail -1 <<< "$pick_result")

  [[ -z "$selected_name" ]] && return 1

  target="$(_vscode_project_target "$selected_name")" || {
    echo "Could not resolve path for: $selected_name" >&2
    return 1
  }

  if [[ "$key" == "alt-enter" ]]; then
    # Alt+Enter: cd into the project directory instead of opening editor
    if [[ -d "$target" ]]; then
      cd "$target"
    else
      echo "Path is not a directory: $target" >&2
      return 1
    fi
  else
    # Enter: open in editor
    command ${VSCODE_PROJECTS_EDITOR} "$target"
  fi
}

# Completion function
_cproj() {
  local -a projects
  projects=("${(@f)$(_vscode_project_names)}")
  _describe 'VS Code projects' projects
}

compdef _cproj cproj

# ZLE widget: intercept Tab when the command line starts with "cproj" or "cprojf"
_fzf_complete_cproj() {
  local tokens cmd
  setopt localoptions noshwordsplit noksh_arrays noposixbuiltins

  tokens=(${(z)LBUFFER})
  cmd=${tokens[1]}

  if [[ "$cmd" == "cproj" || "$cmd" == "cprojf" ]]; then
    local pick_result key selected_name target fuzzy_input

    # Build query from anything typed after the command (fix: empty when no args)
    if (( ${#tokens} > 1 )); then
      fuzzy_input="${LBUFFER#"$tokens[1] "}"
    else
      fuzzy_input=""
    fi

    pick_result=$(_vscode_fzf_pick_project "$fuzzy_input")

    if [[ -z "$pick_result" ]]; then
      zle reset-prompt
      return
    fi

    key=$(head -1 <<< "$pick_result")
    selected_name=$(tail -1 <<< "$pick_result")

    if [[ -n "$selected_name" ]]; then
      target="$(_vscode_project_target "$selected_name")"
      if [[ -n "$target" ]]; then
        if [[ "$key" == "alt-enter" ]]; then
          LBUFFER="cd ${(q)target}"
        else
          LBUFFER="${VSCODE_PROJECTS_EDITOR} ${(q)target}"
        fi
        zle accept-line
        return
      fi
    fi

    zle reset-prompt
  else
    zle ${_fzf_cproj_default_completion:-expand-or-complete}
  fi
}

# Save the current Tab binding, then override with our widget
[ -z "$_fzf_cproj_default_completion" ] && {
  binding=$(bindkey '^I')
  [[ $binding =~ 'undefined-key' ]] || _fzf_cproj_default_completion=$binding[(s: :w)2]
  unset binding
}

zle -N _fzf_complete_cproj
bindkey '^I' _fzf_complete_cproj
