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
- **Unit mapping**: Uses a hardcoded dictionary (`GetBuiltInMappings`) mapping ~130 short unit names to their fully-qualified equivalents (System.*, Winapi.*, Vcl.*, Data.*, Xml.*, etc.).
- **Source parsing**: Custom parser in `AddScopesToUsesClause` handles Delphi comments (`//`, `{}`, `(**)`) and string literals while locating and transforming `uses` clauses.
- **Dynamic scanning** (`BuildUnitMap`): Code exists to scan IDE library/browsing paths and project search paths for .pas/.dcu files, but is currently disabled (`Exit` at the top of the method) — only built-in mappings are active.

## Key Design Decisions

- The plugin operates on the source text directly via `IOTAEditReader`/`IOTAEditWriter`, not the AST.
- Already-scoped names (containing a dot) are left unchanged.
- Both interface and implementation `uses` clauses are processed.
- `in 'filename'` clauses are preserved correctly.
