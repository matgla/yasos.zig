#!/usr/bin/env bash
# Package this grammar-only extension as a .vsix (no vsce, no network) and
# install it with the `code` CLI. Usage: ./install.sh [--package-only]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${YASC_VSIX_OUT:-$here/yasc-syntax.vsix}"

python3 - "$here" "$out" <<'PY'
import json, os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
pkg = json.load(open(os.path.join(src, "package.json")))
files = ["package.json", "README.md"] + [
    os.path.join("syntaxes", f) for f in sorted(os.listdir(os.path.join(src, "syntaxes")))]
manifest = f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="{pkg['name']}" Version="{pkg['version']}" Publisher="{pkg['publisher']}"/>
    <DisplayName>{pkg['displayName']}</DisplayName>
    <Description xml:space="preserve">{pkg['description']}</Description>
    <Categories>Programming Languages</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{pkg['engines']['vscode']}"/>
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
"""
types = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
</Types>
"""
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", types)
    z.writestr("extension.vsixmanifest", manifest)
    for f in files:
        z.write(os.path.join(src, f), "extension/" + f)
print(out)
PY

if [[ "${1:-}" != "--package-only" ]]; then
  code --install-extension "$out" --force
  echo "Installed; run 'Developer: Reload Window' in open VSCode windows."
fi
