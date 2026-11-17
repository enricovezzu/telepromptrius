#!/usr/bin/env python3
"""Controlla le traduzioni: ogni lingua deve avere tutte le chiavi di main.swift,
con gli stessi segnaposto (%ld, %@) nello stesso ordine. Uso: python3 tools/check-lang.py [codice...]"""
import re, sys, subprocess, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "main.swift").read_text()
keys = list(dict.fromkeys(m.group(1) for m in re.finditer(r'\bLF?\("((?:[^"\\]|\\.)+)"', src)))
spec = lambda t: re.findall(r'%(?:ld|@|d)', t)
codes = sys.argv[1:] or sorted(p.name[:-6] for p in (root / "lang").glob("*.lproj") if p.name != "it.lproj")
bad = 0
for c in codes:
    f = root / "lang" / f"{c}.lproj" / "Localizable.strings"
    if not f.exists(): print(f"{c}: manca il file"); bad += 1; continue
    if subprocess.run(["plutil", "-lint", "-s", str(f)]).returncode: print(f"{c}: sintassi non valida"); bad += 1; continue
    d = dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', f.read_text(), re.M))
    miss = [k for k in keys if k not in d]
    wrong = [k for k in keys if k in d and spec(k) != spec(d[k])]
    if miss or wrong:
        bad += 1; print(f"{c}: {len(miss)} chiavi mancanti, {len(wrong)} segnaposto sbagliati")
        for k in (miss + wrong)[:8]: print("   ", k)
    else: print(f"{c}: ok ({len(d)} testi)")
sys.exit(1 if bad else 0)
