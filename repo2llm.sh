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
#   -d, --debug    Debug mode - display the generated output for verification
#   -h, --help     Show usage information
#
# INTERACTIVE COMMANDS:
#   [number]       Select a file or navigate into a directory
#   [num1,num2,..] Select multiple files by comma-separated list
#   [num1-num2]    Select a range of files (inclusive)
#   *              Select all files in current directory
#   **             Select all files recursively
#   ..             Go up to the parent directory
#   /              Return to repository root
#   /path/to/dir   Navigate directly to a subdirectory
#   /path/to/file  Select a specific file directly
#   [empty]        Press Enter with no input to finish selection and copy to clipboard
#   l              List currently selected files
#   q              Quit without generating output
#   h              Show help for commands
#
# EXIT CODES:
#   0              Success
#   1              Error (invalid arguments, not a git repository, etc.)
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

print_usage() {
  echo "repo2llm.sh - Generate structured git repository output for LLMs"
  echo ""
  echo "DESCRIPTION:"
  echo "  This script extracts code from git repositories in a format optimized for"
  echo "  interaction with Large Language Models (LLMs). It provides an interactive"
  echo "  file selection interface sorted by modification time (most recent first),"
  echo "  then generates a structured output with a directory tree and file contents."
  echo ""
  echo "USAGE:"
  echo "  $0 [repository_path] [options]"
  echo ""
  echo "OPTIONS:"
  echo "  -d, --debug              Debug mode to display the output"
  echo "  -h, --help               Show this help message"
  echo ""
  echo "INTERACTIVE NAVIGATION COMMANDS:"
  echo "  [number]                 Select a file or navigate into a directory"
  echo "  [num1,num2,...]         Select multiple files by comma-separated list"
  echo "  [num1-num2]             Select range of files (inclusive)"
  echo "  *                       Select all files in current directory"
  echo "  **                      Select all files recursively"
  echo "  ..                      Go up to the parent directory"
  echo "  /                       Return to repository root"
  echo "  [empty]                  Press Enter with no input to finish selection and copy to clipboard"
  echo "  l                       List currently selected files"
  echo "  q                       Quit without generating output"
  echo "  h                       Show help for commands"
  echo ""
  echo "FEATURES:"
  echo "  - Works with git repositories only (respects .gitignore)"
  echo "  - Excludes hidden files and directories (starting with .)"
  echo "  - Interactive directory navigation with files and folders sorted by recency"
  echo "  - Creates a structured output with file count, directory tree, and contents"
  echo "  - Copies the formatted output to the clipboard"
  echo ""
  echo "EXAMPLES:"
  echo "  $0 ~/my-project        # Start in specified repository"
  echo "  $0                     # Start in current directory"
  echo "  $0 ~/my-project -d     # Show debug output"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--debug)
      DEBUG_MODE=1
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      if [[ -d "$1" ]]; then
        REPO_PATH="$1"
      elif [[ $1 == -* ]]; then
        echo "Unknown option: $1"
        print_usage
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

TEMP_FILE=$(mktemp)
LIST_FILE=$(mktemp)
ORDER_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE" "$LIST_FILE" "$ORDER_FILE"' EXIT

FILE_CACHE_FILE=$(mktemp)
DIR_MOD_TIME_CACHE_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE" "$LIST_FILE" "$ORDER_FILE" "$FILE_CACHE_FILE" "$DIR_MOD_TIME_CACHE_FILE" "$TEMP_FILE.split."* "$LIST_FILE.tmp" "$LIST_FILE.tmp2" "$LIST_FILE.tree" /tmp/tmp.*' EXIT

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

  git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\." > "$TEMP_FILE"
  local file_count=$(wc -l < "$TEMP_FILE")

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_file_cache]: Found $file_count files from git" >&2
  fi

  > "$FILE_CACHE_FILE"

  # Process files in batches using xargs for parallel processing
  split -l 500 "$TEMP_FILE" "$TEMP_FILE.split."
  
  for split_file in "$TEMP_FILE.split."*; do
    if [[ -f "$split_file" ]]; then
      # Use xargs to parallelize stat operations
      cat "$split_file" | xargs -I{} -P 16 bash -c '
        file="$1"
        git_root="$2"
        stat_opt="$3"
        stat_fmt="$4"
        
        if [[ -z "$file" ]]; then
          exit 0
        fi
        
        full_path="$git_root/$file"
        if [[ -f "$full_path" && ! -d "$full_path" ]]; then
          mod_time=$(stat $stat_opt "$stat_fmt" "$full_path" 2>/dev/null)
          if [[ -n "$mod_time" ]]; then
            echo "$file|$mod_time"
          fi
        fi
      ' -- {} "$GIT_ROOT" "$stat_opt" "$stat_fmt" >> "$FILE_CACHE_FILE"
      
      rm "$split_file"
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
  grep "^$file_path|" "$FILE_CACHE_FILE" | cut -d'|' -f2
}

get_dir_mod_time() {
  local dir_path="$1"

  local cached_time=$(grep "^$dir_path|" "$DIR_MOD_TIME_CACHE_FILE" | cut -d'|' -f2)
  if [[ -n "$cached_time" ]]; then
    echo "$cached_time"
    return
  fi

  local max_time=$(awk -F'|' -v path="$dir_path/" '$1 ~ "^"path { if ($2 > max || max=="") max=$2 } END {print max}' "$FILE_CACHE_FILE")

  if [[ -z "$max_time" ]]; then
    local stat_fmt="%Y"
    local stat_opt="-c"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      stat_fmt="%m"
      stat_opt="-f"
    fi
    max_time=$(stat $stat_opt "$stat_fmt" "$GIT_ROOT/$dir_path" 2>/dev/null)
  fi

  echo "$dir_path|$max_time" >> "$DIR_MOD_TIME_CACHE_FILE"

  echo "$max_time"
}

get_all_items() {
  local current_dir="$1"
  local rel_path
  local items_temp_file=$(mktemp)

  if [[ "$current_dir" == "$GIT_ROOT" ]]; then
    rel_path=""
  else
    rel_path="${current_dir#$GIT_ROOT/}"
  fi

  if [[ -z "$rel_path" ]]; then
    grep -E "^[^/]+\|" "$FILE_CACHE_FILE" |
      awk -F'|' '{print $2 "|f|" $1}' >> "$items_temp_file"
  else
    grep -E "^$rel_path/[^/]+\|" "$FILE_CACHE_FILE" |
      awk -F'|' -v path="$rel_path/" '{sub(path, "", $1); print $2 "|f|" $1}' >> "$items_temp_file"
  fi

  local dir_list_file=$(mktemp)

  if [[ -z "$rel_path" ]]; then
    grep -E "/" "$FILE_CACHE_FILE" | cut -d'|' -f1 | cut -d'/' -f1 | grep -v "^\." | sort | uniq > "$dir_list_file"
  else
    grep -E "^$rel_path/" "$FILE_CACHE_FILE" |
      awk -F'|' -v path="$rel_path/" '{
        sub(path, "", $1);
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
      dir_path_full="$rel_path/$dir"
    fi

    local mod_time=$(get_dir_mod_time "$dir_path_full")

    if [[ -n "$mod_time" ]]; then
      echo "$mod_time|d|$dir/" >> "$items_temp_file"
    fi
  done < "$dir_list_file"

  rm "$dir_list_file"

  if [[ -s "$items_temp_file" ]]; then
    sort -t'|' -k1,1nr "$items_temp_file"
  fi

  rm "$items_temp_file"
}

get_directory_preview() {
  local dir_path="$1"
  local max_items="$2"
  local full_path="$GIT_ROOT/$dir_path"

  local all_items=$(get_all_items "$full_path")

  if [[ -z "$all_items" ]]; then
    echo "(Empty directory)"
    return
  fi

  local result=""
  local count=0

  while IFS='|' read -r time type name; do
    if [[ "$type" == "d" ]]; then
      result+="📁 $name\n"
    else
      result+="📄 $name\n"
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
    while read -r item; do
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
        
        local preview=$(get_directory_preview "$dir_path" 3)
        PREVIEWS+=("$preview")
      else
        PREVIEWS+=("")
      fi
    done < <(echo "$sorted_items")
  fi
}

echo "Starting interactive file selection..."
SELECTED_FILES=()
CURRENT_DIR="$GIT_ROOT"

ITEMS=()
ITEM_TYPES=()
MOD_TIMES=()
PREVIEWS=()

build_file_cache
build_dir_mod_time_cache

display_help() {
  tput clear
  tput cup 0 0
  
  echo "Interactive Navigation Commands:"
  echo "  [number]                - Select a file or enter directory"
  echo "  [num1,num2,...]        - Select multiple files by comma-separated list"
  echo "  [num1-num2]            - Select range of files (inclusive)"
  echo "  *                      - Select all files in current directory"
  echo "  **                     - Select all files in current directory and subdirectories"
  echo "  ..                     - Go up to parent directory"
  echo "  /                      - Return to repository root directory"
  echo "  /path/to/dir           - Navigate directly to a specific directory"
  echo "  /path/to/file.ext      - Select a specific file directly"
  echo "  [empty]                - Press Enter with no input to finish selection and copy to clipboard"
  echo "  l                      - List currently selected files"
  echo "  q                      - Quit without processing"
  echo "  h, ?                   - Show this help"
  echo ""
  echo "Navigation Tips:"
  echo "  • Files and directories are sorted by modification time (most recent first)"
  echo "  • Only git-tracked files are shown (respects .gitignore)"
  echo "  • Hidden files and directories (starting with .) are excluded"
  echo "  • The output will follow directory structure for better LLM understanding"
  echo ""
  echo "---------------------------------------------"
  read -p "Press Enter to return to file selection..." 
}

show_files() {
  local current_dir="$1"
  local items_index=()
  
  cd "$current_dir" || return
  
  tput clear
  tput cup 0 0
  
  echo "Directory: $current_dir"
  echo "Selected: ${#SELECTED_FILES[@]} files"
  echo "---------------------------------------------"
  
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
        done < <(echo -e "$preview")
      fi
    else
      echo "[$idx] 📄 $item"
    fi

    ((item_count++))

    items_index[$idx]="$type:$item"
    ((idx++))
  done
  
  echo "---------------------------------------------"
  echo "Commands:"
  echo "  [..] up, [/] root, [/path] jump"
  echo "  [l] list, [q] quit, [h] help"
  echo "  [Enter] finish & copy to clipboard"
  echo "---------------------------------------------"
  
  read -p "> " selection
  
  case "$selection" in
    ""|"done"|"d")
      echo "Finishing selection with ${#SELECTED_FILES[@]} files..."
      return 1
      ;;
    "help"|"h"|"?")
      display_help
      ;;
    "list"|"l"|"ls")
      tput clear
      tput cup 0 0
      
      echo "Currently selected files:"
      if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
        echo "  (No files selected yet)"
      else
        for ((j=0; j<${#SELECTED_FILES[@]}; j++)); do
          echo "  ${SELECTED_FILES[$j]}"
        done
      fi
      
      echo ""
      echo "---------------------------------------------"
      read -p "Press Enter to return to file selection..." 
      ;;
    "quit"|"q"|"exit")
      echo "Exiting without processing files."
      exit 0
      ;;
    "..")
      if [[ "$CURRENT_DIR" != "$GIT_ROOT" ]]; then
        CURRENT_DIR="$(dirname "$CURRENT_DIR")"
      else
        echo "Already at repository root"
      fi
      ;;
    "/"*)
      if [[ "$selection" == "/" ]]; then
        CURRENT_DIR="$GIT_ROOT"
        echo "Returned to repository root"
      else
        # Extract the path after the /
        local requested_path="${selection:1}"
        local target_path="$GIT_ROOT/$requested_path"

        # Check if it's a directory
        if [[ -d "$target_path" ]]; then
          CURRENT_DIR="$target_path"
          echo "Navigated to: $requested_path"
        # Check if it's a file
        elif [[ -f "$target_path" ]]; then
          if [[ ! " ${SELECTED_FILES[*]} " =~ " ${target_path} " ]]; then
            SELECTED_FILES+=("$target_path")
            echo "Selected: $requested_path"
          else
            echo "Already selected: $requested_path"
          fi
        else
          echo "Path not found: $requested_path"
        fi
      fi
      ;;
    "*")
      local count=0
      for i in "${!ITEMS[@]}"; do
        local type="${ITEM_TYPES[$i]}"
        local name="${ITEMS[$i]}"

        if [ "$type" == "f" ]; then
          local full_path="$CURRENT_DIR/$name"
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

      while IFS= read -r line; do
        file_path=$(echo "$line" | cut -d'|' -f1)
        if [[ -z "$file_path" ]]; then continue; fi

        full_path="$GIT_ROOT/$file_path"

        if [[ ! " ${SELECTED_FILES[*]} " =~ " $full_path " ]]; then
          SELECTED_FILES+=("$full_path")
          ((count++))
        fi
      done < <(grep "^$rel_path" "$FILE_CACHE_FILE")

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
              local full_path="$CURRENT_DIR/$name"
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
          echo "Invalid range: $selection"
        fi
      else
        echo "Invalid range format: $selection"
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
              local full_path="$CURRENT_DIR/$name"
              if [[ ! -f "$full_path" ]]; then
                continue
              elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
                continue
              else
                SELECTED_FILES+=("$full_path")
                ((count++))
              fi
            elif [ "$type" == "d" ]; then
              echo "Note: Cannot select directory #$num ($name) in a list - use individual selection to navigate"
            fi
          else
            echo "Skipping invalid selection: $num"
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
            echo "Warning: File not found at path: $full_path"
          elif [[ " ${SELECTED_FILES[*]} " =~ " ${full_path} " ]]; then
            echo "Already selected: $name"
          else
            SELECTED_FILES+=("$full_path")
            echo "Selected: $name"
          fi
        fi
      else
        echo "Invalid selection: $selection"
      fi
      ;;

    *)
      echo "Invalid selection: $selection"
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
  
  sort -V "$LIST_FILE" > "${LIST_FILE}.tree"
  mv "${LIST_FILE}.tree" "$LIST_FILE"
  
  cp "$LIST_FILE" "$ORDER_FILE"
  
  PREV_PARTS=()
  INDENT_CACHE=()
  for ((i=0; i<10; i++)); do
    INDENT_CACHE[i]=$(printf '|   %.0s' $(seq 1 $i))
  done

  get_indent() {
    local depth=$1
    if [ "$depth" -lt 10 ]; then
      echo "${INDENT_CACHE[$depth]}"
    else
      printf '|   %.0s' $(seq 1 $depth)
    fi
  }

  while IFS= read -r FILE_PATH; do
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
    FILE="$GIT_ROOT/$REL_PATH"
    if [[ ! -f "$FILE" ]]; then
      echo "Error: File not found: $FILE" >&2
      continue
    fi
    
    echo -e "\n\n"
    echo -e "########"
    echo -e "# FILE: $FILE"
    echo -e "########"
    echo -e "\n<file-contents>"
    cat "$FILE"
    
    if [ -s "$FILE" ] && [ "$(tail -c1 "$FILE")" != "$(printf '\n')" ]; then
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