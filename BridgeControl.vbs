' Runs BridgeControl.ps1 (next to this file) without a console window.
' Pass /autostart to start the "startAtLogin" apps instead of opening the panel.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
extra = ""
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "/autostart" Then extra = " -Autostart"
End If
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & folder & "\BridgeControl.ps1""" & extra, 0, False
