#!/bin/bash
# TokenBar — build + test para toolchain Command Line Tools (sem Xcode).
#
# Por que os flags extras? O CLT (Xcode 26 era) não inclui os módulos XCTest
# nem Testing nos search paths padrão do swiftc. O framework Testing
# (swift-testing) vive em <CLT>/Library/Developer/Frameworks e a lib de
# interop em <CLT>/Library/Developer/usr/lib — os flags abaixo apontam
# compile (-F), link (-F) e runtime (-rpath) para esses caminhos.
#
# ATENÇÃO: NÃO rode `swift test` puro neste projeto — neste toolchain ele
# pode sair 0 sem executar nenhum teste (falso verde). Use este script.
set -euo pipefail
cd "$(dirname "$0")"

CLT_DEV=/Library/Developer/CommandLineTools/Library/Developer

swift build
swift test \
  -Xswiftc -F -Xswiftc "$CLT_DEV/Frameworks" \
  -Xlinker -F -Xlinker "$CLT_DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_DEV/usr/lib"
