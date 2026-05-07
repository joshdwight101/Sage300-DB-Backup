# Sage300-DB-Backup

This repository now includes:

- `Sage300DBBackupUtility.ps1` (original PowerShell GUI utility)
- `src/Program.cs` + `Sage300DBBackupUtility.csproj` (C# Windows Forms equivalent)
- `Build-CSharpApp.ps1` (PowerShell build loader/compiler for C# app)

## Build the portable C# EXE

Run from PowerShell in this repository root:

```powershell
./Build-CSharpApp.ps1
```

What this build script does:

1. Verifies `dotnet` is installed.
2. If missing, attempts to install **.NET 8 SDK** using `winget`.
3. Restores dependencies.
4. Publishes a **single-file, self-contained** Windows executable (`win-x64`).

Output EXE location:

```text
bin\Release\net8.0-windows\win-x64\publish\Sage300DBBackupUtility.exe
```

## Run the C# app

Double-click the EXE or run from PowerShell:

```powershell
./bin/Release/net8.0-windows/win-x64/publish/Sage300DBBackupUtility.exe
```

The C# app provides the same core workflow as the PowerShell script:

1. Configure SQL connection/runtime/backup paths.
2. Detect candidate Sage databases (`%DAT` and `%SYS`).
3. Select databases.
4. Run sequential `dbdump32.exe` backups with logging/progress/ETA.
