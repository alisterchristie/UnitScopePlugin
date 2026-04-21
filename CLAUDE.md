# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

UnitScopePlugin is a Delphi RAD Studio IDE plugin (design-time package) that automatically adds unit scope namespace prefixes to `uses` clauses in the current editor. For example, it converts `SysUtils` to `System.SysUtils`.

## Build

This is a design-time package (.dpk/.bpl) that must be compiled within RAD Studio or via MSBuild with the BDS environment configured:

```
msbuild UnitScopePlugin.dproj /p:Config=Debug /p:Platform=Win32
```

Required packages: `rtl`, `designide`, `vcl`. The output .bpl is deployed to the shared BPL directory.

## Architecture

The entire plugin is a single unit (`UnitScopeAdder.pas`) implementing `IOTAWizard` from the Open Tools API:

- **Registration**: The wizard is registered via `IOTAWizardServices.AddWizard` in the `initialization` section (not via `Register` procedure).
- **Menu integration**: Installs "Add Unit Scope Names" under the Tools menu with shortcut Ctrl+Alt+Shift+S.
- **Unit mapping**: Dynamically discovered by `BuildUnitMap` which scans IDE library/browsing paths, BDS directories, and the owning project's directory and search paths for scoped .pas/.dcu files.
- **Blocked names**: Unscoped .pas/.dcu files found during scanning block that name from being remapped, preventing false positives when a project has its own unit with the same name as a scoped RTL/VCL unit (e.g. a project-local `Dialogs.pas` won't be rewritten to `Vcl.Dialogs`).
- **Project ownership**: In a project group, the plugin determines which project owns the current file and only scans that project's paths for blockers, so unscoped units in sibling projects don't interfere.
- **Source parsing**: Custom parser in `AddScopesToUsesClause` handles Delphi comments (`//`, `{}`, `(**)`) and string literals while locating and transforming `uses` clauses.

## Key Design Decisions

- The plugin operates on the source text directly via `IOTAEditReader`/`IOTAEditWriter`, not the AST.
- Already-scoped names (containing a dot) are left unchanged.
- Both interface and implementation `uses` clauses are processed.
- `in 'filename'` clauses are preserved correctly.
