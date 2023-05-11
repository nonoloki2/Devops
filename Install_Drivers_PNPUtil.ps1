Get-ChildItem "C:\drivers\" -Recurse -Filter "*.inf" | 
ForEach-Object { PNPUtil.exe /add-driver $_.FullName /install }