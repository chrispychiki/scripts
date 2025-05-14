#!/bin/bash

# =========================================================================
# repo2llm.sh - Generate structured git repository output for LLMs
# =========================================================================
#
# DESCRIPTION:
#   This script helps extract code from git repositories in a format optimized for
#   LLM interactions. It provides an interactive file selection interface with
#   files sorted by modification time (most recent first). The output includes
#   a directory tree and formatted file contents ready for pasting into LLM chats.
#
# FEATURES:
#   - Works exclusively with git repositories (respects .gitignore patterns)
#   - Excludes hidden files and directories (starting with .)
#   - Interactive navigation with files and folders sorted by modification time (most recent first)
#   - Directory previews showing recently modified files
#   - Logical directory structure in the output for better context
#   - Handles file content formatting with proper delimiters
#   - Clipboard integration for direct pasting into LLM interfaces
#   - Cross-platform support for macOS and Linux
#
# DEPENDENCIES:
#   - git: For repository detection and file listing
#   - pbcopy (macOS) or xclip (Linux): For clipboard operations
#     Note: If neither is available, output is saved to a temporary file
#   - Standard Unix utilities: grep, sort, stat, etc.
#
# USAGE:
#   ./repo2llm.sh [repository_path] [options]
#
# OPTIONS:
#   -d, --debug      Debug mode - display the generated output for verification
#   -h, --help       Show usage information
#
# INTERACTIVE COMMANDS:
#   [number]        Select a file or navigate into a directory
#   [num1,num2,..]  Select multiple files by comma-separated list
#   [num1-num2]     Select a range of files (inclusive)
#   *               Select all files in current directory
#   **              Select all files recursively
#   ..              Go up to the parent directory
#   r               Return to repository root
#   path            Navigate to path (tab completion works)
#   u [num|path]    Unselect a file by index number or path
#   u *             Unselect all files
#   [empty]         Press Enter with no input to finish selection and copy to clipboard
#   d, done         Shortcut to finish selection and copy to clipboard
#   l, list         List currently selected files
#   q, quit, exit   Quit without generating output
#   h, help, ?      Show help for commands
#
# EXIT CODES:
#   0               Success
#   1               Error (invalid arguments, not a git repository, etc.)
#
# NOTES:
#   - The script creates temporary files for processing which are automatically
#     cleaned up on exit
#   - Very large repositories might experience performance issues when listing files
#   - Files are always listed with newest modifications first
#   - Navigation starts in the repository root regardless of which subdirectory you're in
#
# EXAMPLES:
#   ./repo2llm.sh ~/my-project        # Start in specified repository
#   ./repo2llm.sh                     # Start in current directory
#   ./repo2llm.sh ~/my-project -d     # Show and debug the output
#
# =========================================================================

REPO_PATH="."
DEBUG_MODE=0

show_help() {
  local interactive_mode=${1:-0}
  
  if [[ "$interactive_mode" -eq 1 ]]; then
    tput clear
    tput cup 0 0
  fi
  
  echo "repo2llm.sh - Generate structured git repository output for LLMs"
  echo ""
  
  if [[ "$interactive_mode" -eq 0 ]]; then
    echo "DESCRIPTION:"
    echo "  This script extracts code from git repositories in a format optimized for"
    echo "  interaction with Large Language Models (LLMs). It provides an interactive"
    echo "  file selection interface sorted by modification time (most recent first),"
    echo "  then generates a structured output with a directory tree and file contents."
    echo ""
    echo "USAGE:"
    echo "  $(basename "$0") [repository_path] [options]"
    echo ""
    echo "OPTIONS:"
    echo "  -d, --debug     Debug mode to display the output"
    echo "  -h, --help      Show this help message"
    echo ""
  fi
  
  echo "INTERACTIVE COMMANDS:"
  echo "  [number]        Select a file or navigate into a directory"
  echo "  [num1,num2,..]  Select multiple files by comma-separated list"
  echo "  [num1-num2]     Select range of files (inclusive)"
  echo "  *               Select all files in current directory"
  echo "  **              Select all files recursively"
  echo "  ..              Go up to the parent directory"
  echo "  r               Return to repository root"
  echo "  path            Navigate to path (tab completion works)"
  echo "  u [num|path]    Unselect a file by index number or path"
  echo "  u *             Unselect all files"
  echo "  [empty]         Press Enter with no input to finish selection and copy to clipboard"
  echo "  d, done         Shortcut to finish selection and copy to clipboard"
  echo "  l, list         List currently selected files"
  echo "  q, quit, exit   Quit without generating output"
  echo "  h, help, ?      Show help for commands"
  echo ""
  
  echo "NAVIGATION TIPS:"
  echo "  • Files and directories are sorted by modification time (most recent first)"
  echo "  • Only git-tracked files are shown (respects .gitignore)"
  echo "  • Hidden files and directories (starting with .) are excluded"
  echo "  • The output will follow directory structure for better LLM understanding"
  
  if [[ "$interactive_mode" -eq 0 ]]; then
    echo ""
    echo "EXAMPLES:"
    echo "  $(basename "$0") ~/my-project"
    echo "  $(basename "$0")"
    echo "  $(basename "$0") ~/my-project -d"
  else
    echo ""
    echo "-------------------------------------------------------------------------------"
    read -p "Press Enter to return to file selection..." 
  fi
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--debug)
      DEBUG_MODE=1
      shift
      ;;
    -h|--help)
      show_help 0
      exit 0
      ;;
    *)
      if [[ -d "$1" ]]; then
        REPO_PATH="$1"
      elif [[ $1 == -* ]]; then
        echo "Unknown option: $1"
        show_help 0
        exit 1
      else
        echo "Error: Directory not found: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

cd "$REPO_PATH" || { echo "Error: Cannot access repository path"; exit 1; }

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: Not a git repository. This script only works in git repositories."
  exit 1
fi

GIT_ROOT=$(git rev-parse --show-toplevel)

RANDPID="$$"
TIMESTAMP=$(date +%s)
RANDOM_SUFFIX="$RANDOM$RANDOM"
TEMPDIR="/tmp/repo2llm_${RANDPID}_${TIMESTAMP}_${RANDOM_SUFFIX}"
mkdir -p "$TEMPDIR"

TEMP_FILE="$TEMPDIR/output.txt"
LIST_FILE="$TEMPDIR/list.txt"
ORDER_FILE="$TEMPDIR/order.txt" 
FILE_CACHE_FILE="$TEMPDIR/file_cache.txt"
DIR_MOD_TIME_CACHE_FILE="$TEMPDIR/dir_mod_cache.txt"

cleanup() {
  local exit_code=$?
  rm -rf "$TEMPDIR"
  exit $exit_code
}

trap cleanup EXIT INT TERM

build_file_cache() {
  local stat_fmt="%Y"
  local stat_opt="-c"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat_fmt="%m"
    stat_opt="-f"
  fi

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_file_cache]: Building file cache..." >&2
  fi

  if ! git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\." > "$TEMP_FILE"; then
    echo "Error: Failed to get file list from git" >&2
    return 1
  fi
  
  local file_count=$(wc -l < "$TEMP_FILE")

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_file_cache]: Found $file_count files from git" >&2
  fi

  > "$FILE_CACHE_FILE"
  if [ ! -f "$FILE_CACHE_FILE" ]; then
    echo "Error: Failed to create file cache" >&2
    return 1
  fi

  local split_prefix="${TEMPDIR}/split.${RANDOM}${RANDOM}"
  if ! split -l 500 "$TEMP_FILE" "$split_prefix"; then
    echo "Error: Failed to split file list" >&2
    return 1
  fi
  
  for split_file in "${TEMPDIR}/split."*; do
    if [[ -f "$split_file" ]]; then
      if ! cat "$split_file" | xargs -I{} -P 16 bash -c '
        file="$1"
        git_root="$2"
        stat_opt="$3"
        stat_fmt="$4"
        
        if [[ -z "$file" ]]; then
          exit 0
        fi
        
        full_path="${git_root}/${file}"
        if [[ -f "$full_path" && ! -d "$full_path" ]]; then
          mod_time=$(stat "$stat_opt" "$stat_fmt" "$full_path" 2>/dev/null)
          if [[ -n "$mod_time" ]]; then
            echo "$file|$mod_time"
          fi
        fi
      ' -- {} "$GIT_ROOT" "$stat_opt" "$stat_fmt" >> "$FILE_CACHE_FILE"; then
        echo "Warning: Error processing some files in ${split_file}" >&2
      fi
      
      rm -f "$split_file"
    fi
  done

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local cache_count=$(wc -l < "$FILE_CACHE_FILE")
    echo "DEBUG [build_file_cache]: Added $cache_count files to cache" >&2
  fi
}

build_dir_mod_time_cache() {
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_dir_mod_time_cache]: Building directory modification time cache..." >&2
  fi

  awk -F'|' '
    BEGIN { OFS="|" }
    $1 ~ /\// {
      parts = split($1, path_parts, "/")
      time = $2

      curr_path = ""
      for (i=1; i < parts; i++) {
        if (curr_path == "") {
          curr_path = path_parts[i]
        } else {
          curr_path = curr_path "/" path_parts[i]
        }

        if (!(curr_path in dirs) || time > dirs[curr_path]) {
          dirs[curr_path] = time
        }
      }
    }
    END {
      for (dir in dirs) {
        print dir, dirs[dir]
      }
    }
  ' "$FILE_CACHE_FILE" > "$DIR_MOD_TIME_CACHE_FILE"

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local cache_count=$(wc -l < "$DIR_MOD_TIME_CACHE_FILE")
    echo "DEBUG [build_dir_mod_time_cache]: Added $cache_count directories to cache" >&2
  fi
}

get_file_mod_time() {
  local file_path="$1"
  grep "^$(printf "%s" "$file_path" | sed 's/[][\.^$*+?(){}|/]/\\&/g')|" "$FILE_CACHE_FILE" | cut -d'|' -f2
}

get_dir_mod_time() {
  local dir_path="$1"

  local cached_time=$(grep "^$(printf "%s" "$dir_path" | sed 's/[][\.^$*+?(){}|/]/\\&/g')|" "$DIR_MOD_TIME_CACHE_FILE" | cut -d'|' -f2)
  if [[ -n "$cached_time" ]]; then
    echo "$cached_time"
    return
  fi

  local max_time=$(awk -F'|' -v path="$(printf "%s" "$dir_path")/" 'BEGIN { gsub(/[][^$.+*(){}|\\]/, "\\\\&", path) } $1 ~ "^"path { if ($2 > max || max=="") max=$2 } END {print max}' "$FILE_CACHE_FILE")

  if [[ -z "$max_time" ]]; then
    local stat_fmt="%Y"
    local stat_opt="-c"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      stat_fmt="%m"
      stat_opt="-f"
    fi
    max_time=$(stat "$stat_opt" "$stat_fmt" "${GIT_ROOT}/${dir_path}" 2>/dev/null)
  fi

  echo "$dir_path|$max_time" >> "$DIR_MOD_TIME_CACHE_FILE"

  echo "$max_time"
}

get_all_items() {
  local current_dir="$1"
  local rel_path
  local random_id="${RANDOM}${RANDOM}_$$"
  local items_temp_file="${TEMPDIR}/items_temp_${random_id}.txt"
  > "$items_temp_file"
  if [ ! -f "$items_temp_file" ]; then
    echo "Error: Failed to create temporary file $items_temp_file" >&2
    return 1
  fi

  if [[ "$current_dir" == "$GIT_ROOT" ]]; then
    rel_path=""
  else
    rel_path="${current_dir#$GIT_ROOT/}"
  fi

  if [[ -z "$rel_path" ]]; then
    grep -E "^[^/]+\|" "$FILE_CACHE_FILE" |
      awk -F'|' '{print $2 "|f|" $1}' >> "$items_temp_file"
  else
    local escaped_path
    escaped_path=$(printf "%s" "$rel_path" | sed 's/[][\^$.*+?(){}|\\]/\\&/g')
    grep -E "^${escaped_path}/[^/]+\|" "$FILE_CACHE_FILE" |
      awk -F'|' -v path="$rel_path/" '{gsub(path, "", $1); print $2 "|f|" $1}' >> "$items_temp_file"
  fi

  local random_id2="${RANDOM}${RANDOM}_$$"
  local dir_list_file="${TEMPDIR}/dir_list_${random_id2}.txt"
  > "$dir_list_file"
  if [ ! -f "$dir_list_file" ]; then
    echo "Error: Failed to create temporary file $dir_list_file" >&2
    rm -f "$items_temp_file"
    return 1
  fi

  if [[ -z "$rel_path" ]]; then
    grep -E "/" "$FILE_CACHE_FILE" | cut -d'|' -f1 | cut -d'/' -f1 | grep -v "^\." | sort | uniq > "$dir_list_file"
  else
    local escaped_path
    escaped_path=$(printf "%s" "$rel_path" | sed 's/[][\^$.*+?(){}|\\]/\\&/g')
    grep -E "^${escaped_path}/" "$FILE_CACHE_FILE" |
      awk -F'|' -v path="$rel_path/" '{
        gsub(path, "", $1);
        if (index($1, "/") > 0) {
          dir = substr($1, 1, index($1, "/")-1);
          if (dir != "." && dir !~ /^\./)
            print dir
        }
      }' | sort | uniq > "$dir_list_file"
  fi

  while read -r dir; do
    if [[ -z "$dir" ]]; then
      continue
    fi

    local dir_path_full
    if [[ -z "$rel_path" ]]; then
      dir_path_full="$dir"
    else
      dir_path_full="${rel_path}/${dir}"
    fi

    local mod_time=$(get_dir_mod_time "$dir_path_full")

    if [[ -n "$mod_time" ]]; then
      echo "$mod_time|d|$dir/" >> "$items_temp_file"
    fi
  done < "$dir_list_file"

  rm -f "$dir_list_file" 2>/dev/null

  if [[ -s "$items_temp_file" ]]; then
    sort -t'|' -k1,1nr "$items_temp_file" || echo "Error: sort failed" >&2
  fi

  rm -f "$items_temp_file" "$dir_list_file" 2>/dev/null
}

get_directory_preview() {
  local dir_path="$1"
  local max_items="$2"
  local full_path="${GIT_ROOT}/${dir_path}"

  local all_items=$(get_all_items "$full_path")

  if [[ -z "$all_items" ]]; then
    echo "(Empty directory)"
    return
  fi

  local result=""
  local count=0

  while IFS='|' read -r time type name; do
    if [[ "$type" == "d" ]]; then
      result+="📁 $name"$'\n'
    else
      result+="📄 $name"$'\n'
    fi

    ((count++))
    if [[ $count -eq $max_items ]]; then
      break
    fi
  done < <(echo "$all_items")

  echo -e "$result"
}

get_directory_contents() {
  local current_dir="$1"
  
  local sorted_items=$(get_all_items "$current_dir")
  
  ITEMS=()
  ITEM_TYPES=()
  MOD_TIMES=()
  PREVIEWS=()
  
  if [[ -n "$sorted_items" ]]; then
    while IFS= read -r item; do
      if [[ -z "$item" ]]; then
        continue
      fi
      
      local mod_time=$(echo "$item" | cut -d'|' -f1)
      local type=$(echo "$item" | cut -d'|' -f2)
      local name=$(echo "$item" | cut -d'|' -f3)
      
      ITEMS+=("$name")
      ITEM_TYPES+=("$type")
      MOD_TIMES+=("$mod_time")
      
      if [[ "$type" == "d" ]]; then
        local dir_path
        if [[ "$current_dir" == "$GIT_ROOT" ]]; then
          dir_path="${name%/}"
        else
          dir_path="${current_dir#$GIT_ROOT/}/${name%/}"
        fi
        
        local preview
        preview=$(get_directory_preview "$dir_path" 3)
        PREVIEWS+=("$preview")
      else
        PREVIEWS+=("")
      fi
    done < <(printf "%s\n" "$sorted_items")
  fi
}

echo "Starting interactive file selection..."
SELECTED_FILES=()
CURRENT_DIR="$GIT_ROOT"
ERROR_MESSAGE=""

ITEMS=()
ITEM_TYPES=()
MOD_TIMES=()
PREVIEWS=()

build_file_cache
build_dir_mod_time_cache


show_files() {
  local current_dir="$1"
  local items_index=()
  local saved_dir
  
  saved_dir=$(pwd)
  
  cd "$current_dir" || return
  
  tput clear
  tput cup 0 0
  
  if [[ -n "$ERROR_MESSAGE" ]]; then
    tput setaf 1
    tput bold
    echo "ERROR: $ERROR_MESSAGE"
    tput sgr0
    echo "-------------------------------------------------------------------------------"
    ERROR_MESSAGE=""
  fi
  
  echo "Directory: $current_dir"
  
  if [ ${#SELECTED_FILES[@]} -gt 0 ]; then
    echo "Selected files:"
    local displayed=0
    for ((j=0; j<${#SELECTED_FILES[@]} && j<3; j++)); do
      echo "  [$j] $(basename "${SELECTED_FILES[$j]}")"
      ((displayed++))
    done
    
    if [ $displayed -lt ${#SELECTED_FILES[@]} ]; then
      echo "  ... and $((${#SELECTED_FILES[@]} - displayed)) more (use 'l' to list all)"
    fi
  else
    echo "Selected: 0 files"
  fi
  
  echo "-------------------------------------------------------------------------------"
  
  get_directory_contents "$current_dir"
  
  local idx=0
  local item_count=0
  local max_previews=3

  for i in "${!ITEMS[@]}"; do
    local item="${ITEMS[$i]}"
    local type="${ITEM_TYPES[$i]}"
    local preview="${PREVIEWS[$i]}"
    local show_preview=0

    if [[ "$type" == "d" && $item_count -lt $max_previews ]]; then
      show_preview=1
    fi

    if [[ "$type" == "d" ]]; then
      echo "[$idx] 📁 $item"

      if [[ $show_preview -eq 1 && "$preview" != "(Empty directory)" ]]; then
        local line_num=0
        while IFS= read -r line; do
          if [[ $line_num -eq 0 ]]; then
            echo "    └─ $line"
          else
            echo "       $line"
          fi
          ((line_num++))
        done < <(echo "$preview")
      fi
    else
      echo "[$idx] 📄 $item"
    fi

    ((item_count++))

    items_index[$idx]="$type:$item"
    ((idx++))
  done
  
  echo "-------------------------------------------------------------------------------"
  echo "  SELECT: [num] file/dir, [num1,num2] multiple, [num1-num2] range"
  echo "  SELECT: [*] all in dir, [**] recursive, [u num/path/*] unselect"
  echo "  NAVIGATE: [..] parent, [r] root, [path] go to path (tab works)"
  echo "  ACTIONS: [Enter] done, [l] list selected, [q] quit, [h] help"
  echo "-------------------------------------------------------------------------------"
  
  read -e -p "> " selection
  
  cd "$saved_dir" || return 1
  
  case "$selection" in
    ""|"done"|"d")
      echo "Finishing selection with ${#SELECTED_FILES[@]} files..."
      return 1
      ;;
    "help"|"h"|"?")
      show_help 1
      ;;
    "list"|"l")
      tput clear
      tput cup 0 0
      
      echo "Currently selected files:"
      if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
        echo "  (No files selected yet)"
      else
        for ((j=0; j<${#SELECTED_FILES[@]}; j++)); do
          echo "  [$j] ${SELECTED_FILES[$j]}"
        done
      fi
      
      echo ""
      echo "-------------------------------------------------------------------------------"
      echo -n "Press Enter to return to file selection..."
      read
      ;;
    "quit"|"q"|"exit")
      echo "Exiting without processing files."
      exit 0
      ;;
    "..")
      if [[ "$CURRENT_DIR" != "$GIT_ROOT" ]]; then
        CURRENT_DIR="$(dirname "$CURRENT_DIR")"
      else
        ERROR_MESSAGE="Already at repository root"
      fi
      ;;
    "r")
      CURRENT_DIR="$GIT_ROOT"
      echo "Returned to repository root"
      ;;
    u*)
      local unselect_arg="${selection#u}"
      unselect_arg="${unselect_arg# }"
      
      if [[ -z "$unselect_arg" ]]; then
        ERROR_MESSAGE="Usage: u [number|path|*] - You must specify what to unselect"
      elif [[ "$unselect_arg" == "*" ]]; then
        local count=${#SELECTED_FILES[@]}
        SELECTED_FILES=()
        echo "Unselected all $count files"
      elif [[ "$unselect_arg" =~ ^[0-9]+$ ]] && [ "$unselect_arg" -lt "${#SELECTED_FILES[@]}" ]; then
        local removed_file="${SELECTED_FILES[$unselect_arg]}"
        SELECTED_FILES=("${SELECTED_FILES[@]:0:$unselect_arg}" "${SELECTED_FILES[@]:$((unselect_arg+1))}")
        echo "Unselected: $removed_file"
      else
        local removed=0
        local full_path=""
        
        if [[ "$unselect_arg" == /* ]]; then
          full_path="$unselect_arg"
        else
          full_path="$CURRENT_DIR/$unselect_arg"
        fi
        
        for i in "${!SELECTED_FILES[@]}"; do
          if [[ "${SELECTED_FILES[$i]}" == "$full_path" ]]; then
            SELECTED_FILES=("${SELECTED_FILES[@]:0:$i}" "${SELECTED_FILES[@]:$((i+1))}")
            removed=1
            echo "Unselected: $full_path"
            break
          fi
        done
        
        if [[ "$removed" -eq 0 ]]; then
          ERROR_MESSAGE="No such file in selection: $unselect_arg"
        fi
      fi
      ;;
    "*")
      local count=0
      for i in "${!ITEMS[@]}"; do
        local type="${ITEM_TYPES[$i]}"
        local name="${ITEMS[$i]}"

        if [ "$type" == "f" ]; then
          local full_path="${CURRENT_DIR}/${name}"
          if [[ ! -f "$full_path" ]]; then
            continue
          elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
            continue
          else
            SELECTED_FILES+=("$full_path")
            ((count++))
          fi
        fi
      done
      echo "Selected $count files from current directory"
      ;;

    "**")
      local rel_path=""
      if [[ "$CURRENT_DIR" != "$GIT_ROOT" ]]; then
        rel_path="${CURRENT_DIR#$GIT_ROOT/}"
      fi

      local count=0
      
      local escaped_path
      escaped_path=$(printf "%s" "$rel_path" | sed 's/[][\^$.*+?(){}|\\]/\\&/g')

      while IFS= read -r line; do
        file_path=$(echo "$line" | cut -d'|' -f1)
        if [[ -z "$file_path" ]]; then continue; fi

        full_path="${GIT_ROOT}/${file_path}"

        if [[ ! " ${SELECTED_FILES[*]} " =~ " $full_path " ]]; then
          SELECTED_FILES+=("$full_path")
          ((count++))
        fi
      done < <(grep -E "^${escaped_path}" "$FILE_CACHE_FILE")

      echo "Selected $count files recursively from $CURRENT_DIR"
      ;;

    [0-9]*-[0-9]*)
      local start end
      if [[ "$selection" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start="${BASH_REMATCH[1]}"
        end="${BASH_REMATCH[2]}"

        if [ "$start" -lt "$idx" ] && [ "$end" -lt "$idx" ] && [ "$start" -le "$end" ]; then
          local count=0
          for ((i=start; i<=end; i++)); do
            local item="${items_index[$i]}"
            local type="${item%%:*}"
            local name="${item#*:}"

            if [ "$type" == "f" ]; then
              local full_path="${CURRENT_DIR}/${name}"
              if [[ ! -f "$full_path" ]]; then
                continue
              elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
                continue
              else
                SELECTED_FILES+=("$full_path")
                ((count++))
              fi
            fi
          done
          echo "Selected $count files from range $start-$end"
        else
          ERROR_MESSAGE="Invalid range: $selection (valid indices are 0-$((idx-1)))"
        fi
      else
        ERROR_MESSAGE="Invalid range format: $selection"
      fi
      ;;

    [0-9]*,[0-9]*)
      if [[ "$selection" =~ ^[0-9,]+$ ]]; then
        IFS=',' read -ra NUMS <<< "$selection"
        local count=0

        for num in "${NUMS[@]}"; do
          if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -lt "$idx" ]; then
            local item="${items_index[$num]}"
            local type="${item%%:*}"
            local name="${item#*:}"

            if [ "$type" == "f" ]; then
              local full_path="${CURRENT_DIR}/${name}"
              if [[ ! -f "$full_path" ]]; then
                continue
              elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
                continue
              else
                SELECTED_FILES+=("$full_path")
                ((count++))
              fi
            elif [ "$type" == "d" ]; then
              ERROR_MESSAGE="Cannot select directory #$num ($name) in a list - use individual selection to navigate"
            fi
          else
            ERROR_MESSAGE="Skipping invalid selection: $num"
          fi
        done
        echo "Selected $count files from list $selection"
      fi
      ;;

    [0-9]*)
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "$idx" ]; then
        local item="${items_index[$selection]}"
        local type="${item%%:*}"
        local name="${item#*:}"

        if [ "$type" == "d" ]; then
          CURRENT_DIR="$CURRENT_DIR/${name%/}"
        elif [ "$type" == "f" ]; then
          local full_path="$CURRENT_DIR/$name"
          if [[ ! -f "$full_path" ]]; then
            ERROR_MESSAGE="File not found at path: $full_path"
          elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
            ERROR_MESSAGE="Already selected: $name"
          else
            SELECTED_FILES+=("$full_path")
            echo "Selected: $name"
          fi
        fi
      else
        ERROR_MESSAGE="Invalid selection: $selection"
      fi
      ;;

    *)
      local target_path=""
      
      # Handle special case for "." or "./" exactly
      if [[ "$selection" == "." || "$selection" == "./" ]]; then
        target_path="$CURRENT_DIR"
      elif [[ "$selection" == /* ]]; then
        target_path="$selection"
      elif [[ "$selection" == ~* ]]; then
        target_path=$(eval echo "$selection")
      else
        local old_pwd=$(pwd)
        cd "$CURRENT_DIR" >/dev/null || return
        target_path=$(realpath -m "$selection" 2>/dev/null || echo "$CURRENT_DIR/$selection")
        cd "$old_pwd" >/dev/null || return
      fi
      
      target_path="${target_path%/}"
      target_path=$(echo "$target_path" | sed 's|/\./|/|g' | sed 's|/\.$||')
      
      if [[ -d "$target_path" ]]; then
        # Ensure we're using the fully resolved canonical path
        CURRENT_DIR=$(cd "$target_path" && pwd)
        echo "Navigated to: $CURRENT_DIR"
      elif [[ -f "$target_path" ]]; then
        if [[ ! " ${SELECTED_FILES[*]} " =~ " ${target_path} " ]]; then
          SELECTED_FILES+=("$target_path")
          echo "Selected: $target_path"
        else
          ERROR_MESSAGE="Already selected: $target_path"
        fi
      else
        ERROR_MESSAGE="Invalid selection or path not found: $selection"
      fi
      ;;
  esac
  
  return 0
}

while true; do
  show_files "$CURRENT_DIR"
  if [ $? -eq 1 ]; then
    break
  fi
done

if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
  echo "No files were selected, nothing to copy."
  exit 0
fi

echo "Formatting ${#SELECTED_FILES[@]} files for LLM interaction..."

{
  REPO_BASENAME=$(basename "$GIT_ROOT")
  echo "# Repository: $REPO_BASENAME ($GIT_ROOT)"
  echo "# Files: ${#SELECTED_FILES[@]}"
  echo ""
  
  echo "## Directory Structure"
  echo '```'
  echo "$GIT_ROOT"
  
  > "$LIST_FILE"
  
  for FILE in "${SELECTED_FILES[@]}"; do
    REL_PATH="${FILE#"$GIT_ROOT/"}"
    echo "$REL_PATH" >> "$LIST_FILE"
  done
  
  list_tree_temp="${TEMPDIR}/list.tree.${RANDOM}${RANDOM}.txt"
  sort -V "$LIST_FILE" > "$list_tree_temp"
  mv "$list_tree_temp" "$LIST_FILE"
  cp "$LIST_FILE" "$ORDER_FILE"
  
  PREV_PARTS=()
  INDENT_CACHE=()
  for ((i=0; i<10; i++)); do
    indentation=""
    for ((j=0; j<i; j++)); do
      indentation="${indentation}|   "
    done
    INDENT_CACHE[i]="$indentation"
  done

  get_indent() {
    local depth=$1
    if [ "$depth" -lt 10 ]; then
      echo "${INDENT_CACHE[$depth]}"
    else
      local indentation=""
      for ((i=0; i<depth; i++)); do
        indentation="${indentation}|   "
      done
      echo "$indentation"
    fi
  }

  while IFS= read -r FILE_PATH; do
    if [[ -z "$FILE_PATH" ]]; then
      continue
    fi
    
    if [[ "$FILE_PATH" != *"/"* ]]; then
      echo "+-- $FILE_PATH"
      continue
    fi

    DIR_PATH=$(dirname "$FILE_PATH")
    FILENAME=$(basename "$FILE_PATH")

    IFS='/' read -ra CURR_PARTS <<< "$DIR_PATH"

    COMMON_PREFIX_LEN=0
    for ((i=0; i<${#PREV_PARTS[@]} && i<${#CURR_PARTS[@]}; i++)); do
      if [[ "${PREV_PARTS[i]}" == "${CURR_PARTS[i]}" ]]; then
        ((COMMON_PREFIX_LEN++))
      else
        break
      fi
    done

    for ((i=COMMON_PREFIX_LEN; i<${#CURR_PARTS[@]}; i++)); do
      if [[ $i -eq 0 ]]; then
        echo "+-- ${CURR_PARTS[i]}"
      else
        echo "$(get_indent $i)+-- ${CURR_PARTS[i]}"
      fi
    done

    echo "$(get_indent ${#CURR_PARTS[@]})+-- $FILENAME"

    PREV_PARTS=("${CURR_PARTS[@]}")
  done < "$LIST_FILE"
  
  echo '```'
  echo ""
  
  while IFS= read -r REL_PATH; do
    if [[ -z "$REL_PATH" ]]; then
      continue
    fi
    
    FILE="${GIT_ROOT}/${REL_PATH}"
    if [[ ! -f "$FILE" ]]; then
      echo "Error: File not found: $FILE" >&2
      continue
    fi
    
    echo -e "\n\n"
    echo -e "########"
    echo -e "# FILE: $FILE"
    echo -e "########"
    echo -e "\n<file-contents>"
    if ! cat "$FILE"; then
      echo "Error: Could not read file: $FILE" >&2
      echo "[Content unavailable due to read error]"
    fi
    
    if [ -s "$FILE" ] && [ "$(tail -c1 "$FILE" 2>/dev/null)" != "$(printf '\n')" ]; then
      echo ""
    fi
    echo "</file-contents>"
  done < "$ORDER_FILE"
} > "$TEMP_FILE"

CLIPBOARD_SUCCESS=0
CLIPBOARD_ERROR=""

if command -v pbcopy &> /dev/null; then
  if cat "$TEMP_FILE" | pbcopy; then
    CLIPBOARD_SUCCESS=1
  else
    CLIPBOARD_ERROR="pbcopy failed with error code $?"
  fi
elif command -v xclip &> /dev/null; then
  if cat "$TEMP_FILE" | xclip -selection clipboard; then
    CLIPBOARD_SUCCESS=1
  else
    CLIPBOARD_ERROR="xclip failed with error code $?"
  fi
else
  CLIPBOARD_ERROR="No clipboard utility found (pbcopy/xclip)"
fi

if [ $CLIPBOARD_SUCCESS -eq 1 ]; then
  echo "Done! Repository files copied to clipboard for LLM chat."
else
  echo "Unable to copy to clipboard: $CLIPBOARD_ERROR"
  echo "Output saved to: $TEMP_FILE"
  trap - EXIT
fi

if [ $DEBUG_MODE -eq 1 ]; then
  echo "=== DEBUG: OUTPUT CONTENTS ==="
  cat "$TEMP_FILE"
  echo "=== END DEBUG OUTPUT ==="
fi
exit 0