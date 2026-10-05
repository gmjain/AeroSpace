---
name: fork-install
description: Install the gmjain/AeroSpace fork on another Mac — either copy a release build from this machine or clone and build there — including config, permissions, quarantine and signing caveats. Use when Gaurav wants the fork on a second machine. The full step list lives in docs/fork/INSTALL.md.
---

# Install on another Mac

Canonical, verified steps: `docs/fork/INSTALL.md`. Read it first; keep it current when the recipe
changes.

- **A (recommended)**: build here per FORK.md; Intel target needs a universal CLI
  (`--arch arm64 --arch x86_64`, copy from `--show-bin-path`); `ditto -c -k --keepParent` the app;
  on target remove any brew cask, rm-before-cp into `/Applications` + `/opt/homebrew/bin`
  (`/usr/local/bin` on Intel), `xattr -dr com.apple.quarantine`, grant Accessibility.
- **B**: only to develop there: Xcode, Homebrew bash 5 first, swiftly, xcodegen, local codesign
  identity, FORK.md recipe.
- Config: clone `~/git/config`, symlink `~/.config/aerospace`; fix hardcoded `/Users/gmjain`
  paths; fork keys break stock AeroSpace; set `fork-debug-log = false` on fresh machines.
- Verify: `aerospace --version`, binary hash, `list-workspaces --all`, `aerospace restart`.
