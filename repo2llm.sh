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
#   - Interactive navigation with files sorted by modification time (most recent first)
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
  echo "  - Interactive directory navigation with files sorted by recency"
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

# Function to list files and directories in the current path sorted by modification time
list_files_and_dirs() {
  local current_dir="$1"
  local dirs=()
  local files=()
  local dir_mod_times=()
  local file_mod_times=()
  local dir_previews=()

  # Get the relative path from the git root
  local rel_path
  if [[ "$current_dir" == "$GIT_ROOT" ]]; then
    rel_path=""
  else
    rel_path="${current_dir#$GIT_ROOT/}/"
  fi

  # List all directories that exist physically at this level
  # with their modification times for sorting
  for d in "$current_dir"/*; do
    if [[ -d "$d" && ! "$(basename "$d")" =~ ^\. &&
          "$(basename "$d")" != "node_modules" &&
          "$(basename "$d")" != ".git" ]]; then
      local dir_name="$(basename "$d")"
      # Get the last modification time of the directory
      local mod_time=$(stat -f "%m" "$d" 2>/dev/null || stat -c "%Y" "$d" 2>/dev/null)
      if [[ -n "$mod_time" ]]; then
        # Generate a preview of directory contents (most recently modified files)
        # respecting .gitignore
        # Setup stat format based on platform
        local stat_fmt="%Y"
        local stat_opt="-c"
        if [[ "$OSTYPE" == "darwin"* ]]; then
          stat_fmt="%m"
          stat_opt="-f"
        fi

        # Get dir path relative to git root for git ls-files
        local dir_rel_path
        if [[ "$d" == "$GIT_ROOT" ]]; then
          dir_rel_path=""
        else
          dir_rel_path="${d#$GIT_ROOT/}"
        fi

        # Get the 3 most recently modified git-tracked files in this directory
        local preview=""

        # Create a temporary file for collecting files with modification times
        local tmp_preview_file=$(mktemp)

        # Get list of files directly in this directory (not subdirectories)
        if [[ -z "$dir_rel_path" ]]; then
          # Root directory - no path prefix
          git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\." | grep -v "/" > "$tmp_preview_file"
        else
          # Subdirectory - filter files directly in this directory
          git -C "$GIT_ROOT" ls-files "$dir_rel_path/" | grep -v "^\." | grep -v "/\." |
          grep "^$dir_rel_path/[^/]*$" | sed "s|^$dir_rel_path/||" > "$tmp_preview_file"
        fi

        # Get the most recently modified files
        if [[ -s "$tmp_preview_file" ]]; then
          # Get full paths and modification times
          preview=$(
            while read -r file; do
              if [[ -z "$dir_rel_path" ]]; then
                # Root directory
                full_path="$GIT_ROOT/$file"
              else
                # Subdirectory
                full_path="$GIT_ROOT/$dir_rel_path/$file"
              fi

              if [[ -f "$full_path" && ! -d "$full_path" ]]; then
                mod_time=$(stat $stat_opt "$stat_fmt" "$full_path" 2>/dev/null)
                [[ -n "$mod_time" ]] && echo "$mod_time $file"
              fi
            done < "$tmp_preview_file" |
            sort -rn | head -n 3 | cut -d' ' -f2- | sed 's/^/• /'
          )
        fi

        # Clean up temporary file
        rm -f "$tmp_preview_file"
        dirs+=("$dir_name")
        dir_mod_times+=("$mod_time:$dir_name")
        dir_previews+=("$preview")
      fi
    fi
  done
  
  # Get git-tracked files in this directory with modification times
  if [[ -z "$rel_path" ]]; then
    # Root level
    while IFS= read -r line; do
      if [[ "$line" != */* && -f "$GIT_ROOT/$line" && ! "$line" =~ ^\. ]]; then
        # Root-level file
        if [[ ! -d "$GIT_ROOT/$line" ]] && ! is_binary "$GIT_ROOT/$line"; then
          # Get modification time
          local mod_time=$(stat -f "%m" "$GIT_ROOT/$line" 2>/dev/null || stat -c "%Y" "$GIT_ROOT/$line" 2>/dev/null)
          if [[ -n "$mod_time" ]]; then
            files+=("$line")
            file_mod_times+=("$mod_time:$line")
          fi
        fi
      fi
    done < <(git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\.")
  else
    # Subdirectory
    while IFS= read -r line; do
      local file_rel_path="${line#$rel_path}"
      if [[ "$line" == "$rel_path"* && "$file_rel_path" != */* && -f "$GIT_ROOT/$line" ]]; then
        # No more directories in path, file in this directory
        if ! is_binary "$GIT_ROOT/$line"; then
          # Get modification time
          local mod_time=$(stat -f "%m" "$GIT_ROOT/$line" 2>/dev/null || stat -c "%Y" "$GIT_ROOT/$line" 2>/dev/null)
          if [[ -n "$mod_time" ]]; then
            local file_name="${line#$rel_path}"
            files+=("$file_name")
            file_mod_times+=("$mod_time:$file_name")
          fi
        fi
      fi
    done < <(git -C "$GIT_ROOT" ls-files "$rel_path" | grep -v "^\." | grep -v "/\.")
  fi
  
  # Sort by modification time (most recent first)
  IFS=$'\n'
  sorted_dir_times=($(for time_dir in "${dir_mod_times[@]}"; do echo "$time_dir"; done | sort -rn))
  sorted_file_times=($(for time_file in "${file_mod_times[@]}"; do echo "$time_file"; done | sort -rn))
  unset IFS

  # Create a simple array to keep track of dir-preview pairs before sorting
  local dir_preview_pairs=()
  for i in "${!dirs[@]}"; do
    dir_preview_pairs+=("${dir_mod_times[$i]}:${dir_previews[$i]}")
  done

  # Clear the arrays for sorted content
  dirs=()
  files=()
  dir_previews=()

  # Rebuild arrays in modification time order
  for time_dir in "${sorted_dir_times[@]}"; do
    local sorted_dir="${time_dir#*:}"
    dirs+=("$sorted_dir")

    # Find the matching preview
    for pair in "${dir_preview_pairs[@]}"; do
      if [[ "$pair" == "$time_dir:"* ]]; then
        dir_previews+=("${pair#*:}")
        break
      fi
    done
  done

  for time_file in "${sorted_file_times[@]}"; do
    files+=("${time_file#*:}")
  done
  
  # Return arrays through variable references
  eval "$2=(${dirs[*]@Q})"
  eval "$3=(${files[*]@Q})"
  eval "$4=(${dir_previews[*]@Q})"
}

# Start interactive file selection
echo "Starting interactive file selection..."
echo "Enter number to select file or navigate to directory."
SELECTED_FILES=()
CURRENT_DIR="$(pwd)"

# Show files in the current directory
show_files() {
  local current_dir="$1"
  local dir_list=()
  local file_list=()
  local dir_preview_list=()
  local items=()
  local i=0

  # Change to the directory
  cd "$current_dir" || return

  # Display current location and selection info
  echo "Directory: $current_dir"
  echo "Selected: ${#SELECTED_FILES[@]} files"
  echo "---------------------------------------------"

  # Get directories and files in this location
  list_files_and_dirs "$current_dir" dir_list file_list dir_preview_list

  # The lists are already sorted by modification time through list_files_and_dirs
  sorted_dirs=("${dir_list[@]}")
  sorted_files=("${file_list[@]}")

  # Print directories with folder emoji and preview of contents
  local preview_idx=0

  # Reset counter properly with local scope
  i=0  # Ensure we start from 0
  for dir in "${sorted_dirs[@]}"; do
    echo "[$i] 📁 $dir/"

    # Generate direct preview for this directory
    local dir_path="$current_dir/$dir"
    local preview_files=()

    # Get overview of this directory
    if [[ -d "$dir_path" ]]; then
      local dir_rel_path="${dir_path#$GIT_ROOT/}"

      # Get a combined list of directories and files, sorted by modification time
      local all_items=()
      local all_item_times=()

      # Find subdirectories that are part of git repo (by checking .git existence)
      # Get list of filtered directories from find (non-hidden only)
      while read -r d; do
        local dir_name=$(basename "$d")
        # Only include directories that are not hidden
        if [[ ! "$dir_name" =~ ^\. && -d "$d" && "$dir_name" != "node_modules" ]]; then
          # Check for files in Git inside this directory
          local dir_rel_to_git="${d#$GIT_ROOT/}"
          # Count matching files in git that start with this directory path
          if [[ -z "$dir_rel_to_git" || "$d" == "$GIT_ROOT" ]]; then
            # Special case for root - should never happen here
            continue
          else
            # Check if this directory has any git-tracked files within it
            local git_file_count=$(git -C "$GIT_ROOT" ls-files "$dir_rel_to_git/" | wc -l)
            if [[ $git_file_count -gt 0 ]]; then
              # Get modification time
              local mod_time
              if [[ "$OSTYPE" == "darwin"* ]]; then
                mod_time=$(stat -f "%m" "$d" 2>/dev/null)
              else
                mod_time=$(stat -c "%Y" "$d" 2>/dev/null)
              fi
              if [[ -n "$mod_time" ]]; then
                all_items+=("$dir_name/")  # Add trailing slash to directories
                all_item_times+=("$mod_time:$dir_name/")
              fi
            fi
          fi
        fi
      done < <(find "$dir_path" -maxdepth 1 -type d -not -path "$dir_path")

      # Get files with modification times
      if [[ "$dir_path" == "$GIT_ROOT" ]]; then
        # Root level files
        while read -r file; do
          local full_path="$GIT_ROOT/$file"
          if [[ -f "$full_path" && ! "$file" =~ ^\. ]]; then
            # Get modification time
            local mod_time
            if [[ "$OSTYPE" == "darwin"* ]]; then
              mod_time=$(stat -f "%m" "$full_path" 2>/dev/null)
            else
              mod_time=$(stat -c "%Y" "$full_path" 2>/dev/null)
            fi
            if [[ -n "$mod_time" ]]; then
              all_items+=("$file")
              all_item_times+=("$mod_time:$file")
            fi
          fi
        done < <(git -C "$GIT_ROOT" ls-files | grep -v "^\." | grep -v "/\." | grep -v "/")
      else
        # Subdirectory files
        while read -r file; do
          local full_path="$GIT_ROOT/$file"
          local file_rel_path="${file#$dir_rel_path/}"
          if [[ "$file" == "$dir_rel_path"* && "$file_rel_path" != */* && -f "$full_path" ]]; then
            # Get modification time
            local mod_time
            if [[ "$OSTYPE" == "darwin"* ]]; then
              mod_time=$(stat -f "%m" "$full_path" 2>/dev/null)
            else
              mod_time=$(stat -c "%Y" "$full_path" 2>/dev/null)
            fi
            if [[ -n "$mod_time" ]]; then
              all_items+=("$(basename "$full_path")")
              all_item_times+=("$mod_time:$(basename "$full_path")")
            fi
          fi
        done < <(git -C "$GIT_ROOT" ls-files "$dir_rel_path/" | grep -v "^\." | grep -v "/\.")
      fi

      # Sort all items by modification time
      IFS=$'\n'
      sorted_item_times=($(for time_item in "${all_item_times[@]}"; do echo "$time_item"; done | sort -rn))
      unset IFS

      # Get top 3 items
      local preview=""
      for ((idx=0; idx<${#sorted_item_times[@]} && idx<3; idx++)); do
        local item="${sorted_item_times[$idx]#*:}"
        if [[ -n "$preview" ]]; then
          preview="$preview"$'\n'"$item"
        else
          preview="$item"
        fi
      done

      # Display the preview
      if [[ -n "$preview" ]]; then
        echo "    └─ $(echo "$preview" | head -n 1)"
        echo "$preview" | tail -n +2 | sed 's/^/       /'
      else
        echo "    └─ (Empty directory)"
      fi
    fi

    items[$i]="d:$dir"
    ((i++))
    ((preview_idx++))
  done
  
  # Print files with file emoji
  for file in "${sorted_files[@]}"; do
    echo "[$i] 📄 $file"
    items[$i]="f:$file"
    ((i++))
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
      echo "  • Files are sorted by modification time (most recent first)"
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
      if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -lt "$i" ]; then
        local item="${items[$selection]}"
        local type="${item%%:*}"
        local name="${item#*:}"
        
        if [ "$type" == "d" ]; then
          # Navigate into directory
          CURRENT_DIR="$CURRENT_DIR/$name"
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
    
    # Skip binary files
    if is_binary "$FILE"; then
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