#!/bin/bash

# repo2llm: Generate structured repository output for LLMs
# Usage: ./repo2llm.sh [repository_path] [options]
# Options:
#   -d, --debug              Debug mode to display the output
#   -h, --help               Show help

# Parse command line arguments
REPO_PATH="."
DEBUG_MODE=0

print_usage() {
  echo "Usage: $0 [repository_path] [options]"
  echo "Options:"
  echo "  -d, --debug              Debug mode to display the output"
  echo "  -h, --help               Show help"
  echo ""
  echo "Examples:"
  echo "  $0 ~/my-project"
  echo "  $0 ~/my-project -d       # Debug mode"
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
trap 'rm -f "$TEMP_FILE" "$LIST_FILE"' EXIT

# Function to detect binary file
is_binary() {
  file --mime "$1" | grep -q "charset=binary"
}

# Function to list files and directories in the current path
list_files_and_dirs() {
  local current_dir="$1"
  local dirs=()
  local files=()
  
  # Get the relative path from the git root
  local rel_path
  if [[ "$current_dir" == "$GIT_ROOT" ]]; then
    rel_path=""
  else
    rel_path="${current_dir#$GIT_ROOT/}/"
  fi
  
  # List all directories that exist physically at this level
  for d in "$current_dir"/*; do
    if [[ -d "$d" && ! "$(basename "$d")" =~ ^\. && 
          "$(basename "$d")" != "node_modules" && 
          "$(basename "$d")" != ".git" ]]; then
      dirs+=("$(basename "$d")")
    fi
  done
  
  # Get git-tracked files in this directory
  if [[ -z "$rel_path" ]]; then
    # Root level
    while IFS= read -r line; do
      if [[ "$line" != */* && -f "$GIT_ROOT/$line" && ! "$line" =~ ^\. ]]; then
        # Root-level file
        if [[ ! -d "$GIT_ROOT/$line" ]] && ! is_binary "$GIT_ROOT/$line"; then
          files+=("$line")
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
          files+=("${line#$rel_path}")
        fi
      fi
    done < <(git -C "$GIT_ROOT" ls-files "$rel_path" | grep -v "^\." | grep -v "/\.")
  fi
  
  # Return arrays through variable references
  eval "$2=(${dirs[*]@Q})"
  eval "$3=(${files[*]@Q})"
}

# Start interactive file selection
echo "Starting interactive file selection..."
SELECTED_FILES=()
CURRENT_DIR="$(pwd)"

# Show files in the current directory
show_files() {
  local current_dir="$1"
  local dir_list=()
  local file_list=()
  local items=()
  local i=0
  
  # Change to the directory
  cd "$current_dir" || return
  
  # Display current location and selection info
  echo "Current directory: $current_dir"
  echo "Selected files: ${#SELECTED_FILES[@]}"
  echo "---------------------------------------------"
  
  # Get directories and files in this location
  list_files_and_dirs "$current_dir" dir_list file_list
  
  # Sort the arrays
  IFS=$'\n' 
  sorted_dirs=($(sort <<<"${dir_list[*]}"))
  sorted_files=($(sort <<<"${file_list[*]}"))
  unset IFS
  
  # Print directories with folder emoji
  for dir in "${sorted_dirs[@]}"; do
    echo "[$i] 📁 $dir/"
    items[$i]="d:$dir"
    ((i++))
  done
  
  # Print files with file emoji
  for file in "${sorted_files[@]}"; do
    echo "[$i] 📄 $file"
    items[$i]="f:$file"
    ((i++))
  done
  
  # Show command prompt
  echo "---------------------------------------------"
  echo "Commands: [#] select/enter, [..] up, [d] done, [h] help"
  echo "---------------------------------------------"
  
  # Get user input
  read -p "> " selection
  
  # Process selection
  case "$selection" in
    "help"|"h"|"?")
      echo "Commands:"
      echo "  [number]  - Select a file or enter directory"
      echo "  ..        - Go up to parent directory"
      echo "  d         - Done, finish selection and process files"
      echo "  l         - List currently selected files"
      echo "  q         - Quit without processing"
      echo "  h, ?      - Show this help"
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
  # Repository header
  REPO_BASENAME=$(basename "$(pwd)")
  echo "# Repository: $REPO_BASENAME ($(pwd))"
  echo ""
  
  # Directory Structure visualization
  echo "## Directory Structure"
  echo '```'
  echo "$(pwd)"
  
  # Clear the file list first
  > "$LIST_FILE"
  
  # Collect file paths for SELECTED files only
  for FILE in "${SELECTED_FILES[@]}"; do
    REL_PATH="${FILE#"$(pwd)/"}"
    echo "$REL_PATH" >> "$LIST_FILE"
  done
  
  # Sort file paths
  sort "$LIST_FILE" > "${LIST_FILE}.sorted"
  mv "${LIST_FILE}.sorted" "$LIST_FILE"
  
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
  
  # Add file contents
  for FILE in "${SELECTED_FILES[@]}"; do
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
  done
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

echo "Done! Files ready for LLM chat."
exit 0