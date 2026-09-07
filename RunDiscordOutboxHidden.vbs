Set shell = CreateObject("WScript.Shell")
shell.Run """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""C:\dev\gladio-mori-mods\ChampionsLeagueTracker\SendDiscordOutbox.ps1""", 0, False
