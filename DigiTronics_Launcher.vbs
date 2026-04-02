Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Get path of this script
strPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
strHTML = strPath & "\DigiTronics.html"

If objFSO.FileExists(strHTML) Then
    objShell.Run "explorer.exe """ & strHTML & """", 1, False
Else
    MsgBox "خطأ: ملف DigiTronics.html غير موجود!" & vbCrLf & "يرجى وضع الملف في نفس المجلد", vbCritical, "DigiTronics"
End If
