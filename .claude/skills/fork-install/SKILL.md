---
name: fork-install
description: Install the gmjain/AeroSpace fork on another Mac — either copy a release build from this machine or clone and build there — including config, permissions, quarantine and signing caveats. Use when Gaurav wants the fork on a second machine. The full step list lives in docs/fork/INSTALL.md.
---

# Install on another Mac

Canonical, verified steps: `docs/fork/INSTALL.md` (keep it current when the recipe changes).

**A. Copy a build from this Mac (recommended)**
- Build per FORK.md; for an Intel target build the CLI universal (`--arch arm64 --arch x86_64`);
  the app is already universal.
- Ship `.release/AeroSpace.app` + `.release/aerospace`; on the target remove any Homebrew cask
  `aerospace` first, then rm-before-cp into `/Applications` and `/opt/homebrew/bin`.
- `xattr -dr com.apple.quarantine` on both; grant Accessibility; self-signed identity
  ("VoiceInk Local Self-Signed") is untrusted there but runs once quarantine is cleared.
- Config: clone `~/git/config` (aerospace.toml uses fork-only keys + scripts); state dir
  `~/.local/state/aerospace/` is created on first run.

**B. Clone and build there** (only if developing there): Xcode, Homebrew bash 5, swiftly +
`.swift-version` toolchain, a local codesign identity, then the FORK.md recipe.
