Option Explicit
Dim shell, fso, folder, script, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(folder, "CodexCacheMonitor.en.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
' The launcher exits immediately. The only remaining process is the PowerShell process that owns the GUI.
' Closing the GUI ends that process; no service, job, or scheduled task is installed.
shell.Run cmd, 0, False
