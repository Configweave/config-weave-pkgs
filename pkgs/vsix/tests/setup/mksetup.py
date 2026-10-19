# Usage: mksetup.py script.ps1 -> a Windows test `setup` line (cmd /C safe).
# The script is gzip+base64'd so it may hold any character; the bootstrap
# holds none of cmd's metacharacters or double quotes.
import sys, gzip, base64
src = open(sys.argv[1], 'rb').read()
b = base64.b64encode(gzip.compress(src, mtime=0)).decode()
s = ("powershell -NoProfile -ExecutionPolicy Bypass -Command "
     "$ErrorActionPreference='Stop'; "
     "$z=New-Object IO.Compression.GZipStream((New-Object IO.MemoryStream(,[Convert]::FromBase64String('" + b + "'))),[IO.Compression.CompressionMode]::Decompress); "
     "$s=(New-Object IO.StreamReader($z)).ReadToEnd(); "
     "Invoke-Expression $s")
for c in '"<>|&^%':
    assert c not in s, c
print(len(s), file=sys.stderr)
print(s)
