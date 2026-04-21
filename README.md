# UnitScopePlugin

A RAD Studio IDE plugin that automatically adds unit scope namespace prefixes to `uses` clauses in your Delphi source files.

## What it does

When Delphi XE2+ introduced unit scope names, existing code using short unit names like `SysUtils` or `Forms` started requiring namespace prefixes (`System.SysUtils`, `Vcl.Forms`). This plugin automates that conversion.

**Before:**
```delphi
uses
  SysUtils, Classes, Forms, Controls, Graphics, Dialogs,
  Windows, Messages, Registry, StrUtils;
```

**After:**
```delphi
uses
  System.SysUtils, System.Classes, Vcl.Forms, Vcl.Controls, Vcl.Graphics, Vcl.Dialogs,
  Winapi.Windows, Winapi.Messages, System.Win.Registry, System.StrUtils;
```

## Features

- Processes both interface and implementation `uses` clauses
- Leaves already-scoped unit names unchanged
- Handles comments and `in 'filename'` clauses correctly
- Dynamically discovers unit scope mappings by scanning IDE library paths and BDS directories
- Respects project-local units — if your project has its own `Dialogs.pas`, it won't be rewritten to `Vcl.Dialogs`
- Works correctly in project groups by scoping to the project that owns the current file

## Installation

1. Open `UnitScopePlugin.dpk` in RAD Studio
2. Right-click the project in the Project Manager and select **Install**
3. The plugin registers itself under the Tools menu

## Usage

- **Menu**: Tools > Add Unit Scope Names
- **Shortcut**: Ctrl+Alt+Shift+S

Open any `.pas` file in the editor and invoke the command. The plugin will scan all `uses` clauses and add the appropriate namespace prefixes.

## Requirements

- RAD Studio (Delphi) XE2 or later
- Win32 platform

## Building from Command Line

```
msbuild UnitScopePlugin.dproj /p:Config=Debug /p:Platform=Win32
```

Requires the RAD Studio command-line environment (`rsvars.bat`).

## License

MIT
