# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Description 

Crucible is an opinionated server provisioning tool that transforms fresh Ubuntu or Fedora servers into fully configured production environments. It automates the installation and configuration of web servers, databases, application frameworks (PHP/Laravel, Node.js), and development tools through interactive bash scripts powered by Gum.

## Tech Stack

- **Gum**: Interactive TUI components for bash scripts (https://github.com/charmbracelet/gum)
- **Bash**: Shell scripting with error handling and cross-distribution support
- **Target Systems**: Ubuntu/Debian and Fedora/RHEL-based distributions

## Architecture Overview

### Entry Points
- `install.sh`: Main installer that sets up gum, clones repository, and launches startup menu
- `startup.sh`: Interactive main menu using gum for service selection

### Core Structure
```
install/
├── lib/progress.sh          # Reusable progress bar utilities
├── coreservice.sh          # Orchestrates core services (PHP, Caddy, MySQL, Docker)
├── framework.sh            # Framework setup (Laravel, Next.js)
├── services/               # Individual service installers
│   ├── php84.sh
│   ├── caddy.sh
│   ├── composer.sh
│   └── docker.sh
├── frameworks/             # Framework-specific configurations
│   └── caddy_laravel.sh
└── operation/              # Management and orchestration scripts
    └── docker.sh
```

## Common Commands

### Running the installer
```bash
# Download and run installer
curl -fsSL -o install.sh https://raw.githubusercontent.com/ekrist1/gumcrucible/main/install.sh
chmod +x install.sh
./install.sh

# With custom options
./install.sh -d /custom/path -b main
```

### Development workflow
```bash
# Make all shell scripts executable after changes
find . -type f -name "*.sh" -exec chmod +x {} +

# Test individual components
./install/coreservice.sh
./install/framework.sh
```

## Development Guidelines

### Error Handling
- Use `set -euo pipefail` in all scripts
- Provide meaningful error messages with `gum style --foreground 196`
- Log errors to files for analysis (see install.sh error handling pattern)
- Use trap for cleanup on script failure

### Progress Display
- Source `install/lib/progress.sh` for multi-step operations
- Use `pb_packages` for batch package installations
- Guard with `declare -f pb_packages` checks for fallback compatibility
- Use `gum spin` for single operations, progress bars for batches

### Cross-Distribution Support
- Detect OS via `/etc/os-release`
- Support both apt-get (Ubuntu/Debian) and dnf (Fedora/RHEL)
- Test package manager availability before use
- Handle ID_LIKE for derivative distributions

### Service Detection
- Implement detection functions (e.g., `has_php84()`, `has_caddy()`) 
- Display dynamic checkmarks in menus: `[x]` for installed, `[ ]` for missing
- Check both command availability and version requirements

### Menu Design
- Use `gum choose` for interactive selection
- Provide clear service status indicators
- Include "Back" and "Cancel" options
- Allow returning to main menu with confirmation prompts