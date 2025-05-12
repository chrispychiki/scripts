# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository contains a collection of utility scripts designed to enhance development workflows. The repository serves as a centralized location for various command-line utilities and helper scripts that optimize different aspects of software development.

## Scripts Overview

Current scripts:

- `repo2llm.sh`: Utility to interactively select files from a git repository, format them with directory structure, and copy to clipboard for LLM interactions

## Bash Script Conventions

When adding new scripts or modifying existing ones:

- Scripts should be self-contained and focused on a single purpose
- Include detailed usage instructions and examples at the top of each script
- Implement proper error handling and status code returns
- Use portable shell constructs when possible for cross-platform compatibility
- Add clear command-line option handling with comprehensive help text
- Follow a consistent structure:
  - Header block with description, usage and examples
  - Command-line argument parsing
  - Main functionality implementation
  - Helper functions defined before they're used
  - Exit with appropriate status codes

## Cross-platform Compatibility

Scripts should work across different Unix-like systems:

- Use platform detection for OS-specific functionality
- Provide fallbacks when commands differ between systems (e.g., `stat` options)
- Test on both macOS and Linux when possible
- Handle clipboard operations with support for multiple platforms

## Repository Structure

Scripts are organized at the root level for ease of access and installation. This flat structure allows for:

- Direct script execution
- Simple path inclusion in shell profiles
- Easy discovery of available tools

## Script Requirements

All scripts should:

- Be executable (`chmod +x`)
- Include a shebang line for proper interpreter selection
- Provide clear, concise output messages
- Handle errors gracefully
- Document dependencies
- Support both interactive and non-interactive usage when appropriate
- Include proper cleanup of temporary files/resources

## Code Interaction Guidelines

- Prefer reading entire files and std outputs. When you grep/find small snippets of code to save on tokens, you end up getting extremely confused and wasting way more tokens overall. just read the whole file. please.