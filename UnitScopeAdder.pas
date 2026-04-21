unit UnitScopeAdder;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Types,
  System.Variants,
  System.Generics.Collections,
  System.IOUtils,
  System.StrUtils,
  System.Masks,
  ToolsAPI,
  Vcl.Menus,
  Vcl.Dialogs;

type
  TUnitScopeAdder = class(TNotifierObject, IOTAWizard)
  private
    FUnitMap: TDictionary<string, string>; // LowerCase short name -> fully qualified name
    FBlockedNames: TDictionary<string, Boolean>; // Unscoped unit names that should not be remapped
    FMenuItem: TMenuItem;
    procedure BuildUnitMap;
    procedure CollectUnitsFromPath(const APath: string);
    procedure ProcessCurrentEditor;
    function GetEditorSource(const AEditor: IOTASourceEditor): string;
    procedure SetEditorSource(const AEditor: IOTASourceEditor; const ASource: string);
    function AddScopesToUsesClause(const ASource: string; out AChangeCount: Integer): string;
    function ParseUsesClause(const ASource: string; AStartPos: Integer;
      out AEndPos: Integer): TArray<string>;
    function FindUsesKeyword(const ASource: string; AFromPos: Integer;
      out AUsesPos: Integer): Boolean;
    function GetScopedName(const AUnitName: string): string;
    procedure MenuClick(Sender: TObject);
    procedure InstallMenu;
    procedure UninstallMenu;
  public
    constructor Create;
    destructor Destroy; override;
    // IOTAWizard
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
  end;

procedure Register;

implementation

procedure Register;
begin
  // Empty; registration is done via the package initialization
end;

{ TUnitScopeAdder }

constructor TUnitScopeAdder.Create;
begin
  inherited Create;
  FUnitMap := TDictionary<string, string>.Create;
  FBlockedNames := TDictionary<string, Boolean>.Create;
  InstallMenu;
end;

destructor TUnitScopeAdder.Destroy;
begin
  UninstallMenu;
  FBlockedNames.Free;
  FUnitMap.Free;
  inherited;
end;

function TUnitScopeAdder.GetIDString: string;
begin
  Result := 'CodeGearGuru.UnitScopeAdder';
end;

function TUnitScopeAdder.GetName: string;
begin
  Result := 'Unit Scope Adder';
end;

function TUnitScopeAdder.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TUnitScopeAdder.InstallMenu;
var
  NTAServices: INTAServices;
  MainMenu: TMainMenu;
  ToolsMenu: TMenuItem;
  I: Integer;
begin
  if not Supports(BorlandIDEServices, INTAServices, NTAServices) then
    Exit;

  MainMenu := NTAServices.MainMenu;
  if not Assigned(MainMenu) then
    Exit;

  // Find the Tools menu
  ToolsMenu := nil;
  for I := 0 to MainMenu.Items.Count - 1 do
  begin
    if SameText(StripHotkey(MainMenu.Items[I].Caption), 'Tools') then
    begin
      ToolsMenu := MainMenu.Items[I];
      Break;
    end;
  end;

  if not Assigned(ToolsMenu) then
    Exit;

  FMenuItem := TMenuItem.Create(nil);
  FMenuItem.Caption := 'Add Unit Scope Names';
  FMenuItem.ShortCut := ShortCut(Ord('S'), [ssCtrl, ssAlt, ssShift]);
  FMenuItem.OnClick := MenuClick;

  // Insert before the last separator/item in Tools, or just append
  ToolsMenu.Add(FMenuItem);
end;

procedure TUnitScopeAdder.UninstallMenu;
begin
  if Assigned(FMenuItem) then
  begin
    if Assigned(FMenuItem.Parent) then
      FMenuItem.Parent.Remove(FMenuItem);
    FreeAndNil(FMenuItem);
  end;
end;

procedure TUnitScopeAdder.MenuClick(Sender: TObject);
begin
  Execute;
end;

procedure TUnitScopeAdder.Execute;
begin
  // Rebuild the map each time (picks up project-specific paths)
  BuildUnitMap;
  ProcessCurrentEditor;
end;

procedure TUnitScopeAdder.BuildUnitMap;
var
  Services: IOTAServices;
  ModuleServices: IOTAModuleServices;
  EnvOptions: IOTAEnvironmentOptions;
  ProjectGroup: IOTAProjectGroup;
  Project: IOTAProject;
  ProjectOptions: IOTAProjectOptions;
  Paths: TStringDynArray;
  PathList: string;
  BDSDir, PlatformDir: string;
begin
  FUnitMap.Clear;
  FBlockedNames.Clear;
  // 1. Gather library paths from IDE environment options
  if Supports(BorlandIDEServices, IOTAServices, Services) then
  begin
    EnvOptions := Services.GetEnvironmentOptions;
    if Assigned(EnvOptions) then
    begin
      // Library path (semicolon-separated)
      PathList := EnvOptions.Values['LibraryPath'];
      Paths := SplitString(PathList, ';');
      for var P in Paths do
      begin
        var Expanded := Trim(P);
        if Expanded <> '' then
          CollectUnitsFromPath(Expanded);
      end;

      // Browsing path
      PathList := EnvOptions.Values['BrowsingPath'];
      Paths := SplitString(PathList, ';');
      for var P in Paths do
      begin
        var Expanded := Trim(P);
        if Expanded <> '' then
          CollectUnitsFromPath(Expanded);
      end;
    end;
  end;

  // 2. Find the project that owns the current module and scan its paths
  if Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
  begin
    Project := nil;
    var CurrentModule := ModuleServices.CurrentModule;

    // Find the project group and determine which project owns the current file
    for var I := 0 to ModuleServices.ModuleCount - 1 do
    begin
      if Supports(ModuleServices.Modules[I], IOTAProjectGroup, ProjectGroup) then
      begin
        if Assigned(CurrentModule) then
        begin
          for var J := 0 to ProjectGroup.ProjectCount - 1 do
          begin
            var Proj := ProjectGroup.Projects[J];
            if not Assigned(Proj) then
              Continue;
            for var K := 0 to Proj.GetModuleCount - 1 do
            begin
              if SameText(Proj.GetModule(K).FileName, CurrentModule.FileName) then
              begin
                Project := Proj;
                Break;
              end;
            end;
            if Assigned(Project) then
              Break;
          end;
        end;
        // Fall back to active project if current file not found in any project
        if not Assigned(Project) then
          Project := ProjectGroup.ActiveProject;
        Break;
      end;
    end;

    // Fall back to GetActiveProject if no project group exists
    if not Assigned(Project) then
      Project := GetActiveProject;

    if Assigned(Project) then
    begin
      // Scan the project's own directory
      var ProjectDir := TPath.GetDirectoryName(Project.FileName);
      if (ProjectDir <> '') and TDirectory.Exists(ProjectDir) then
        CollectUnitsFromPath(ProjectDir);

      // Scan the project's search paths
      ProjectOptions := Project.ProjectOptions;
      if Assigned(ProjectOptions) then
      begin
        PathList := VarToStr(ProjectOptions.Values['SrcDir']);
        Paths := SplitString(PathList, ';');
        for var P in Paths do
        begin
          var Expanded := Trim(P);
          if Expanded <> '' then
            CollectUnitsFromPath(Expanded);
        end;
      end;
    end;
  end;

  // 3. Scan BDS lib/source directories (common locations)
  BDSDir := GetEnvironmentVariable('BDSLIB');
  if BDSDir <> '' then
    CollectUnitsFromPath(BDSDir);

  BDSDir := GetEnvironmentVariable('BDSCOMMONDIR');
  if BDSDir <> '' then
  begin
    PlatformDir := TPath.Combine(BDSDir, 'Source');
    if TDirectory.Exists(PlatformDir) then
      CollectUnitsFromPath(PlatformDir);
  end;
end;

procedure TUnitScopeAdder.CollectUnitsFromPath(const APath: string);
var
  Files: TStringDynArray;
  FileName, BaseName, ShortName: string;
  DotPos: Integer;
begin
  if not TDirectory.Exists(APath) then
    Exit;

  try
    // Search for .pas and .dcu files
    Files := TDirectory.GetFiles(APath, '*.*', TSearchOption.soAllDirectories);
  except
    // Access denied or other I/O errors - skip this path
    Exit;
  end;

  for FileName in Files do
  begin
    var Ext := LowerCase(TPath.GetExtension(FileName));
    if (Ext <> '.pas') and (Ext <> '.dcu') then
      Continue;

    BaseName := TPath.GetFileNameWithoutExtension(FileName);

    // If the filename contains dots, it's already scoped
    // e.g. System.SysUtils.pas -> short name is SysUtils
    DotPos := Pos('.', BaseName);
    if DotPos > 0 then
    begin
      // Extract the short name (last segment after final dot)
      ShortName := BaseName;
      var LastDot := ShortName.LastIndexOf('.');
      if LastDot >= 0 then
        ShortName := ShortName.Substring(LastDot + 1);

      // Only add mapping if not blocked by an unscoped unit with the same name
      if not FBlockedNames.ContainsKey(LowerCase(ShortName)) then
        FUnitMap.AddOrSetValue(LowerCase(ShortName), BaseName);
    end
    else
    begin
      // Unscoped file exists - block this name from being remapped
      FBlockedNames.AddOrSetValue(LowerCase(BaseName), True);
      FUnitMap.Remove(LowerCase(BaseName));
    end;
  end;
end;

function TUnitScopeAdder.GetScopedName(const AUnitName: string): string;
begin
  // Already scoped (contains a dot)? Leave it alone.
  if Pos('.', AUnitName) > 0 then
    Exit(AUnitName);

  if FUnitMap.TryGetValue(LowerCase(AUnitName), Result) then
    Exit; // Found a mapping

  // No mapping found - return the original name unchanged
  Result := AUnitName;
end;

procedure TUnitScopeAdder.ProcessCurrentEditor;
var
  ModuleServices: IOTAModuleServices;
  Module: IOTAModule;
  SourceEditor: IOTASourceEditor;
  Source, NewSource: string;
  ChangeCount: Integer;
begin
  if not Supports(BorlandIDEServices, IOTAModuleServices, ModuleServices) then
  begin
    ShowMessage('Unable to access module services.');
    Exit;
  end;

  Module := ModuleServices.CurrentModule;
  if not Assigned(Module) then
  begin
    ShowMessage('No file is currently open.');
    Exit;
  end;

  SourceEditor := nil;
  for var I := 0 to Module.ModuleFileCount - 1 do
  begin
    if Supports(Module.ModuleFileEditors[I], IOTASourceEditor, SourceEditor) then
      Break;
  end;

  if not Assigned(SourceEditor) then
  begin
    ShowMessage('No source editor found for the current module.');
    Exit;
  end;

  Source := GetEditorSource(SourceEditor);
  if Source = '' then
  begin
    ShowMessage('Could not read source from the editor.');
    Exit;
  end;

  NewSource := AddScopesToUsesClause(Source, ChangeCount);

  if ChangeCount = 0 then
  begin
    ShowMessage('No units needed scope names added. Everything looks good!');
    Exit;
  end;

  SetEditorSource(SourceEditor, NewSource);
  ShowMessage(Format('Done! Added scope names to %d unit(s).', [ChangeCount]));
end;

function TUnitScopeAdder.GetEditorSource(const AEditor: IOTASourceEditor): string;
var
  Reader: IOTAEditReader;
  Buf: AnsiString;
  ReadCount: Integer;
  Position: Integer;
begin
  Result := '';
  Reader := AEditor.CreateReader;
  if not Assigned(Reader) then
    Exit;

  Position := 0;
  repeat
    SetLength(Buf, 4096);
    ReadCount := Reader.GetText(Position, PAnsiChar(Buf), Length(Buf));
    SetLength(Buf, ReadCount);
    Result := Result + string(Buf);
    Inc(Position, ReadCount);
  until ReadCount < 4096;
end;

procedure TUnitScopeAdder.SetEditorSource(const AEditor: IOTASourceEditor;
  const ASource: string);
var
  Writer: IOTAEditWriter;
begin
  Writer := AEditor.CreateUndoableWriter;
  if not Assigned(Writer) then
    Exit;

  Writer.DeleteTo(MaxInt);
  Writer.Insert(PAnsiChar(AnsiString(ASource)));
end;

function TUnitScopeAdder.FindUsesKeyword(const ASource: string;
  AFromPos: Integer; out AUsesPos: Integer): Boolean;
var
  Len: Integer;
  I: Integer;
  InLineComment, InBlockComment, InBraceComment, InString: Boolean;
  Ch, NextCh: Char;
begin
  Result := False;
  AUsesPos := 0;
  Len := Length(ASource);
  I := AFromPos;
  InLineComment := False;
  InBlockComment := False;
  InBraceComment := False;
  InString := False;

  while I <= Len do
  begin
    Ch := ASource[I];
    NextCh := #0;
    if I < Len then
      NextCh := ASource[I + 1];

    // Handle comment state
    if InLineComment then
    begin
      if (Ch = #13) or (Ch = #10) then
        InLineComment := False;
      Inc(I);
      Continue;
    end;

    if InBlockComment then
    begin
      if (Ch = '*') and (NextCh = ')') then
      begin
        InBlockComment := False;
        Inc(I, 2);
        Continue;
      end;
      Inc(I);
      Continue;
    end;

    if InBraceComment then
    begin
      if Ch = '}' then
        InBraceComment := False;
      Inc(I);
      Continue;
    end;

    if InString then
    begin
      if Ch = '''' then
        InString := False;
      Inc(I);
      Continue;
    end;

    // Enter comment/string states
    if (Ch = '/') and (NextCh = '/') then
    begin
      InLineComment := True;
      Inc(I, 2);
      Continue;
    end;

    if (Ch = '(') and (NextCh = '*') then
    begin
      InBlockComment := True;
      Inc(I, 2);
      Continue;
    end;

    if Ch = '{' then
    begin
      // Check for compiler directive - still a comment for our purposes
      InBraceComment := True;
      Inc(I);
      Continue;
    end;

    if Ch = '''' then
    begin
      InString := True;
      Inc(I);
      Continue;
    end;

    // Look for 'uses' keyword (case-insensitive)
    if CharInSet(Ch, ['u', 'U']) and (I + 3 <= Len) then
    begin
      var Word := Copy(ASource, I, 4);
      if SameText(Word, 'uses') then
      begin
        // Make sure it's a whole word (not part of an identifier)
        var BeforeOK := (I = 1) or not CharInSet(ASource[I - 1],
          ['A'..'Z', 'a'..'z', '0'..'9', '_']);
        var AfterOK := (I + 4 > Len) or not CharInSet(ASource[I + 4],
          ['A'..'Z', 'a'..'z', '0'..'9', '_']);

        if BeforeOK and AfterOK then
        begin
          AUsesPos := I;
          Result := True;
          Exit;
        end;
      end;
    end;

    Inc(I);
  end;
end;

function TUnitScopeAdder.AddScopesToUsesClause(const ASource: string;
  out AChangeCount: Integer): string;
var
  UsesPos, SearchFrom: Integer;
  Positions: TList<Integer>;
begin
  AChangeCount := 0;
  Result := ASource;

  // Find all 'uses' clauses in the source
  Positions := TList<Integer>.Create;
  try
    SearchFrom := 1;
    while FindUsesKeyword(Result, SearchFrom, UsesPos) do
    begin
      Positions.Add(UsesPos);
      SearchFrom := UsesPos + 4;
    end;

    // Process in reverse order so position offsets remain valid
    for var PIdx := Positions.Count - 1 downto 0 do
    begin
      var UPos := Positions[PIdx];
      var ClauseStart := UPos + 4; // Skip 'uses'

      // Find the semicolon that ends this uses clause
      var EndPos := ClauseStart;
      var InStr := False;
      var InLC := False;
      var InBC := False;
      var InBrC := False;
      var Len := Length(Result);

      while EndPos <= Len do
      begin
        var C := Result[EndPos];
        var NC: Char := #0;
        if EndPos < Len then
          NC := Result[EndPos + 1];

        if InLC then
        begin
          if (C = #13) or (C = #10) then InLC := False;
          Inc(EndPos);
          Continue;
        end;
        if InBC then
        begin
          if (C = '*') and (NC = ')') then begin InBC := False; Inc(EndPos); end;
          Inc(EndPos);
          Continue;
        end;
        if InBrC then
        begin
          if C = '}' then InBrC := False;
          Inc(EndPos);
          Continue;
        end;
        if InStr then
        begin
          if C = '''' then InStr := False;
          Inc(EndPos);
          Continue;
        end;
        if (C = '/') and (NC = '/') then begin InLC := True; Inc(EndPos, 2); Continue; end;
        if (C = '(') and (NC = '*') then begin InBC := True; Inc(EndPos, 2); Continue; end;
        if C = '{' then begin InBrC := True; Inc(EndPos); Continue; end;
        if C = '''' then begin InStr := True; Inc(EndPos); Continue; end;
        if C = ';' then
          Break;
        Inc(EndPos);
      end;

      // Now we have the uses clause from ClauseStart to EndPos-1
      var ClauseText := Copy(Result, ClauseStart, EndPos - ClauseStart);

      // Parse individual unit names and their positions within the clause
      var NewClause := '';
      var CI := 1;
      var ClauseLen := Length(ClauseText);

      while CI <= ClauseLen do
      begin
        var CC := ClauseText[CI];

        // Skip whitespace, commas, and comments - copy them through
        if CharInSet(CC, [' ', #9, #13, #10, ',']) then
        begin
          NewClause := NewClause + CC;
          Inc(CI);
          Continue;
        end;

        // Handle comments - copy through
        if (CC = '/') and (CI < ClauseLen) and (ClauseText[CI + 1] = '/') then
        begin
          while (CI <= ClauseLen) and not CharInSet(ClauseText[CI], [#13, #10]) do
          begin
            NewClause := NewClause + ClauseText[CI];
            Inc(CI);
          end;
          Continue;
        end;
        if (CC = '{') then
        begin
          while (CI <= ClauseLen) and (ClauseText[CI] <> '}') do
          begin
            NewClause := NewClause + ClauseText[CI];
            Inc(CI);
          end;
          if CI <= ClauseLen then
          begin
            NewClause := NewClause + ClauseText[CI]; // the }
            Inc(CI);
          end;
          Continue;
        end;
        if (CC = '(') and (CI < ClauseLen) and (ClauseText[CI + 1] = '*') then
        begin
          while CI <= ClauseLen do
          begin
            if (ClauseText[CI] = '*') and (CI < ClauseLen) and (ClauseText[CI + 1] = ')') then
            begin
              NewClause := NewClause + ClauseText[CI] + ClauseText[CI + 1];
              Inc(CI, 2);
              Break;
            end;
            NewClause := NewClause + ClauseText[CI];
            Inc(CI);
          end;
          Continue;
        end;

        // Read a unit name (can contain dots for already-scoped names)
        if CharInSet(CC, ['A'..'Z', 'a'..'z', '_']) then
        begin
          var UnitName := '';
          while (CI <= ClauseLen) and CharInSet(ClauseText[CI],
            ['A'..'Z', 'a'..'z', '0'..'9', '_', '.']) do
          begin
            UnitName := UnitName + ClauseText[CI];
            Inc(CI);
          end;

          // Skip 'in' filename clauses: UnitName in 'filename.pas'
          // First, output the (possibly scoped) unit name
          var ScopedName := GetScopedName(UnitName);
          if not SameText(ScopedName, UnitName) then
            Inc(AChangeCount);
          NewClause := NewClause + ScopedName;

          // Now check if followed by 'in'
          var SaveCI := CI;
          // Skip whitespace
          while (CI <= ClauseLen) and CharInSet(ClauseText[CI], [' ', #9, #13, #10]) do
            Inc(CI);
          if (CI + 1 <= ClauseLen) and SameText(Copy(ClauseText, CI, 2), 'in') and
             ((CI + 2 > ClauseLen) or not CharInSet(ClauseText[CI + 2],
               ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
          begin
            // Copy whitespace before 'in'
            NewClause := NewClause + Copy(ClauseText, SaveCI, CI - SaveCI);
            // Copy 'in'
            NewClause := NewClause + Copy(ClauseText, CI, 2);
            Inc(CI, 2);
            // Copy everything up to the closing quote
            while (CI <= ClauseLen) and (ClauseText[CI] <> '''') do
            begin
              NewClause := NewClause + ClauseText[CI];
              Inc(CI);
            end;
            if CI <= ClauseLen then
            begin
              NewClause := NewClause + ''''; // opening quote
              Inc(CI);
              while (CI <= ClauseLen) and (ClauseText[CI] <> '''') do
              begin
                NewClause := NewClause + ClauseText[CI];
                Inc(CI);
              end;
              if CI <= ClauseLen then
              begin
                NewClause := NewClause + ''''; // closing quote
                Inc(CI);
              end;
            end;
          end
          else
            CI := SaveCI; // No 'in' clause, restore position

          Continue;
        end;

        // Anything else, just copy through
        NewClause := NewClause + CC;
        Inc(CI);
      end;

      // Replace the clause text in the result
      Result := Copy(Result, 1, ClauseStart - 1) + NewClause +
                Copy(Result, EndPos, MaxInt);
    end;
  finally
    Positions.Free;
  end;
end;

function TUnitScopeAdder.ParseUsesClause(const ASource: string;
  AStartPos: Integer; out AEndPos: Integer): TArray<string>;
begin
  // Not used directly - parsing is done inline in AddScopesToUsesClause
  // Kept for potential future use
  Result := [];
  AEndPos := AStartPos;
end;

var
  WizardIndex: Integer = -1;

initialization
  WizardIndex := (BorlandIDEServices as IOTAWizardServices).AddWizard(
    TUnitScopeAdder.Create);

finalization
  if WizardIndex >= 0 then
    (BorlandIDEServices as IOTAWizardServices).RemoveWizard(WizardIndex);

end.
