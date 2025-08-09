# Copilot Instructions for Crucible

This file provides guidance to Copilot when working with code in this repository.

## General Guidelines

1. **Understand the Codebase**: Before making changes, take time to understand the existing code structure and logic.
2. **Follow Coding Standards**: Adhere to the coding conventions and best practices established in this repository.
3. **Write Clear Commit Messages**: When making changes, write concise and descriptive commit messages to explain the rationale behind your modifications.

## Specific Instructions

- When implementing new features, consider how they will impact existing functionality and ensure backward compatibility.
- Write unit tests for any new code you add, and ensure all tests pass before submitting your changes.
- If you encounter any issues or have questions, don't hesitate to reach out to the team for clarification.

By following these instructions, you can help ensure a smooth and efficient development process within the Crucible project.

## Description

Crucible turns a fresh Ubuntu or Fedora server into a fully configured production environment. It automates the setup process, ensuring that all necessary components are installed and configured correctly. Currently, it supports the installation and configuration of various software packages, including web servers, databases, and application frameworks.

Crucible is opinionated, meaning it enforces certain conventions and best practices to streamline the setup process and reduce configuration drift. This approach helps ensure that all environments are consistent and reproducible, making it easier to manage and maintain applications over time.

## Implementation Details

- **Gum**: Crucible uses Gum for interactive bash scripts, providing a user-friendly interface for configuration and setup tasks. See: https://github.com/charmbracelet/gum
- **Bash**: Crucible relies on Bash for scripting and automation tasks, leveraging its powerful features to streamline the setup process.
- The script must support both Ubuntu and Fedora distributions, ensuring compatibility across different environments.
- The scripts should handle errors gracefully and provide meaningful feedback to the user. Prefer using `gum style` for error messages. Log all errors to a file for later analysis. Use a custom error handling function

## Folder structure

The install folder contains the main installation scripts and configuration files for Crucible.

The config folder contains templates and configuration files for various software packages supported by Crucible.

The operation folder contains scripts for managing and orchestrating the core services.

## Progress Bar Utilities

A reusable progress bar helper lives in `install/lib/progress.sh` and should be sourced by scripts that perform multi-step package installations.

Key functions:
* `pb_init TOTAL "Message"` – initialize a bar.
* `pb_tick` / `pb_add N` – advance progress.
* `pb_finish` – complete and render final state.
* `pb_packages "Title" pkg1 pkg2 ...` – convenience wrapper to install a list of packages (supports both `apt-get` and `dnf`) while displaying progress.
* `pb_wrap LABEL command ...` – run a single command with a quick progress representation.

Usage pattern:
```bash
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"
if declare -f pb_packages >/dev/null 2>&1; then
	pb_packages "Installing prerequisites" curl wget git
else
	apt-get install -y curl wget git
fi
```

Guidelines:
* Always guard usage with `declare -f` so scripts work even if the library is missing.
* Keep package operations quiet (`>/dev/null 2>&1`) when wrapped by progress bar to avoid flicker.
* Prefer using the bar for batches larger than one package; use gum spinners for single quick tasks.