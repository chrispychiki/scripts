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
#   - Automatically excludes binary files
#   - Clipboard integration for direct pasting into LLM interfaces
#   - Cross-platform support for macOS and Linux
#
# DEPENDENCIES:
#   - git: For repository detection and file listing
#   - file: For binary file detection
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
#   ..             Go up to the parent directory
#   d              Done, finish selection and generate output
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
# AUTHOR:
#   Chris Kim
#
# REPOSITORY:
#   This script is part of the scripts repository containing various
#   development utilities. See /Users/chriskim/scripts/CLAUDE.md for
#   more information about repository conventions and expectations.
# =========================================================================

# Parse command line arguments
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
  echo "  ..                       Go up to the parent directory"
  echo "  d                        Done, finish selection and generate output"
  echo "  l                        List currently selected files"
  echo "  q                        Quit without generating output"
  echo "  h                        Show help for commands"
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

# Navigate to repository
cd "$REPO_PATH" || { echo "Error: Cannot access repository path"; exit 1; }

# Check if this is a git repository
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "Error: Not a git repository. This script only works in git repositories."
  exit 1
fi

# Get the git root directory
GIT_ROOT=$(git rev-parse --show-toplevel)

# Create temporary files
TEMP_FILE=$(mktemp)
LIST_FILE=$(mktemp)
ORDER_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE" "$LIST_FILE" "$ORDER_FILE"' EXIT

# Function to detect binary file
is_binary() {
  file --mime "$1" | grep -q "charset=binary"
}

# Efficient cache to store file paths and modification times
# Format: path1|modtime1\npath2|modtime2\n...
FILE_CACHE=""
DIR_MOD_TIME_CACHE=""

# Build file modification time cache
build_file_cache() {
  # Platform-specific stat command
  local stat_fmt="%Y"
  local stat_opt="-c"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat_fmt="%m"
    stat_opt="-f"
  fi

  # Get all git-tracked files (excluding hidden files) with a single command
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_file_cache]: Building file cache..." >&2
  fi

  # Get the list of files and ensure we properly grep out hidden files
  local files=$(git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\.")
  local file_count=$(echo "$files" | wc -l)

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_file_cache]: Found $file_count files from git" >&2
  fi

  while IFS= read -r file; do
    if [[ -z "$file" ]]; then
      continue  # Skip empty lines
    fi

    if [[ "$file" =~ /\.|^\. ]]; then
      continue  # Skip hidden files (double-check)
    fi

    local full_path="$GIT_ROOT/$file"
    if [[ -f "$full_path" && ! -d "$full_path" ]] && ! is_binary "$full_path"; then
      # Get file modification time
      local mod_time=$(stat $stat_opt "$stat_fmt" "$full_path" 2>/dev/null)
      if [[ -n "$mod_time" ]]; then
        # Add to cache
        FILE_CACHE+="$file|$mod_time\n"
      fi
    fi
  done < <(echo "$files")

  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local cache_count=$(echo -e "$FILE_CACHE" | wc -l)
    echo "DEBUG [build_file_cache]: Added $cache_count files to cache" >&2
  fi
}

# Build directory modification time cache
build_dir_mod_time_cache() {
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    echo "DEBUG [build_dir_mod_time_cache]: Building directory modification time cache..." >&2
  fi
  
  # Get unique directories from file paths
  local dirs=()
  local dir=""
  
  while read -r line; do
    local file_path="${line%%|*}"
    if [[ "$file_path" == */* ]]; then
      dir=$(dirname "$file_path")
      
      # Add all parent directories
      local curr_dir="$dir"
      while [[ -n "$curr_dir" && "$curr_dir" != "." ]]; do
        if [[ ! " ${dirs[*]} " =~ " $curr_dir " ]]; then
          dirs+=("$curr_dir")
        fi
        curr_dir=$(dirname "$curr_dir")
      done
    fi
  done < <(echo -e "$FILE_CACHE")
  
  # Calculate the modification time for each directory (max of contained files)
  for dir in "${dirs[@]}"; do
    local pattern="^$dir/"
    local matches=$(echo -e "$FILE_CACHE" | grep "$pattern")
    local max_time=$(echo "$matches" | cut -d'|' -f2 | sort -nr | head -n1)
    
    if [[ -n "$max_time" ]]; then
      DIR_MOD_TIME_CACHE+="$dir|$max_time\n"
    fi
  done
  
  if [[ "$DEBUG_MODE" -eq 1 ]]; then
    local cache_count=$(echo -e "$DIR_MOD_TIME_CACHE" | wc -l)
    echo "DEBUG [build_dir_mod_time_cache]: Added $cache_count directories to cache" >&2
  fi
}

# Get modification time for a file from cache
get_file_mod_time() {
  local file_path="$1"
  echo -e "$FILE_CACHE" | grep "^$file_path|" | cut -d'|' -f2
}

# Get directory modification time from cache
get_dir_mod_time() {
  local dir_path="$1"
  
  # Try getting from cache first
  local cached_time=$(echo -e "$DIR_MOD_TIME_CACHE" | grep "^$dir_path|" | cut -d'|' -f2)
  
  if [[ -n "$cached_time" ]]; then
    echo "$cached_time"
    return
  fi
  
  # If not in cache, calculate it
  local pattern="^$dir_path/"
  local matches=$(echo -e "$FILE_CACHE" | grep "$pattern")
  local max_time=$(echo "$matches" | cut -d'|' -f2 | sort -nr | head -n1)
  
  # Fall back to directory's own time if no files found
  if [[ -z "$max_time" ]]; then
    local stat_fmt="%Y"
    local stat_opt="-c"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      stat_fmt="%m"
      stat_opt="-f"
    fi
    max_time=$(stat $stat_opt "$stat_fmt" "$GIT_ROOT/$dir_path" 2>/dev/null)
  fi
  
  # Add to cache for future use
  DIR_MOD_TIME_CACHE+="$dir_path|$max_time\n"
  
  echo "$max_time"
}

# Get a list of all items (files and directories) in a path - optimized version
get_all_items() {
  local current_dir="$1"
  local rel_path
  local items_with_times=""

  # Get relative path from git root
  if [[ "$current_dir" == "$GIT_ROOT" ]]; then
    rel_path=""
  else
    rel_path="${current_dir#$GIT_ROOT/}"
  fi

  # Filter pattern construction - much faster than multiple string operations in a loop
  local pattern
  if [[ -z "$rel_path" ]]; then
    # For root directory, we want only files without slashes
    pattern="^[^/]*$"
  else
    # For subdirectories, match files in that exact directory level
    pattern="^$rel_path/[^/]*$"
  fi

  # Process files in this directory - use grep to pre-filter candidates
  # This dramatically reduces the number of iterations needed
  local matching_files=$(echo -e "$FILE_CACHE" | grep -E "$pattern")

  while read -r line; do
    if [[ -z "$line" ]]; then
      continue  # Skip empty lines
    fi

    local file_path="${line%%|*}"
    local mod_time="${line##*|}"

    # For root directory items
    if [[ -z "$rel_path" ]]; then
      items_with_times+="$mod_time|f|$file_path\n"
    # For subdirectory items
    else
      local rel_file="${file_path#$rel_path/}"
      items_with_times+="$mod_time|f|$rel_file\n"
    fi
  done < <(echo "$matching_files")
  
  # Build a list of direct subdirectories more efficiently
  local subdirs=()
  local seen_dirs=""

  while read -r line; do
    if [[ -z "$line" ]]; then
      continue  # Skip empty lines
    fi

    local file_path="${line%%|*}"

    # Extract subdirectory based on current path
    if [[ -z "$rel_path" ]]; then
      # Root directory - get first level directories
      if [[ "$file_path" == */* ]]; then
        local dir="${file_path%%/*}"
        # Faster check with direct string match
        if [[ "$seen_dirs" != *"|$dir|"* ]]; then
          subdirs+=("$dir")
          seen_dirs+="|$dir|"
        fi
      fi
    elif [[ "$file_path" == "$rel_path/"* ]]; then
      # Subdirectory - extract next level directories
      local rel_file="${file_path#$rel_path/}"
      if [[ "$rel_file" == */* ]]; then
        local dir="${rel_file%%/*}"
        # Faster check with direct string match
        if [[ "$seen_dirs" != *"|$dir|"* ]]; then
          subdirs+=("$dir")
          seen_dirs+="|$dir|"
        fi
      fi
    fi
  done < <(echo -e "$FILE_CACHE")
  
  # Add directories with their modification times
  for dir in "${subdirs[@]}"; do
    # Skip hidden directories
    if [[ "$dir" =~ ^\. || "$dir" == "node_modules" || "$dir" == ".git" ]]; then
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
      items_with_times+="$mod_time|d|$dir/\n"
    fi
  done
  
  # Return all items sorted by modification time (newest first)
  if [[ -n "$items_with_times" ]]; then
    echo -e "$items_with_times" | sort -t'|' -k1,1nr
  fi
}

# Get preview of a directory (up to 3 most recent items) - fixed for proper display
get_directory_preview() {
  local dir_path="$1"
  local max_items="$2"
  local full_path="$GIT_ROOT/$dir_path"

  # Get all items in this directory, sorted by recency
  local all_items=$(get_all_items "$full_path")

  # Process and store items in a temporary file for reliable output
  local temp_file=$(mktemp)
  if [[ -n "$all_items" ]]; then
    # Get first max_items entries only
    local count=0
    while IFS='|' read -r time type name; do
      if [[ "$type" == "d" ]]; then
        echo "📁 $name" >> "$temp_file"
      else
        echo "📄 $name" >> "$temp_file"
      fi

      ((count++))
      if [[ $count -eq $max_items ]]; then
        break
      fi
    done < <(echo -e "$all_items")
  fi

  if [[ ! -s "$temp_file" ]]; then
    rm "$temp_file"
    echo "(Empty directory)"
  else
    # Read the file line by line and format output
    cat "$temp_file"
    rm "$temp_file"
  fi
}

# Get contents of current directory
get_directory_contents() {
  local current_dir="$1"
  
  # Get all items with mod times, sorted by recency
  local sorted_items=$(get_all_items "$current_dir")
  
  # Parse items into arrays
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
      
      # Get previews for directories
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
        PREVIEWS+=("")  # Empty preview for files
      fi
    done < <(echo "$sorted_items")
  fi
}

# Start interactive file selection
echo "Starting interactive file selection..."
echo "Enter number to select file or navigate to directory."
SELECTED_FILES=()
CURRENT_DIR="$GIT_ROOT"

# Global arrays for directory contents
ITEMS=()
ITEM_TYPES=()
MOD_TIMES=()
PREVIEWS=()

# Initialize file cache
build_file_cache
build_dir_mod_time_cache

# Show files in the current directory
show_files() {
  local current_dir="$1"
  local items_index=()
  
  # Change to the directory
  cd "$current_dir" || return
  
  # Display current location and selection info
  echo "Directory: $current_dir"
  echo "Selected: ${#SELECTED_FILES[@]} files"
  echo "---------------------------------------------"
  
  # Get all items in this directory, already sorted by modification time
  get_directory_contents "$current_dir"
  
  # Display items
  local idx=0
  local item_count=0
  local max_previews=3

  for i in "${!ITEMS[@]}"; do
    local item="${ITEMS[$i]}"
    local type="${ITEM_TYPES[$i]}"
    local preview="${PREVIEWS[$i]}"
    local show_preview=0

    # Determine if this item should get a preview (only first 3 items that are directories)
    if [[ "$type" == "d" && $item_count -lt $max_previews ]]; then
      show_preview=1
    fi

    # Display item with index
    if [[ "$type" == "d" ]]; then
      echo "[$idx] 📁 $item"

      # Only show previews for the first 3 items in the overall listing
      if [[ $show_preview -eq 1 && "$preview" != "(Empty directory)" ]]; then
        # Create a temporary file and read line by line for proper formatting
        local temp_file=$(mktemp)
        echo "$preview" > "$temp_file"

        # Read line by line with correct formatting
        local line_num=0
        while IFS= read -r line; do
          if [[ $line_num -eq 0 ]]; then
            echo "    └─ $line"
          else
            echo "       $line"
          fi
          ((line_num++))
        done < "$temp_file"

        rm "$temp_file"
      fi
    else
      echo "[$idx] 📄 $item"
    fi

    # Increment item counter regardless of type
    ((item_count++))
    
    # Keep track of original index for selection
    items_index[$idx]="$type:$item"
    ((idx++))
  done
  
  # Show command prompt
  echo "---------------------------------------------"
  echo "Commands: [..] up, [d] done, [l] list, [q] quit, [h] help"
  echo "---------------------------------------------"
  
  # Get user input
  read -p "> " selection
  
  # Process selection
  case "$selection" in
    "help"|"h"|"?")
      echo "Interactive Navigation Commands:"
      echo "  [number]  - Select a file or enter directory"
      echo "  ..        - Go up to parent directory"
      echo "  d         - Done, finish selection and generate LLM-ready output"
      echo "  l         - List currently selected files"
      echo "  q         - Quit without processing"
      echo "  h, ?      - Show this help"
      echo ""
      echo "Navigation Tips:"
      echo "  • Files and directories are sorted by modification time (most recent first)"
      echo "  • Only git-tracked files are shown (respects .gitignore)"
      echo "  • Hidden files and directories (starting with .) are excluded"
      echo "  • Binary files are automatically filtered out"
      echo "  • The output will follow directory structure for better LLM understanding"
      ;;
    "done"|"d")
      echo "Finishing selection with ${#SELECTED_FILES[@]} files..."
      return 1
      ;;
    "list"|"l"|"ls")
      echo "Currently selected files:"
      for ((j=0; j<${#SELECTED_FILES[@]}; j++)); do
        echo "  ${SELECTED_FILES[$j]}"
      done
      ;;
    "quit"|"q"|"exit")
      echo "Exiting without processing files."
      exit 0
      ;;
    "..")
      # Go up one directory level
      if [[ "$CURRENT_DIR" != "$GIT_ROOT" ]]; then
        CURRENT_DIR="$(dirname "$CURRENT_DIR")"
      else
        echo "Already at repository root"
      fi
      ;;
    *)
      # Check if input is a number within range
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "$idx" ]; then
        local item="${items_index[$selection]}"
        local type="${item%%:*}"
        local name="${item#*:}"
        
        if [ "$type" == "d" ]; then
          # Navigate into directory (remove trailing slash)
          CURRENT_DIR="$CURRENT_DIR/${name%/}"
        elif [ "$type" == "f" ]; then
          # Add file to selection if not already selected
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
  esac
  
  return 0
}

# Main loop for file selection
while true; do
  show_files "$CURRENT_DIR"
  if [ $? -eq 1 ]; then
    break
  fi
done

# Check if any files were selected
if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
  echo "No files were selected, nothing to copy."
  exit 0
fi

echo "Formatting ${#SELECTED_FILES[@]} files for LLM interaction..."

# Build output into temporary file
{
  # Repository header - use git root name for consistency
  REPO_BASENAME=$(basename "$GIT_ROOT")
  echo "# Repository: $REPO_BASENAME ($GIT_ROOT)"
  echo "# Files: ${#SELECTED_FILES[@]}"
  echo ""
  
  # Directory Structure visualization
  echo "## Directory Structure"
  echo '```'
  echo "$GIT_ROOT"
  
  # Clear the file list and fill it with selected files for the directory tree
  > "$LIST_FILE"
  
  # Collect file paths for SELECTED files only, relative to git root
  for FILE in "${SELECTED_FILES[@]}"; do
    REL_PATH="${FILE#"$GIT_ROOT/"}"
    echo "$REL_PATH" >> "$LIST_FILE"
  done
  
  # Sort file paths by directory structure for a logical tree view
  sort -V "$LIST_FILE" > "${LIST_FILE}.tree"
  mv "${LIST_FILE}.tree" "$LIST_FILE"
  
  # Store the ordered list for file content generation
  cp "$LIST_FILE" "$ORDER_FILE"
  
  # Build tree structure
  PREV_PARTS=()
  while IFS= read -r FILE_PATH; do
    if [[ "$FILE_PATH" != *"/"* ]]; then
      # Root file
      echo "+-- $FILE_PATH"
      continue
    fi
    
    # Split path into components
    DIR_PATH=$(dirname "$FILE_PATH")
    FILENAME=$(basename "$FILE_PATH")
    
    # Split directory into parts
    IFS='/' read -ra CURR_PARTS <<< "$DIR_PATH"
    
    # Find the common prefix length
    COMMON_PREFIX_LEN=0
    for ((i=0; i<${#PREV_PARTS[@]} && i<${#CURR_PARTS[@]}; i++)); do
      if [[ "${PREV_PARTS[i]}" == "${CURR_PARTS[i]}" ]]; then
        ((COMMON_PREFIX_LEN++))
      else
        break
      fi
    done
    
    # Print new directory parts
    for ((i=COMMON_PREFIX_LEN; i<${#CURR_PARTS[@]}; i++)); do
      INDENT=$(printf '|   %.0s' $(seq 1 $i))
      if [[ $i -eq 0 ]]; then
        echo "+-- ${CURR_PARTS[i]}"
      else
        echo "$INDENT+-- ${CURR_PARTS[i]}"
      fi
    done
    
    # Print the file
    INDENT=$(printf '|   %.0s' $(seq 1 ${#CURR_PARTS[@]}))
    echo "$INDENT+-- $FILENAME"
    
    # Save current path parts for next iteration
    PREV_PARTS=("${CURR_PARTS[@]}")
  done < "$LIST_FILE"
  
  echo '```'
  echo ""
  
  # Add file contents in the same order as the directory tree
  while IFS= read -r REL_PATH; do
    FILE="$GIT_ROOT/$REL_PATH"
    if [[ ! -f "$FILE" ]]; then
      echo "Error: File not found: $FILE" >&2
      continue
    fi
    
    # Skip binary files and handle missing files
    if [[ ! -f "$FILE" ]]; then
      echo "Warning: File not found or was removed: $FILE" >&2
      continue
    elif is_binary "$FILE"; then
      echo "Warning: Skipping binary file: $FILE" >&2
      continue
    fi
    
    # Add file header and content with visible separator
    echo -e "\n\n"
    echo -e "###############################################################"
    echo -e "# FILE: $FILE"
    echo -e "###############################################################"
    echo -e "\n<file-contents>"
    cat "$FILE"
    
    # Add newline if the file doesn't end with one
    if [ "$(tail -c1 "$FILE" | wc -l)" -eq 0 ]; then
      echo ""
    fi
    echo "</file-contents>"
  done < "$ORDER_FILE"
} > "$TEMP_FILE"

# Copy to clipboard
CLIPBOARD_SUCCESS=0
if command -v pbcopy &> /dev/null; then
  if cat "$TEMP_FILE" | pbcopy; then
    CLIPBOARD_SUCCESS=1
  fi
elif command -v xclip &> /dev/null; then
  if cat "$TEMP_FILE" | xclip -selection clipboard; then
    CLIPBOARD_SUCCESS=1
  fi
fi

if [ $CLIPBOARD_SUCCESS -eq 1 ]; then
  echo "Repository files copied to clipboard successfully!"
else
  echo "Unable to copy to clipboard. Output saved to: $TEMP_FILE"
  # Release file from trap so it doesn't get deleted
  trap - EXIT
fi

# Debug output
if [ $DEBUG_MODE -eq 1 ]; then
  echo "=== DEBUG: OUTPUT CONTENTS ==="
  cat "$TEMP_FILE"
  echo "=== END DEBUG OUTPUT ==="
fi

# Done - just output one completion message
echo "Done! Repository files copied to clipboard for LLM chat."
exit 0