#!/bin/bash
# Source this before any `swift build` / `swift test`:   source Scripts/toolchain-fix.sh
#
# Why this exists: this Mac's Command Line Tools has leftover files from an older install, and they break
# every Swift build ("redefinition of module 'SwiftBridging'", and a link error in the package tool).
#   1. usr/include/swift/module.modulemap (Aug 2023) clashes with bridging.modulemap (Dec 2024).
#   2. ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface (Feb 2024) is older than the library next to it.
# The proper fix is to reinstall the Command Line Tools (needs admin). Until then, this script hides both files
# from the compiler using private copies under .toolchain-fix/, and does not change anything in /Library.
# If the tools are ever repaired, this script notices and does nothing.

# Works whether sourced from bash (BASH_SOURCE) or zsh ($0 is the sourced file).
_SRC="${BASH_SOURCE[0]:-$0}"
_ROOT="$(cd "$(dirname "$_SRC")/.." && pwd)"
_CLT=/Library/Developer/CommandLineTools
_FIX="$_ROOT/.toolchain-fix"

if [ -f "$_CLT/usr/include/swift/module.modulemap" ] && [ -f "$_CLT/usr/include/swift/bridging.modulemap" ]; then
  mkdir -p "$_FIX"

  printf '// intentionally empty: hides the stale duplicate SwiftBridging module map\n' > "$_FIX/empty.modulemap"
  cat > "$_FIX/overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "type": "file",
      "name": "$_CLT/usr/include/swift/module.modulemap",
      "external-contents": "$_FIX/empty.modulemap"
    }
  ]
}
EOF

  # The overlay goes LAST: when several are given, the compiler only honours the final one.
  cat > "$_FIX/swiftc" <<EOF
#!/bin/bash
exec $_CLT/usr/bin/swiftc "\$@" -vfsoverlay "$_FIX/overlay.yaml"
EOF
  chmod +x "$_FIX/swiftc"

  if [ ! -d "$_FIX/pm/ManifestAPI" ]; then
    mkdir -p "$_FIX/pm"
    cp -R "$_CLT/usr/lib/swift/pm/ManifestAPI" "$_FIX/pm/ManifestAPI"
    cp -R "$_CLT/usr/lib/swift/pm/PluginAPI" "$_FIX/pm/PluginAPI" 2>/dev/null
    rm -f "$_FIX"/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
  fi

  export SWIFT_EXEC="$_FIX/swiftc"
  export SWIFT_EXEC_MANIFEST="$_FIX/swiftc"
  export SWIFTPM_CUSTOM_LIBS_DIR="$_FIX/pm"
fi
