## How ONLYOFFICE builds (stable orientation; exact names/versions live in the source)

Pipeline (documents-pipeline/Jenkinsfile): one stage per platform (Windows
x64/x86/arm64, macOS arm64 / x86_64 / x86_64 V8, Linux x86_64/aarch64, Android).
Each stage checks out the component repos, then builds, then packages.

Everything is driven from build_tools:
  - configure.py    -> writes a config file from CLI args (module, platform, branding...).
  - make.py         -> runs the build, in THIS order:
       1. update/clone the component repos
       2. make_common: build core's 3rdParty deps (V8, CEF, OpenSSL, ICU, boost,
          curl, harfbuzz, ...) - each is a module in
          build_tools/scripts/core_common/modules/. This also fetches tooling such
          as depot_tools for V8.
       3. build the native C++ solutions (core, and the desktop apps)
       4. build the JS (sdkjs / web-apps), then the server, then deploy
  - make_package.py -> packaging/signing (dmg/deb/exe...). On macOS it archives the
       app via Xcode + fastlane (gym); Xcode script phases like "Copy Library" copy
       libraries produced by the earlier build steps.

Repo dependency direction: build_tools orchestrates everything; core holds the C++
engine and the built 3rdParty; its libraries are consumed by desktop-sdk and
desktop-apps. So a failure in a later/consumer step (a mac "Copy Library" phase,
linking in desktop-apps, a missing .lib/.a) is OFTEN caused UPSTREAM - a 3rdParty
or tooling build in build_tools/make_common that never produced that library.
