# PRs welcome 🤗

## This is:
- vOid Community repOsitory (oco)  
aka  
- Void User Repository
- VUR
- testing repo
- waiting list
- void unstable

Providing:
- templates
- binaries
- by community
- for community

## DISCLAIMER
This project is **not affiliated with or endorsed by the Void Linux project** or its maintainers.
It is an **unofficial community repository** designed to simplify managing and building user-contributed packages using the void-packages build system.
Use at your own discretion.

## Overview
A collection of template files for building packages on Void Linux.
If you dont wish to build the packages locally,
https://repo.osowoso.org repository provides prebuilt binaries.
Pick your architecture there and you will see

## Structure
- Main repository with templates on Codeberg https://codeberg.org/oSoWoSo/oco
- mirror Github repository + CI https://github.com/oSoWoSo/oco (Here we build binary packages)
- To make CI quicker we use daily updated Bootstrap Docker images from [oco-builder](https://github.com/oSoWoSo/oco-builder)
- nocross templates build support (GitHub aarch runner)
- Binary repository https://repo.osowoso.org/
- Just built (RSS feed) https://repo.osowoso.org/feed.xml

## What we don't build? (From source)
Browsers: It's waste of energy and when you finish building is maybe already new version out
We provide repackaged binaries, they all have `-bin` after <pkgname>
(You can use AppImages and manage them with [AM](https://github.com/ivan-hc/AM), or flatpaks. They are usualy always latest)

## How to use
in https://repo.osowoso.org/`(architecture)`
are easy to understand READMEs
Just pick your architecture

### Install repository key
xbps looks up repository keys by their RSA fingerprint, so the key file must
be named `df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb.plist`.
```sh
sudo mkdir -p /var/db/xbps/keys
curl -fsSL "https://codeberg.org/oSoWoSo/oco/raw/branch/OCO/oco-repo-key.plist" \
  -o /tmp/oco-repo-key.plist 2>/dev/null || \
curl -fsSL "https://raw.githubusercontent.com/oSoWoSo/oco/OCO/oco-repo-key.plist" \
  -o /tmp/oco-repo-key.plist
sudo cp /tmp/oco-repo-key.plist /var/db/xbps/keys/df:ec:10:ef:5c:03:e9:e0:9e:86:77:08:c2:b5:a8:cb.plist
```

## How to contribute

### Clone using ocoman script
Running `./ocoman -i` will clone void-packages and oco into ~/void
PS: Destination could be changed look at `./ocoman -h`

### Clone manualy A or B
A) Clone Codeberg repo  
`git clone https://codeberg.org/oSoWoSo/oco`  
B) Clone GitHub repo  
`git clone https://codeberg.org/oSoWoSo/oco`  
Copy srcpkgs directory to cloned [void-packages](https://github.com/void-linux/void-packages)

Then:

Use `xnew <pkgname>` to create new template
Fill everyhing as needed and remove rest
Use `xlint <pkgname>` to lint templates
Build templates with tests `./xbps-src -Q pkg <pkgname>`
(Tests must be allowed in $XBPS_DISTDIR/etc/conf)
We build for x86_64 and aarch64 + musl variants
(I am usualy trying x86_64 and aarch64-musl crossbuild)
Add your changes
When you change any shlib from upstream void-packages, changes must be reflected in `shlibs_remove` and `shlibe_append`
When you add new shlib add it only to `shlibe_append`
After adding template, run `./ocoman -u` to regenerate templates list and table
One commit per template, mesage: `<pkgname> <version>`

Create PR to Codeberg or GitHub

## Void official documentation
- [Manual](https://github.com/void-linux/void-packages/blob/master/Manual.md)
- [Contributing](https://github.com/void-linux/void-packages/blob/master/CONTRIBUTING.md)
- [Readme](https://github.com/void-linux/void-packages/blob/master/README.md)

## Available templates (packages when built successfully)
| package | version | home | maintainer | notes | description |
|:--------|:--------|:-----|:-----------|:------|:------|
| adw-gtk3 | 6.5 | [home](https://github.com/lassekongo83/adw-gtk3) | Coolllyn |  | Libadwaita-styled theme ported to GTK 3 |
| android-sdk | 36 | [home](https://developer.android.com/studio) | zenobit | x86_64 | Android SDK platform 36 and build-tools 29.0.3 |
| aquamarine | 0.15.1 | [home](https://github.com/hyprwm/aquamarine) | zenobit |  | Aquamarine is a very light linux rendering backend library |
| aquamarine-devel | 0.15.1 | [home](https://github.com/hyprwm/aquamarine) | zenobit |  | Aquamarine is a very light linux rendering backend library |
| better-sqlite3 | 13.0.3 | [home](https://github.com/WiseLibs/better-sqlite3) | zenobit |  | Fastest and simplest SQLite library for Node.js |
| better-sqlite3-devel | 13.0.3 | [home](https://github.com/WiseLibs/better-sqlite3) | zenobit |  | Fastest and simplest SQLite library for Node.js |
| blocaled | 0.7 | [home](https://github.com/lfs-book/blocaled) | zenobit |  | Standalone implementation of the localed D-Bus service |
| BoxBuddy | 2.6.2 | [home](https://github.com/Dvlv/BoxBuddyRS) | zenobit | x86_64 | Graphical Interface for Distrobox |
| brave-browser-bin | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brave-browser-bin-qt5 | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brave-browser-bin-qt6 | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brave-origin-bin | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brave-origin-bin-qt5 | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brave-origin-bin-qt6 | 1.98.63 | [home](https://www.brave.com/) | zenobit | x86_64 aarch64 | One of the most private browsers built on top off Chromium project |
| brow6el | 0.3.5 | [home](https://brow6el.dev/) | zenobit | x86_64 | Minimalistic graphical terminal web browser using sixels |
| btrfs-progs | 7.1 | [home](https://btrfs.wiki.kernel.org/index.php/Main_Page) | Enno Boland |  | Btrfs filesystem utilities |
| bulletty | 0.3.0 | [home](https://github.com/crocidb/bulletty) | zenobit |  | Feed reader for the terminal that stores the articles as Markdown |
| bun | 1.4.4 | [home](https://bun.sh) | zenobit | aarch64* x86_64* | JavaScript runtime, bundler, transpiler, and package manager |
| bun-bootstrap | 1.4.4 | [home](https://bun.sh) | zenobit | x86_64* aarch64* | Bootstrap package for bun (prebuilt binary) |
| caerus | 0.8.2 | [home](https://github.com/mendescotta/Caerus) | zenobit |  | Package manager for Void Linux, inspired by Synaptic |
| candy-icons-git | 0.11.1 | [home](https://www.opendesktop.org/p/1305251/) | Trve_AY |  | Sweet gradient icons, sweet rainbow folders included |
| cc-switch | 4.0.22 | [home](https://github.com/farion1231/cc-switch) | zenobit | x86_64* aarch64* | Assistant for Claude Code, Codex, OpenCode, OpenClaw & Gemini CLI |
| cliamp | 2.3.0 | [home](https://github.com/bjarneo/cliamp) | zenobit |  | Terminal music player inspired by winamp |
| clitest | 0.5.0 | [home](https://github.com/aureliojargas/clitest) | zenobit |  | Command Line Tester |
| Community-Repositories-Collection | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| corekeyboard | 5.0.1 | [home](https://gitlab.com/cubocore/coreapps/corekeyboard) | zenobit |  | X11 based virtual keyboard for C Suite |
| cosign | 3.1.4 | [home](https://github.com/sigstore/cosign) | zenobit |  | Code signing and transparency for containers and binaries |
| cosmic-applets | 1.11.0 | [home](https://github.com/pop-os/cosmic-applets) | zenobit |  | Applets for COSMIC Panel |
| cosmic-applibrary | 1.11.0 | [home](https://github.com/pop-os/cosmic-app-library) | zenobit |  | Application launcher for the COSMIC desktop |
| cosmic-bg | 1.11.0 | [home](https://github.com/pop-os/cosmic-bg) | zenobit |  | COSMIC session service which applies backgrounds to displays |
| cosmic-comp | 1.11.0 | [home](https://github.com/pop-os/cosmic-comp) | zenobit |  | Compositor for the COSMIC desktop environment |
| cosmic-desktop-full | 1.11.0 | [home](https://github.com/pop-os/cosmic-epoch) | Bella109 |  | Full Cosmic Desktop |
| cosmic-desktop-minimal | 1.10.0 | [home](https://github.com/pop-os/cosmic-epoch) | Bella109 |  | Meta Package for COSMIC Desktop |
| cosmic-edit | 1.11.0 | [home](https://github.com/pop-os/cosmic-edit) | zenobit |  | Text editor for the COSMIC desktop |
| cosmic-files | 1.11.0 | [home](https://github.com/pop-os/cosmic-files) | zenobit |  | File manager for the COSMIC desktop environment |
| cosmic-greeter | 1.11.0 | [home](https://github.com/pop-os/cosmic-greeter) | zenobit |  | COSMIC greeter for greetd |
| cosmic-icons | 1.11.0 | [home](https://github.com/pop-os/cosmic-icons) | zenobit |  | System76 Cosmic icon theme for Linux |
| cosmic-idle | 1.11.0 | [home](https://github.com/pop-os/cosmic-idle) | zenobit |  | Idle daemon for the COSMIC desktop |
| cosmic-initial-setup | 1.11.0 | [home](https://github.com/pop-os/cosmic-initial-setup) | zenobit |  | Initial setup for the COSMIC desktop |
| cosmic-launcher | 1.11.0 | [home](https://github.com/pop-os/cosmic-launcher) | zenobit |  | Layer Shell frontend for pop-launcher |
| cosmic-monitor | 1.11.0 | [home](https://github.com/pop-os/cosmic-monitor) | zenobit |  | System monitor for the COSMIC desktop |
| cosmic-notifications | 1.11.0 | [home](https://github.com/pop-os/cosmic-notifications) | zenobit |  | Layer Shell notifications daemon for the COSMIC desktop |
| cosmic-osd | 1.11.0 | [home](https://github.com/pop-os/cosmic-osd) | zenobit |  | On-Screen Display daemon for the COSMIC desktop |
| cosmic-osk | 1.11.0 | [home](https://github.com/pop-os/cosmic-osk) | zenobit |  | COSMIC On-Screen Keyboard |
| cosmic-panel | 1.11.0 | [home](https://github.com/pop-os/cosmic-panel) | zenobit |  | COSMIC applet for creating panels and docks |
| cosmic-player | 1.11.0 | [home](https://github.com/pop-os/cosmic-player) | zenobit |  | Media player for the COSMIC desktop |
| cosmic-randr | 1.11.0 | [home](https://github.com/pop-os/cosmic-randr) | zenobit |  | Library and utility for displaying and configuring Wayland outputs |
| cosmic-screenshot | 1.11.0 | [home](https://github.com/pop-os/cosmic-screenshot) | zenobit |  | Utility for capturing screenshots via XDG Desktop Portal |
| cosmic-session | 1.11.0 | [home](https://github.com/pop-os/cosmic-session) | zenobit |  | Session manager for the COSMIC desktop environment |
| cosmic-settings | 1.11.0 | [home](https://github.com/pop-os/cosmic-settings) | zenobit |  | Settings application for the COSMIC desktop environment |
| cosmic-settings-daemon | 1.11.0 | [home](https://github.com/pop-os/cosmic-settings-daemon) | zenobit |  | Settings daemon for the COSMIC desktop environment |
| cosmic-sound-theme | 1.11.0 | [home](https://github.com/pop-os/cosmic-sound-theme) | zenobit |  | Sound theme for the COSMIC desktop environment |
| cosmic-store | 1.11.0 | [home](https://github.com/pop-os/cosmic-store) | zenobit |  | Cosmic App Store |
| cosmic-term | 1.11.0 | [home](https://github.com/pop-os/cosmic-term) | zenobit |  | COSMIC terminal emulator |
| cosmic-tweaks | 0.2.5 | [home](https://github.com/cosmic-utils/cosmic-tweaks) | Bella109 | x86_64 | Tweaks for COSMIC |
| cosmic-viewer | 1.11.0 | [home](https://github.com/pop-os/cosmic-viewer) | zenobit |  | COSMIC Image Viewer |
| cosmic-wallpapers | 1.11.0 | [home](https://github.com/pop-os/cosmic-wallpapers) | zenobit |  | Wallpapers for the COSMIC Desktop Environment |
| cosmic-workspaces-epoch | 1.11.0 | [home](https://github.com/pop-os/cosmic-workspaces-epoch) | zenobit |  | COSMIC workspaces |
| CRC-black-hole | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-brgvos | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-brgvos-testing | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-cereus-core | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-cereus-extra | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-cosmic | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-d77void | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-dms | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-dux | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-hyprland | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-jake | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-lazy | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-librewolf | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-noid | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-odyssey | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-sofijacom | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-sonicde | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-split | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-voiders | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-vostock | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| CRC-xlibre | 1 | [home](https://repo.osowoso.org) | zenobit |  | CRC: Collection of community repositories |
| crush | 0.99.0 | [home](https://github.com/charmbracelet/crush) | zenobit |  | Glamourous AI coding agent for your favourite terminal |
| cwal | 0.10.1 | [home](https://github.com/nitinbhat972/cwal) | zenobit |  | Blazing-fast pywal-like color palette generator written in C |
| dankcalendar | 2.0.0 | [home](https://github.com/duxlabs-dev/dux-calendar) | zenobit |  | Calendar app that brings your calendars together in one place |
| DankMaterialShell | 2.0.0 | [home](https://duxlabs.dev) | zenobit |  | Dux Shell — Material 3 desktop shell for Wayland |
| dashy | 4.9.11 | [home](https://dashy.to) | zenobit |  | Feature-rich, self-hostable dashboard for your services |
| default-cursors | 1 | [home](https://www.voidlinux.org) | zenobit |  | Default cursor set |
| desktop-tui | 0.3.2 | [home](https://github.com/Julien-cpsn/desktop-tui) | zenobit |  | Desktop environment without graphics |
| devedeng | 4.22.1 | [home](https://www.rastersoft.com/programas/devede.html) | Bella109 |  | Create video DVDs and CDs |
| diskwatch | 0.7.0 | [home](https://www.netwatchlabs.com) | zenobit |  | Single-host, read-only disk diagnostics TUI |
| distrobox | 1.8.2.5 | [home](https://distrobox.it/) | zenobit |  | Podman/Docker wrapper to use any linux distribution in your terminal |
| dragonfly-reverb | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-clap | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-doc | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-lv2 | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-standalone | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-vst | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| dragonfly-reverb-vst3 | 3.2.10 | [home](https://michaelwillis.github.io/dragonfly-reverb) | Trve_AY |  | Collection of reverbs |
| drako | 0.4.2 | [home](https://github.com/lucky7xz/drako) | zenobit |  | Grid-based, customizable TUI-Deck launcher |
| dux-calendar | 2.0.0 | [home](https://github.com/duxlabs-dev/dux-calendar) | zenobit |  | Calendar app that brings your calendars together in one place |
| dux-files | 2.0.0 | [home](https://github.com/duxlabs-dev/dux-files) | zenobit |  | File manager for the Dux Labs desktop |
| dux-gop | 2.0.0 | [home](https://github.com/duxlabs-dev/dux-gop) | zenobit |  | API and CLI for system and process monitoring from Dux Labs |
| dux-search | 2.0.0 | [home](https://duxlabs.dev/docs/dsearch/) | AvengeMedia |  | Blazingly fast filesystem search tool (Dux Shell) |
| dux-shell | 2.0.0 | [home](https://duxlabs.dev) | zenobit |  | Dux Shell — Material 3 desktop shell for Wayland |
| easybashgui | 15.0.2 | [home](https://github.com/BashGui/easybashgui) | zenobit |  | Bash functions library that aims to give simple GUI functions |
| faugus-launcher | 2.5.5 | [home](https://github.com/Faugus/faugus-launcher) | zenobit |  | Simple and lightweight app for running Windows games using UMU-Launcher |
| Favnyr | 0.3.7 | [home](https://github.com/GlitchAwakened/Favnyr) | zenobit |  | Modern and lightweight file manager for Windows and Linux |
| fcitx5-lotus | 6.0.4 | [home](https://github.com/LotusInputMethod/fcitx5-lotus) | Coolllyn |  | Fcitx5 - Vietnamese IME |
| fcitx5-lotus-settings | 6.0.4 | [home](https://github.com/LotusInputMethod/fcitx5-lotus) | Coolllyn |  | Fcitx5 - Vietnamese IME |
| floorp-bin | 12.21.0 | [home](https://github.com/Floorp-Projects/Floorp) | zenobit | x86_64 aarch64 | Browser built for keeping the Open, Private and Sustainable Web alive |
| flyline | 1.10.0 | [home](https://github.com/HalFrgrd/flyline) | zenobit |  | Bash plugin to replace readline for a modern line editing experience |
| forgejo-runner | 13.2.1 | [home](https://code.forgejo.org/forgejo/runner) | zenobit |  | Continuous integration for Forgejo |
| FreeTube | 0.25.1 | [home](https://github.com/FreeTubeApp/FreeTube) | Bella109 | x86_64 | Client for watching YouTube Videos |
| fresh | 0.5.3 | [home](https://github.com/sinelaw/fresh) | zenobit |  | Terminal based IDE & text editor: easy, powerful and fast |
| ftxui | 7.0.3 | [home](https://github.com/ArthurSonzogni/FTXUI) | zenobit |  | C++ Functional Terminal User Interface |
| ftxui-devel | 7.0.3 | [home](https://github.com/ArthurSonzogni/FTXUI) | zenobit |  | C++ Functional Terminal User Interface |
| gama | 1.2.1 | [home](https://github.com/termkit/gama) | zenobit |  | Manage your GitHub Actions from Terminal with great UI |
| gh-dash | 4.26.2 | [home](https://github.com/dlvhdr/gh-dash) | zenobit |  | Rich terminal UI for GitHub that doesn't break your flow |
| gh-lazy | 0.6.6 | [home](https://github.com/gizmo385/gh-lazy) | zenobit |  | Terminal UI for interacting with GitHub |
| ghgrab | 2.3.0 | [home](https://github.com/abhixdd/ghgrab) | zenobit |  | Terminal tool to browse and download files in git forges |
| glaze | 8.2.0 | [home](https://github.com/stephenberry/glaze) | zenobit |  | Extremely fast, in memory, JSON and interface library for modern C++ |
| glaze7 | 7.2.0 | [home](https://github.com/stephenberry/glaze) | zenobit |  | Extremely fast, in memory, JSON and interface library for modern C++ |
| gofer | 1.0.0 | [home](https://codeberg.org/JakeAtLinux/Gofer) | zenobit |  | Fast, minimal application launcher written in pure Go. Supports both Way |
| gradle9 | 9.8.0 | [home](https://gradle.org) | zenobit |  | Build system for Java/C/C++ software |
| graphite-gtk-theme | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-all | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-black | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-black-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-compact-all | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-dark | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-dark-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-light | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-light-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord-dark | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord-dark-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord-light | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| graphite-gtk-theme-nord-light-compact | 2026.08.23 | [home](https://github.com/vinceliuice/Graphite-gtk-theme) | zenobit |  | Material design inspired GTK theme with light and dark variants |
| gum-panel | 2.0.0.001 | [home](https://codeberg.org/oSoWoSo/gum) | zenobit |  | Modified version of gum with panel support |
| helium-browser-bin | 0.20.2.1 | [home](https://helium.computer) | zenobit | x86_64 aarch64 | Private, fast, and honest web browser based on Chromium (binary build) |
| hister | 0.21.0 | [home](https://github.com/asciimoo/hister) | zenobit |  | Your own search engine |
| hyprcursor | 0.1.13 | [home](https://github.com/hyprwm/hyprcursor) | zenobit |  | Hyprland cursor format, library and utilities |
| hyprdynamicmonitors | 1.4.0 | [home](https://github.com/fiffeek/hyprdynamicmonitors) | zenobit |  | Hyprland configuration based on connected displays, power and lid state |
| hyprgraphics | 0.5.1 | [home](https://github.com/hyprwm/hyprgraphics) | zenobit |  | Hyprland graphics resources and utilities |
| hypridle | 0.1.8 | [home](https://github.com/hyprwm/hypridle) | zenobit |  | Hyprland's idle daemon |
| hyprland | 0.56.2 | [home](https://hyprland.org/) | zenobit |  | Dynamic tiling Wayland compositor that doesn't sacrifice on its looks |
| hyprland-devel | 0.56.2 | [home](https://hyprland.org/) | zenobit |  | Dynamic tiling Wayland compositor that doesn't sacrifice on its looks |
| hyprland-guiutils | 0.2.2 | [home](https://github.com/hyprwm/hyprland-guiutils) | zenobit |  | Qt/QML utility apps for Hyprland |
| hyprland-protocols | 0.8.0 | [home](https://github.com/hyprwm/hyprland-protocols) | zenobit |  | Wayland protocol extensions for Hyprland |
| hyprland-qt-support | 0.1.0 | [home](https://github.com/hyprwm/hyprland-qt-support) | zenobit |  | QML style provider for Hypr* QT apps |
| hyprlang | 0.6.8 | [home](https://github.com/hyprwm/hyprlang) | zenobit |  | Official implementation library for the hypr config language |
| hyprlock | 0.9.6 | [home](https://github.com/hyprwm/hyprlock) | zenobit |  | Hyprland's GPU-accelerated screen locking utility |
| hyprmoncfg | 1.26.0 | [home](https://github.com/crmne/hyprmoncfg/) | zenobit |  | Terminal-first monitor configurator and daemon for Hyprland |
| hyprpaper | 0.8.4 | [home](https://github.com/hyprwm/hyprpaper) | zenobit |  | Fast wallpaper utility for wlroots compositors with IPC controls |
| hyprpicker | 0.4.7 | [home](https://github.com/hyprwm/hyprpicker) | zenobit |  | Wlroots-compatible Wayland color picker that does not suck |
| hyprpolkitagent | 0.2.0 | [home](https://github.com/hyprwm/hyprpolkitagent) | zenobit |  | Simple polkit authentication agent for Hyprland, written in QT/QML |
| hyprsunset | 0.4.0 | [home](https://github.com/hyprwm/hyprsunset) | zenobit |  | Application to enable a blue-light filter on Hyprland |
| hyprsysteminfo | 0.2.0 | [home](https://github.com/hyprwm/hyprsysteminfo) | zenobit |  | Tiny qt6/qml application to display system informations |
| hyprtoolkit | 0.6.0 | [home](https://github.com/hyprwm/hyprtoolkit) | zenobit |  | Modern C++ Wayland-native GUI toolkit |
| hyprtoolkit-devel | 0.6.0 | [home](https://github.com/hyprwm/hyprtoolkit) | zenobit |  | Modern C++ Wayland-native GUI toolkit |
| hyprutils | 0.14.3 | [home](https://github.com/hyprwm/hyprutils) | zenobit |  | Hyprland utilities library used across the ecosystem |
| hyprutils-devel | 0.14.3 | [home](https://github.com/hyprwm/hyprutils) | zenobit |  | Hyprland utilities library used across the ecosystem |
| hyprwayland-scanner | 0.4.6 | [home](https://github.com/hyprwm/hyprwayland-scanner) | zenobit |  | Hyprland's implementation of wayland-scanner |
| hyprwire | 0.3.1 | [home](https://github.com/hyprwm/hyprwire) | zenobit |  | Fast and consistent wire protocol for IPC |
| hyprwire-devel | 0.3.1 | [home](https://github.com/hyprwm/hyprwire) | zenobit |  | Fast and consistent wire protocol for IPC |
| iruka-xbps | 0.2.0 | [home](https://github.com/javiercplus/iruka-xbps) | zenobit |  | Graphical front-end for the XBPS package manager |
| kairo | 1.7.3 | [home](https://github.com/programmersd21/kairo) | nerdyslacker |  | Fast, keyboard-first terminal task manager |
| kando | 3.0.1 | [home](https://kando.menu) | zenobit | x86_64 aarch64 | Do things with utmost efficiency |
| kernwatch | 0.5.1 | [home](https://www.netwatchlabs.com) | zenobit |  | Linux kernel observability in your terminal |
| kmscon | 10.0.4 | [home](https://github.com/kmscon/kmscon) | zenobit |  | Linux KMS/DRM based virtual Console Emulator |
| lazyrsync | 0.4.0 | [home](https://github.com/westpoint-io/lazyrsync) | zenobit |  | Friendly terminal UI for rsync |
| lemonade-server | 2026.44.1 | [home](https://github.com/lemonade-sdk/lemonade) | zenobit |  | Local LLM Serving with GPU and NPU acceleration (Server) |
| lgogdownloader | 3.19 | [home](https://github.com/Sude-/lgogdownloader) | zenobit |  | Unofficial downloader to GOG.com for Linux users |
| libbtrfs | 7.1 | [home](https://btrfs.wiki.kernel.org/index.php/Main_Page) | Enno Boland |  | Btrfs filesystem utilities |
| libbtrfs-devel | 7.1 | [home](https://btrfs.wiki.kernel.org/index.php/Main_Page) | Enno Boland |  | Btrfs filesystem utilities |
| libbtrfsutil | 7.1 | [home](https://btrfs.wiki.kernel.org/index.php/Main_Page) | Enno Boland |  | Btrfs filesystem utilities |
| libbtrfsutil-devel | 7.1 | [home](https://btrfs.wiki.kernel.org/index.php/Main_Page) | Enno Boland |  | Btrfs filesystem utilities |
| libcprime | 5.0.1 | [home](https://gitlab.com/cubocore/libcprime) | zenobit |  | Library for bookmarking, saving activities, sharing files and more |
| libheif | 1.23.6 | [home](https://github.com/strukturag/libheif) | zenobit |  | HEIF file format decoder and encoder + Dav1d encoding |
| libheif-devel | 1.23.6 | [home](https://github.com/strukturag/libheif) | zenobit |  | HEIF file format decoder and encoder + Dav1d encoding |
| libkrun | 1.19.6 | [home](https://github.com/libkrun/libkrun) | zenobit |  | Library providing Virtualization-based process isolation capabilities |
| libkrun-devel | 1.19.6 | [home](https://github.com/libkrun/libkrun) | zenobit |  | Library providing Virtualization-based process isolation capabilities |
| libkrunfw | 5.6.2 | [home](https://github.com/libkrun/libkrunfw) | zenobit |  | Dynamic library bundling the guest payload consumed by libkrun |
| librewolf-bin | 159.0.1 | [home](https://librewolf.net) | zenobit | x86_64 aarch64 | Community-maintained fork of Firefox focused on privacy and security |
| libspng | 0.7.4 | [home](https://libspng.org/) | zenobit |  | Simple, modern libpng alternative |
| libtsm | 4.8.0 | [home](https://github.com/kmscon/libtsm) | zenobit |  | Terminal-emulator State Machine |
| libtsm-devel | 4.8.0 | [home](https://github.com/kmscon/libtsm) | zenobit |  | Terminal-emulator State Machine |
| linuxcommandlibrary | 4.9.1 | [home](http://linuxcommandlibrary.com/) | zenobit | x86_64 aarch64 | Linux reference app with basics, tips and formatted man pages |
| linuxcommandlibrary-desktop | 4.9.1 | [home](http://linuxcommandlibrary.com/) | zenobit | x86_64 aarch64 | Linux reference app with basics, tips and formatted man pages |
| llama.cpp | 0.8.0 | [home](https://github.com/ggml-org/llama.cpp) | zenobit |  | LLM inference in C/C++ |
| llmfit | 1.1.18 | [home](https://github.com/AlexsJones/llmfit) | zenobit |  | Hundreds of models & providers, easy to find what fits your hardware |
| logseq | 2.0.2 | [home](https://logseq.com) | zenobit |  | Privacy-first, open-source knowledge management platform |
| lunasvg | 3.5.0 | [home](https://github.com/sammycage/lunasvg) | zenobit |  | SVG rendering and manipulation library in C++ |
| lunasvg-devel | 3.5.0 | [home](https://github.com/sammycage/lunasvg) | zenobit |  | SVG rendering and manipulation library in C++ |
| ly | 1.4.0 | [home](https://codeberg.org/fairyglade/ly) | zenobit | i686 x86_64 | Lightweight TUI (ncurses-like) display manager for Linux and BSD |
| lycan | 0.1.2 | [home](https://github.com/tutkuofnight/lycan) | Bella109 | x86_64* | Lightweight PWA manager for Linux |
| menu-themes | 0.9.0 | [home](https://github.com/kando-menu/menu-themes) | zenobit | x86_64 aarch64 | Collection of menu themes for Kando |
| mesa-amber | 26.1.2 | [home](https://www.mesa3d.org/) | Bella109 |  | Mesa for older hardware (legacy driver build) |
| morewaita-icon-theme | 50.1 | [home](https://github.com/somepaulo/MoreWaita) | Coolllyn |  | Expanded Adwaita-styled companion icon theme for GNOME Shell |
| morgenwm | 0.3.1 | [home](https://codeberg.org/LinuxNation/MorgenWM) | LinuxNation |  | Scrolling window manager with subframes for the River compositor |
| nano-syntax-highlighting | 2026.10.01 | [home](https://github.com/galenguyer/nano-syntax-highlighting) | Coolllyn |  | Improved nano syntax highlighting files |
| nebula-gtk | 1.3.7 | [home](https://github.com/Letdown2491/nebula-gtk) | zenobit |  | GTK frontend for Void Linux's XBPS tooling |
| noctalia | 5.4.1 | [home](https://noctalia.dev) | Coolllyn |  | Sleek, customizable desktop shell crafted for Wayland |
| noctalia-greeter | 1.7.0 | [home](https://github.com/noctalia-dev/noctalia-greeter) | Coolllyn |  | Minimal login greeter for greetd matching the Noctalia Shell look |
| notesnook | 3.4.10 | [home](https://github.com/streetwriters/notesnook) | zenobit | x86_64* aarch64* | End-to-end encrypted note taking alternative to Evernote |
| NuvioDesktop | 0.3.8 | [home](https://github.com/blarns/NuvioForLinux) | Bella109 | x86_64* | Multi Media Hub - multiple sources for watching Series, Movies and Anime |
| nvchecker | 2.22 | [home](https://github.com/lilydjwg/nvchecker) | zenobit |  | New version checker for software releases |
| nwg-bar | 0.1.6 | [home](https://github.com/nwg-piotr/nwg-bar) | zenobit |  | GTK3-based button bar for wlroots-based compositors |
| nwg-clipman | 0.2.8 | [home](https://github.com/nwg-piotr/nwg-clipman) | zenobit |  | GTK based GUI for cliphist - nwg-shell clipboard manager |
| nwg-displays | 0.5.0 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-displays) | zenobit |  | Intuitive GUI to manage multiple displays for wayland |
| nwg-dock | 0.4.3 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-dock) | zenobit |  | GTK based dock for sway |
| nwg-dock-hyprland | 0.4.11 | [home](https://github.com/nwg-piotr/nwg-dock-hyprland) | zenobit |  | GTK3-based dock for Hyprland |
| nwg-drawer | 0.7.5 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-drawer) | zenobit |  | Application drawer for wlroots-based Wayland compositors |
| nwg-hello | 0.5.1 | [home](https://github.com/nwg-piotr/nwg-hello) | zenobit |  | GTK based greeter for greetd written in python |
| nwg-icon-picker | 0.1.1 | [home](https://github.com/nwg-piotr/nwg-icon-picker) | zenobit |  | GTK icon chooser with a text search option |
| nwg-menu | 0.1.9 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-menu) | zenobit |  | MenuStart plugin to nwg-panel, also capable of working standalone |
| nwg-panel | 0.12.3 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-panel) | zenobit |  | GTK based panel for sway and Hyprland Wayland compositors |
| nwg-readme-browser | 0.1.7 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-readme-browser) | zenobit |  | WebKitGTK based README file browser |
| nwg-shell | 0.5.50 | [home](https://nwg-piotr.github.io/nwg-shell) | zenobit |  | GTK based shell for sway and Hyprland Wayland compositors |
| nwg-shell-config | 0.5.65 | [home](https://nwg-piotr.github.io/nwg-shell/nwg-shell-config) | zenobit |  | Graphical user interface for configuring sway and Hyprland |
| nwg-shell-wallpapers | 1.5 | [home](https://github.com/nwg-piotr/nwg-shell-wallpapers) | zenobit |  | Selection of wallpapers contributed to the nwg-shell project |
| oco-removed-packages | 0.1.20261006 | [home](https://repo.osowoso.org) | zenobit |  | Uninstalls packages removed from OCO repository |
| odin2 | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| odin2-clap | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| odin2-common | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| odin2-lv2 | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| odin2-standalone | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| odin2-vst3 | 2.4.1 | [home](https://thewavewarden.com/pages/odin-2) | Trve_AY |  | 24 voice polyphinic synthesizer with modulation and FX |
| omniroute | 3.8.24 | [home](https://github.com/diegosouzapw/OmniRoute) | zenobit |  | Universal AI gateway with smart routing for multiple LLM providers |
| opencode | 1.19.5 | [home](https://github.com/anomalyco/opencode) | zenobit | x86_64 aarch64 | Open source AI coding agent |
| opencode2 | 2.2.5 | [home](https://github.com/anomalyco/opencode) | zenobit | x86_64 aarch64 | Open source AI coding agent |
| OpenShell | 0.1.2 | [home](https://github.com/NVIDIA/OpenShell) | zenobit |  | OpenShell is the safe, private runtime for autonomous AI agents |
| patchance | 1.4.0 | [home](https://raysession.tuxfamily.org/) | Trve_AY |  | Jack patchbay GUI |
| pi | 1.4.0 | [home](https://github.com/earendil-works/pi) | zenobit |  | AI agent toolkit: unified LLM API, agent loop, TUI, coding agent CLI |
| pinguintv-installer-git | 0.0.0 | [home](https://pinguin-tv.de/installer.html) | Bella109 | x86_64 | New GUI Installer for void |
| pop-fonts | 0.0.0 | [home](https://github.com/pop-os/fonts) | Bella109 |  | Pop Fonts |
| pop-icons | 3.5.1 | [home](https://github.com/pop-os/icon-theme) | Bella109 |  | TODO: pop-icons short_desc |
| pop-launcher | 1.11.0 | [home](https://github.com/pop-os/launcher) | zenobit |  | Modular IPC-based desktop launcher service |
| pop-sounds-theme | 5.5.1 | [home](https://github.com/pop-os/gtk-theme) | Bella109 |  | Pop sounds theme |
| proxelar | 0.6.1 | [home](https://github.com/emanuele-em/proxelar) | zenobit |  | Scriptable local traffic workbench |
| python3-anysqlite | 0.0.5 | [home](https://github.com/karpetrosyan/anysqlite) | zenobit |  | Provides interface to sqlite3 library and supports trio and asyncio |
| python3-geographiclib | 2.1 | [home](https://geographiclib.sourceforge.io/) | zenobit |  | Python implementation of the geodesic routines |
| python3-geopy | 2.5.0 | [home](https://github.com/geopy/geopy) | zenobit |  | Geocoding library for Python |
| python3-hishel | 1.1.9 | [home](https://github.com/karpetrosyan/hishel) | zenobit |  |  Elegant HTTP Caching for Python |
| python3-inline-snapshot | 0.32.6 | [home](https://15r10nk.github.io/inline-snapshot/latest) | zenobit |  | Boosts efficiency when writing tests |
| python3-linkify-it-py | 2.1.0 | [home](https://github.com/tsutsu3/linkify-it-py) | Orphaned |  | Linkify plugin for markdown-it-py |
| python3-PyGithub | 2.10.0 | [home](https://pygithub.readthedocs.io/) | Orphan |  | Python library to access the GitHub API v3 |
| python3-structlog | 26.1.0 | [home](https://github.com/hynek/structlog) | zenobit |  | Simple, powerful, and fast logging for Python |
| python3-textual | 8.2.8 | [home](https://textual.textualize.io) | icp |  | Modern Text User Interface framework |
| python3-uc-micro-py | 2.0.0 | [home](https://github.com/tsutsu3/uc.micro-py) | Orphaned |  | Unicode category micro library |
| qrunsvmgr | 0.2.5 | [home](https://codeberg.org/ItsZariep/qrunsvmgr) | zenobit |  | Service manager GUI (Qt6), supporting Runit and Dinit |
| quickbox-gtk4 | 1.3.10 | [home](https://github.com/musqz/quickbox) | zenobit |  | GTK4 UI for managing quickemu VMs |
| quickbox-qt | 1.3.4 | [home](https://github.com/musqz/quickbox-qt) | zenobit |  | QT6 UI for managing Quickemu VMs |
| quickemu | 4.9.9 | [home](https://github.com/quickemu-project/quickemu) | zenobit |  | Quickly create and run optimised virtual machines |
| quickosdl | 0.3.2 | [home](https://github.com/lj3954/quickosdl) | zenobit |  | Tool to quickly find URLs to images and download them |
| quickshell+ | 0.3.2 | [home](https://quickshell.org) | zenobit |  | Flexible QtQuick-based desktop shell toolkit. Hyprland-enabled |
| radicle | 1.8.0 | [home](https://radicle.dev/) | zenobit |  | Peer-to-peer code collaboration stack built on Git |
| raysession | 0.18.0 | [home](https://raysession.tuxfamily.org/) | Trve_AY |  | Session manager for audio programs using the NSM API |
| rebos | 3.5.2 | [home](https://gitlab.com/Oglo12/rebos) | zenobit |  | NixOS like repeatability for any Linux distribution |
| rgc | 1.2.0 | [home](https://github.com/flameshikari/rgc) | zenobit |  | Rust alternative of grc |
| river-compositor | 0.5.0 | [home](https://codeberg.org/river/river) | LinuxNation | ~i686* ~armv6l* ~armv7l* | Non-monolithic tiling Wayland compositor |
| runkit | 1.4.0 | [home](https://github.com/Letdown2491/runkit) | zenobit |  | Graphical manager for runit services |
| rustdesk | 1.4.9 | [home](https://github.com/rustdesk/rustdesk) | Bella109 | x86_64* | Alternative to AnyDesk |
| sdkmanager | 0.7.1 | [home](https://gitlab.com/fdroid/sdkmanager) | zenobit |  | Drop-in replacement for Android sdkmanager written in Python |
| seamonkey-bin | 2.53.24 | [home](https://www.seamonkey-project.org/) | zenobit | x86_64 | All-in-one internet application suite |
| sfizz-cli | 1.2.3 | [home](https://sfztools.github.io/sfizz/) | Trve_AY |  | SFZ sampler |
| sfizz-git | 1.2.3 | [home](https://sfztools.github.io/sfizz/) | Trve_AY |  | SFZ sampler |
| sfizz-lib | 1.2.3 | [home](https://sfztools.github.io/sfizz/) | Trve_AY |  | SFZ sampler |
| sfizz-lv2 | 1.2.3 | [home](https://sfztools.github.io/sfizz/) | Trve_AY |  | SFZ sampler |
| sfizz-vst3 | 1.2.3 | [home](https://sfztools.github.io/sfizz/) | Trve_AY |  | SFZ sampler |
| shaderc | 2026.4 | [home](https://github.com/google/shaderc) | zenobit |  | Collection of tools, libraries and tests for shader compilation |
| shattered-pixel-dungeon | 4.0.2 | [home](https://github.com/00-Evan/shattered-pixel-dungeon) | zenobit |  | Open-source roguelike dungeon crawler with randomized levels and enemies |
| simplex-chat | 7.0.0 | [home](https://simplex.chat) | rayfadh | ~i686 | Private and secure messaging application (CLI) |
| simplex-chat-desktop | 7.0.0 | [home](https://simplex.chat) | rayfadh | ~i686 | Private and secure messaging application (CLI) |
| sonic-activities | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-activities) | zenobit |  | Core activity management components for SonicDE |
| sonic-activities-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-activities) | zenobit |  | Core activity management components for SonicDE |
| sonic-activities-stats | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-activities-stats) | zenobit |  | Library for accessing the usage data collected by the activities system |
| sonic-activities-stats-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-activities-stats) | zenobit |  | Library for accessing the usage data collected by the activities system |
| sonic-activity-manager-daemon | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-activity-manager-daemon) | zenobit |  | System service to manage user's activities, track the usage patterns |
| sonic-audio-applet-pulse | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-audio-applet-pulse) | zenobit |  | SonicDE applet for audio volume management using PulseAudio |
| sonic-bluetooth-runtime | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-bluetooth-runtime) | zenobit |  | Bluetooth capabilities for Sonic |
| sonic-breeze | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-breeze) | zenobit |  | Artwork, styles and assets for the Silver visual style of Sonic Desktop |
| sonic-breeze-sddm | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-breeze-sddm) | zenobit |  | Breeze SDDM theme |
| sonic-browser-integration | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-browser-integration) | zenobit |  | Components necessary to integrate browsers into the Sonic Desktop |
| sonic-crypto-library | 2.3.12 | [home](https://github.com/Sonic-DE/sonic-crypto-library) | zenobit |  | Qt Cryptographic Architecture |
| sonic-crypto-library-devel | 2.3.12 | [home](https://github.com/Sonic-DE/sonic-crypto-library) | zenobit |  | Qt Cryptographic Architecture |
| sonic-daemon | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-daemon) | zenobit |  | Central daemon of Sonic work spaces |
| sonic-daemon-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-daemon) | zenobit |  | Central daemon of Sonic work spaces |
| sonic-decoration | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-decoration) | zenobit |  | Plugin based library to create window decorations |
| sonic-decoration-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-decoration) | zenobit |  | Plugin based library to create window decorations |
| sonic-desktop-interface | 6.8.0.1 | [home](https://github.com/Sonic-DE/sonic-desktop-interface) | zenobit |  | Sonic Desktop Interface |
| sonic-disks | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-disks) | zenobit |  | Monitors S.M.A.R.T. capable devices for imminent failure |
| sonic-dr-robotnik | 6.8.0.1 | [home](https://github.com/Sonic-DE/sonic-dr-robotnik) | zenobit |  | Crash handler for Sonic software |
| sonic-drawing-tablet | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-drawing-tablet) | zenobit |  | GUI for Wacom Linux drivers with different button/pen layout profiles |
| sonic-ecco | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-ecco) | zenobit |  | File manager for Sonic |
| sonic-exiv2-library | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-exiv2-library) | zenobit |  | Wrapper around Exiv2 library to manipulate picture metadata |
| sonic-exiv2-library-devel | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-exiv2-library) | zenobit |  | Wrapper around Exiv2 library to manipulate picture metadata |
| sonic-firewall | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-firewall) | zenobit |  | Control Panel for your system firewall |
| sonic-frameworks-addons-downloader | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-addons-downloader) | zenobit |  | Framework for downloading and sharing additional application data |
| sonic-frameworks-addons-downloader-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-addons-downloader) | zenobit |  | Framework for downloading and sharing additional application data |
| sonic-frameworks-app-info | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-app-info) | zenobit |  | Query info about installed applications and their associated file types |
| sonic-frameworks-app-info-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-app-info) | zenobit |  | Query info about installed applications and their associated file types |
| sonic-frameworks-archive | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-archive) | zenobit |  | Qt addon providing access to numerous types of archives |
| sonic-frameworks-archive-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-archive) | zenobit |  | Qt addon providing access to numerous types of archives |
| sonic-frameworks-auth | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-auth) | zenobit |  | Authentication and policy abstraction layer for SonicDE frameworks |
| sonic-frameworks-auth-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-auth) | zenobit |  | Authentication and policy abstraction layer for SonicDE frameworks |
| sonic-frameworks-auth-tools | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-auth) | zenobit |  | Authentication and policy abstraction layer for SonicDE frameworks |
| sonic-frameworks-autocomplete | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-autocomplete) | zenobit |  | Sonic completion framework |
| sonic-frameworks-autocomplete-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-autocomplete) | zenobit |  | Sonic completion framework |
| sonic-frameworks-barcode | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-barcode) | zenobit |  | Barcode API to produce QRCode barcodes and DataMatrix barcodes |
| sonic-frameworks-barcode-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-barcode) | zenobit |  | Barcode API to produce QRCode barcodes and DataMatrix barcodes |
| sonic-frameworks-bluetooth | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-bluetooth) | zenobit |  | Qt wrapper for Bluez 5 D-Bus API |
| sonic-frameworks-bluetooth-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-bluetooth) | zenobit |  | Qt wrapper for Bluez 5 D-Bus API |
| sonic-frameworks-bookmarks | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-bookmarks) | zenobit |  | Bookmarks management library |
| sonic-frameworks-bookmarks-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-bookmarks) | zenobit |  | Bookmarks management library |
| sonic-frameworks-cmake-modules | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-cmake-modules) | zenobit |  | Extended CMake modules and build utilities for SonicDE frameworks |
| sonic-frameworks-color-scheme | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-color-scheme) | zenobit |  | Classes to read and interact with KColorScheme |
| sonic-frameworks-color-scheme-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-color-scheme) | zenobit |  | Classes to read and interact with KColorScheme |
| sonic-frameworks-core-addons | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-core-addons) | zenobit |  | Core Qt functionality extensions for SonicDE frameworks |
| sonic-frameworks-core-addons-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-core-addons) | zenobit |  | Core Qt functionality extensions for SonicDE frameworks |
| sonic-frameworks-crash-handler | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-crash-handler) | zenobit |  | Graceful handling of application crashes |
| sonic-frameworks-crash-handler-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-crash-handler) | zenobit |  | Graceful handling of application crashes |
| sonic-frameworks-data-models | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-data-models) | zenobit |  | Item models extending the Qt model-view framework |
| sonic-frameworks-data-models-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-data-models) | zenobit |  | Item models extending the Qt model-view framework |
| sonic-frameworks-data-views | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-data-views) | zenobit |  | Item views extending the Qt model-view framework |
| sonic-frameworks-data-views-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-data-views) | zenobit |  | Item views extending the Qt model-view framework |
| sonic-frameworks-dbus | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-dbus) | zenobit |  | KDE Convenience classes for DBus |
| sonic-frameworks-dbus-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-dbus) | zenobit |  | KDE Convenience classes for DBus |
| sonic-frameworks-device-integration | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-device-integration) | zenobit |  | Hardware integration and detection |
| sonic-frameworks-device-integration-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-device-integration) | zenobit |  | Hardware integration and detection |
| sonic-frameworks-doctools | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-doctools) | zenobit |  | DocBook-based documentation generation tools for SonicDE frameworks |
| sonic-frameworks-doctools-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-doctools) | zenobit |  | DocBook-based documentation generation tools for SonicDE frameworks |
| sonic-frameworks-feeds | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-feeds) | zenobit |  | RSS/Atom parser library |
| sonic-frameworks-feeds-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-feeds) | zenobit |  | RSS/Atom parser library |
| sonic-frameworks-file-metadata | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-file-metadata) | zenobit |  | Library for extracting file metadata |
| sonic-frameworks-file-metadata-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-file-metadata) | zenobit |  | Library for extracting file metadata |
| sonic-frameworks-file-search | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-file-search) | zenobit |  | Framework for searching and managing metadata |
| sonic-frameworks-file-search-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-file-search) | zenobit |  | Framework for searching and managing metadata |
| sonic-frameworks-gui-addons | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-gui-addons) | zenobit |  | GUI helper components and utilities for SonicDE frameworks |
| sonic-frameworks-gui-addons-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-gui-addons) | zenobit |  | GUI helper components and utilities for SonicDE frameworks |
| sonic-frameworks-gui-addons-geo-uri-handler | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-gui-addons) | zenobit |  | GUI helper components and utilities for SonicDE frameworks |
| sonic-frameworks-holidays | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-holidays) | zenobit |  | Library to assist determining when holidays occur |
| sonic-frameworks-holidays-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-holidays) | zenobit |  | Library to assist determining when holidays occur |
| sonic-frameworks-icon-themes | 6.31.0.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-icon-themes) | zenobit |  | Icon GUI utilities |
| sonic-frameworks-icon-themes-devel | 6.31.0.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-icon-themes) | zenobit |  | Icon GUI utilities |
| sonic-frameworks-idle-tracker | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-idle-tracker) | zenobit |  | Framework for detection and notification of device idle time |
| sonic-frameworks-idle-tracker-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-idle-tracker) | zenobit |  | Framework for detection and notification of device idle time |
| sonic-frameworks-image-formats | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-image-formats) | zenobit |  | Plugins to allow QImage to support extra file formats |
| sonic-frameworks-internationalization | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-internationalization) | zenobit |  | Gettext-based UI text internationalization |
| sonic-frameworks-internationalization-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-internationalization) | zenobit |  | Gettext-based UI text internationalization |
| sonic-frameworks-io | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-io) | zenobit |  | Resource and network access abstraction layer for SonicDE |
| sonic-frameworks-io-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-io) | zenobit |  | Resource and network access abstraction layer for SonicDE |
| sonic-frameworks-io-extras | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-frameworks-io-extras) | zenobit |  | Extended I/O components for SonicDE frameworks (kio-extras replacement) |
| sonic-frameworks-io-fuse | 6.0.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-io-fuse) | zenobit |  | FUSE Interface for Sonic Frameworks IO |
| sonic-frameworks-keybind | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-keybind) | zenobit |  | Global workspace shortcut system for SonicDE |
| sonic-frameworks-keybind-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-keybind) | zenobit |  | Global workspace shortcut system for SonicDE |
| sonic-frameworks-keyring | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-keyring) | zenobit |  | Safe desktop-wide storage for passwords |
| sonic-frameworks-keyring-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-keyring) | zenobit |  | Safe desktop-wide storage for passwords |
| sonic-frameworks-keyring-pam | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-keyring-pam) | zenobit |  | PAM Integration for Sonic keyring |
| sonic-frameworks-modemmanager | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-modemmanager) | zenobit |  | Qt wrapper for ModemManager DBus API |
| sonic-frameworks-modemmanager-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-modemmanager) | zenobit |  | Qt wrapper for ModemManager DBus API |
| sonic-frameworks-networkmanager | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-networkmanager) | zenobit |  | Qt wrapper for NetworkManager API |
| sonic-frameworks-networkmanager-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-networkmanager) | zenobit |  | Qt wrapper for NetworkManager API |
| sonic-frameworks-notification-settings | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-notification-settings) | zenobit |  | Configuration dialog for desktop notification |
| sonic-frameworks-notification-settings-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-notification-settings) | zenobit |  | Configuration dialog for desktop notification |
| sonic-frameworks-notifications | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-notifications) | zenobit |  | Sonic Desktop notifications |
| sonic-frameworks-notifications-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-notifications) | zenobit |  | Sonic Desktop notifications |
| sonic-frameworks-open-collab | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-open-collab) | zenobit |  | Qt library implementing Open Collaboration Services API (SonicDE fork) |
| sonic-frameworks-open-collab-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-open-collab) | zenobit |  | Qt library implementing Open Collaboration Services API (SonicDE fork) |
| sonic-frameworks-package | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-package) | zenobit |  | Installation and loading of additional content as packages |
| sonic-frameworks-package-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-package) | zenobit |  | Installation and loading of additional content as packages |
| sonic-frameworks-progress-ui | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-progress-ui) | zenobit |  | Widgets for showing progress of asynchronous jobs |
| sonic-frameworks-progress-ui-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-progress-ui) | zenobit |  | Widgets for showing progress of asynchronous jobs |
| sonic-frameworks-pseudo-terminal | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-pseudo-terminal) | zenobit |  | Interfacing with pseudo terminal devices |
| sonic-frameworks-pseudo-terminal-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-pseudo-terminal) | zenobit |  | Interfacing with pseudo terminal devices |
| sonic-frameworks-purpose | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-purpose) | zenobit |  | Framework for providing abstractions to get the dev's purposes fulfilled |
| sonic-frameworks-purpose-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-purpose) | zenobit |  | Framework for providing abstractions to get the dev's purposes fulfilled |
| sonic-frameworks-qml-bridge | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-qml-bridge) | zenobit |  | Integration of QML and Sonic work spaces |
| sonic-frameworks-qml-bridge-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-qml-bridge) | zenobit |  | Integration of QML and Sonic work spaces |
| sonic-frameworks-qt-integration | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-qt-integration) | zenobit |  | Framework to integrate applications with a KDE Workspace |
| sonic-frameworks-qt-integration-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-qt-integration) | zenobit |  | Framework to integrate applications with a KDE Workspace |
| sonic-frameworks-quick-charts | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-charts) | zenobit |  | QtQuick plugin providing high-performance charts |
| sonic-frameworks-quick-charts-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-charts) | zenobit |  | QtQuick plugin providing high-performance charts |
| sonic-frameworks-quick-desktop-style | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-desktop-style) | zenobit |  | Qt Quick Controls 2: Desktop Style |
| sonic-frameworks-quick-desktop-style-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-desktop-style) | zenobit |  | Qt Quick Controls 2: Desktop Style |
| sonic-frameworks-quick-ui | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-ui) | zenobit |  | QtQuick component set for SonicDE frameworks |
| sonic-frameworks-quick-ui-addons | 1.13.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-ui-addons) | zenobit |  | Add-ons for the Sonic quick ui framework |
| sonic-frameworks-quick-ui-addons-devel | 1.13.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-ui-addons) | zenobit |  | Add-ons for the Sonic quick ui framework |
| sonic-frameworks-quick-ui-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-quick-ui) | zenobit |  | QtQuick component set for SonicDE frameworks |
| sonic-frameworks-root-shell | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-root-shell) | zenobit |  | User interface for running shell commands with root privileges |
| sonic-frameworks-root-shell-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-root-shell) | zenobit |  | User interface for running shell commands with root privileges |
| sonic-frameworks-runner | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-runner) | zenobit |  | Framework for providing actions based on query strings (SonicDE runner) |
| sonic-frameworks-runner-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-runner) | zenobit |  | Framework for providing actions based on query strings (SonicDE runner) |
| sonic-frameworks-settings | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings) | zenobit |  | Persistent platform-independent application settings |
| sonic-frameworks-settings-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings) | zenobit |  | Persistent platform-independent application settings |
| sonic-frameworks-settings-ui | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings-ui) | zenobit |  | Widgets for configuration dialogs |
| sonic-frameworks-settings-ui-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings-ui) | zenobit |  | Widgets for configuration dialogs |
| sonic-frameworks-settings-utils | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings-utils) | zenobit |  | Utilities for Sonic System Settings modules |
| sonic-frameworks-settings-utils-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-settings-utils) | zenobit |  | Utilities for Sonic System Settings modules |
| sonic-frameworks-silver-icons | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-silver-icons) | zenobit |  | Silver icon theme |
| sonic-frameworks-silver-icons-library | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-silver-icons) | zenobit |  | Silver icon theme |
| sonic-frameworks-silver-icons-library-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-silver-icons) | zenobit |  | Silver icon theme |
| sonic-frameworks-spell-check | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-spell-check) | zenobit |  | Multi-language spell checker |
| sonic-frameworks-spell-check-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-spell-check) | zenobit |  | Multi-language spell checker |
| sonic-frameworks-sso | 8.61.2.3 | [home](https://github.com/Sonic-DE/sonic-frameworks-sso) | zenobit |  | Daemon providing SSO over D-Bus for the gSSO framework |
| sonic-frameworks-sso-devel | 8.61.2.3 | [home](https://github.com/Sonic-DE/sonic-frameworks-sso) | zenobit |  | Daemon providing SSO over D-Bus for the gSSO framework |
| sonic-frameworks-status-notification | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-status-notification) | zenobit |  | Implementation of Status Notifier Items |
| sonic-frameworks-status-notification-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-status-notification) | zenobit |  | Implementation of Status Notifier Items |
| sonic-frameworks-svg | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-svg) | zenobit |  | Library for rendering SVG-based themes |
| sonic-frameworks-svg-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-svg) | zenobit |  | Library for rendering SVG-based themes |
| sonic-frameworks-syntax-highlighting | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-syntax-highlighting) | zenobit |  | Syntax highlighting Engine for Structured Text and Code |
| sonic-frameworks-syntax-highlighting-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-syntax-highlighting) | zenobit |  | Syntax highlighting Engine for Structured Text and Code |
| sonic-frameworks-text-codec | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-codec) | zenobit |  | Collection of methods to manipulate strings using various encodings |
| sonic-frameworks-text-codec-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-codec) | zenobit |  | Collection of methods to manipulate strings using various encodings |
| sonic-frameworks-text-editor | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-editor) | zenobit |  | Full text editor component |
| sonic-frameworks-text-editor-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-editor) | zenobit |  | Full text editor component |
| sonic-frameworks-text-widgets | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-widgets) | zenobit |  | Text editing widgets |
| sonic-frameworks-text-widgets-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-text-widgets) | zenobit |  | Text editing widgets |
| sonic-frameworks-ui-components | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-ui-components) | zenobit |  | Plugin framework for user interface components |
| sonic-frameworks-ui-components-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-ui-components) | zenobit |  | Plugin framework for user interface components |
| sonic-frameworks-unit-conversion | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-unit-conversion) | zenobit |  | Physical units converter |
| sonic-frameworks-unit-conversion-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-unit-conversion) | zenobit |  | Physical units converter |
| sonic-frameworks-user-feedback | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-user-feedback) | zenobit |  | Framework for collecting user feedback via telemetry and surveys |
| sonic-frameworks-user-feedback-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-user-feedback) | zenobit |  | Framework for collecting user feedback via telemetry and surveys |
| sonic-frameworks-widgets-addons | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-widgets-addons) | zenobit |  | Large set of desktop widgets |
| sonic-frameworks-widgets-addons-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-widgets-addons) | zenobit |  | Large set of desktop widgets |
| sonic-frameworks-windowsystem | 6.31.0.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-windowsystem) | zenobit |  | Access to the windowing system (SonicDE framework fork) |
| sonic-frameworks-windowsystem-devel | 6.31.0.1 | [home](https://github.com/Sonic-DE/sonic-frameworks-windowsystem) | zenobit |  | Access to the windowing system (SonicDE framework fork) |
| sonic-frameworks-xml-gui | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-xml-gui) | zenobit |  | Framework for managing menu and toolbar actions |
| sonic-frameworks-xml-gui-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-xml-gui) | zenobit |  | Framework for managing menu and toolbar actions |
| sonic-frameworks-zeroconf | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-zeroconf) | zenobit |  | Network service discovery using Zeroconf |
| sonic-frameworks-zeroconf-devel | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-frameworks-zeroconf) | zenobit |  | Network service discovery using Zeroconf |
| sonic-gtk-theme-bridge | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-gtk-theme-bridge) | zenobit |  | Syncs Sonic settings to GTK applications |
| sonic-interface-libraries | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-interface-libraries) | zenobit |  | SonicDE library and runtime components |
| sonic-interface-libraries-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-interface-libraries) | zenobit |  | SonicDE library and runtime components |
| sonic-keybind-daemon | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-keybind-daemon) | zenobit |  | Daemon providing global keyboard shortcut functionality for SonicDE |
| sonic-keybind-daemon-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-keybind-daemon) | zenobit |  | Daemon providing global keyboard shortcut functionality for SonicDE |
| sonic-launcher-menu-edit | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-launcher-menu-edit) | zenobit |  | Menu Editor for Sonic Workspaces |
| sonic-login-manager | 6.8.0.3 | [home](https://github.com/Sonic-DE/sonic-login-manager) | zenobit |  | Sonic Login Manager |
| sonic-network-manager | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-network-manager) | zenobit |  | SonicDE applet written in QML for managing network connections |
| sonic-night-light | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-night-light) | zenobit |  | Helpers for scheduling the dark-light cycle |
| sonic-night-light-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-night-light) | zenobit |  | Helpers for scheduling the dark-light cycle |
| sonic-oxygen | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-oxygen) | zenobit |  | Classic style for Qt and Sonic applications |
| sonic-oxygen-icons | 6.31.0 | [home](https://github.com/Sonic-DE/sonic-oxygen-icons) | zenobit |  | Oxygen icon theme |
| sonic-oxygen-sounds | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-oxygen-sounds) | zenobit |  | Oxygen Sound Theme |
| sonic-partition-manager | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-partition-manager) | zenobit |  | Manage the disk devices, partitions and file systems on your computer |
| sonic-pipewire | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-pipewire) | zenobit |  | Components to use PipeWire in Qt projects |
| sonic-pipewire-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-pipewire) | zenobit |  | Components to use PipeWire in Qt projects |
| sonic-plasma5-support-library | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-plasma5-support-library) | zenobit |  | Support components for porting from KF5/Qt5 to KF6/Qt6 |
| sonic-plasma5-support-library-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-plasma5-support-library) | zenobit |  | Support components for porting from KF5/Qt5 to KF6/Qt6 |
| sonic-polkit | 0.201.2 | [home](https://github.com/Sonic-DE/sonic-polkit) | zenobit |  | Qt wrapper around Polkit-1 client libraries |
| sonic-polkit-agent | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-polkit-agent) | zenobit |  | Daemon providing a Polkit authentication UI for Sonic |
| sonic-polkit-devel | 0.201.2 | [home](https://github.com/Sonic-DE/sonic-polkit) | zenobit |  | Qt wrapper around Polkit-1 client libraries |
| sonic-pulseaudio-library | 1.8.1 | [home](https://github.com/Sonic-DE/sonic-pulseaudio-library) | zenobit |  | Qt bindings for Pulseaudio |
| sonic-pulseaudio-library-devel | 1.8.1 | [home](https://github.com/Sonic-DE/sonic-pulseaudio-library) | zenobit |  | Qt bindings for Pulseaudio |
| sonic-qt-accounts-library | 1.17.2 | [home](https://github.com/Sonic-DE/sonic-qt-accounts-library) | zenobit |  | Qt-based client library for the accounts database |
| sonic-qt-accounts-library-devel | 1.17.2 | [home](https://github.com/Sonic-DE/sonic-qt-accounts-library) | zenobit |  | Qt-based client library for the accounts database |
| sonic-qt-theme-bridge | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-qt-theme-bridge) | zenobit |  | Qt platform theme integration plugins for Sonic Workspaces |
| sonic-quick-image-editor | 0.7.0.1 | [home](https://github.com/Sonic-DE/sonic-quick-image-editor) | zenobit |  | QtQuick-based image editing components |
| sonic-quick-image-editor-devel | 0.7.0.1 | [home](https://github.com/Sonic-DE/sonic-quick-image-editor) | zenobit |  | QtQuick-based image editing components |
| sonic-rdp | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-rdp-server) | zenobit |  | Library and examples for creating an RDP server |
| sonic-screen | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-screen) | zenobit |  | SonicDE screen management software |
| sonic-screen-library | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-screen-library) | zenobit |  | Screen management library for SonicDE Workspaces |
| sonic-screen-library-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-screen-library) | zenobit |  | Screen management library for SonicDE Workspaces |
| sonic-screenies | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-screenies) | zenobit |  | Screenshot capture utility |
| sonic-screenlocker | 6.8.0.1 | [home](https://github.com/Sonic-DE/sonic-screenlocker) | zenobit |  | Library and components for secure lock screen architecture |
| sonic-screenlocker-devel | 6.8.0.1 | [home](https://github.com/Sonic-DE/sonic-screenlocker) | zenobit |  | Library and components for secure lock screen architecture |
| sonic-silver | 6.8.0.1 | [home](https://github.com/Sonic-DE/sonic-silver) | zenobit |  | Customizable theme for Sonic Desktop |
| sonic-silver-gtk | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-silver-gtk) | zenobit |  | Silver widget theme for GTK 2 and 3 |
| sonic-silver-sddm | 1.1.0 | [home](https://github.com/Sonic-DE/silver-sddm) | zenobit |  | Sonic Silver SDDM Theme (KDE Plasma 6) |
| sonic-ssh-password-prompt | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-ssh-password-prompt) | zenobit |  | Ssh-add helper for QtKeychain |
| sonic-system-info | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-system-info) | zenobit |  | System information tool for Sonic Desktop |
| sonic-system-log | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-system-log) | zenobit |  | Sonic SystemLog Viewer |
| sonic-system-monitor | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-system-monitor) | zenobit |  | Application for monitoring system resources |
| sonic-system-monitor-library | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-system-monitor-library) | zenobit |  | Library to retrieve info on the current status of computer hardware |
| sonic-system-monitor-library-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-system-monitor-library) | zenobit |  | Library to retrieve info on the current status of computer hardware |
| sonic-system-stats | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-system-stats) | zenobit |  | Plugin based system monitoring daemon |
| sonic-terminal | 26.08.2 | [home](https://github.com/Sonic-DE/sonic-terminal) | zenobit |  | Terminal emulator for SonicDE |
| sonic-terminal-tools | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-terminal-tools) | zenobit |  | Tools based on Sonic Frameworks to better interact with the system |
| sonic-thunderbolt | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-thunderbolt) | zenobit |  | Sonic integration for controlling Thunderbolt devices |
| sonic-tv-interface | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-tv-interface) | zenobit |  | Interface for large screens such as TVs |
| sonic-vault | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-vault) | zenobit |  | Sonic applet and services for creating encrypted vaults |
| sonic-win | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-win) | zenobit |  | KWin X11 fork with Sonic patches |
| sonic-win-devel | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-win) | zenobit |  | KWin X11 fork with Sonic patches |
| sonic-workspace | 6.8.0.3 | [home](https://github.com/Sonic-DE/sonic-workspace) | zenobit |  | Sonic Plasma Workspace (X11-focused) |
| sonic-workspace-addons | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-workspace-addons) | zenobit |  | All kinds of addons to improve SonicDE experience |
| sonic-workspace-devel | 6.8.0.3 | [home](https://github.com/Sonic-DE/sonic-workspace) | zenobit |  | Sonic Plasma Workspace (X11-focused) |
| sonic-workspace-library | 6.8.0.3 | [home](https://github.com/Sonic-DE/sonic-workspace) | zenobit |  | Sonic Plasma Workspace (X11-focused) |
| sonic-workspace-wallpapers | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-workspace-wallpapers) | zenobit |  | Additional wallpapers for the Sonic Workspace |
| sonic-workspace-x11 | 6.8.0.3 | [home](https://github.com/Sonic-DE/sonic-workspace) | zenobit |  | Sonic Plasma Workspace (X11-focused) |
| sonic-write-daemon | 6.8.0 | [home](https://github.com/Sonic-DE/sonic-write-daemon) | zenobit |  | Listen to traditional system notifications |
| sonicde-meta | 6.8 | [home](https://github.com/Sonic-DE) | zenobit |  | Meta package for Sonic Desktop Environment (X11-focused KDE fork) |
| surfer-cli | 7.4.0 | [home](https://github.com/cloudron-io/surfer) | zenobit |  | Command line interface for surfer |
| surfer-server | 7.4.0 | [home](https://github.com/cloudron-io/surfer) | zenobit |  | Simple static file server with web interface and resumable uploads |
| surge-xt | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| surge-xt-clap | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| surge-xt-common | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| surge-xt-lv2 | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| surge-xt-standalone | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| surge-xt-vst3 | 1.3.4 | [home](https://surge-synthesizer.github.io/) | Trve_AY |  | Subtractive hybrid synthesizer |
| sv-helper | 5.0.0 | [home](https://github.com/rubyists/sv-helper) | zenobit |  | Utilities to help administer a runit-as-pid1 system |
| svi | 0.2.2 | [home](https://codeberg.org/LinuxNation/svi) | zenobit |  | Graphical installer for Void Linux, built with GTK4 and Python |
| svlog | 0.6.3 | [home](https://github.com/pascal-huber/svlog) | Coolllyn |  | Display, filter and follow socklog log files on Void Linux |
| SysMan | 0.024 | [home](https://codeberg.org/oSoWoSo/SysMan) | zenobit |  | System Manager |
| syswatch | 0.14.4 | [home](https://www.netwatchlabs.com) | zenobit |  | Single-host system diagnostics TUI |
| tdf | 0.5.0 | [home](https://github.com/itsjunetime/tdf) | zenobit |  | TUI PDF viewer |
| tiki | 0.6.1 | [home](https://github.com/boolean-maybe/tiki) | zenobit |  | Terminal Markdown-based shapeless workflow builder |
| tls-client | 1.18.0 | [home](https://github.com/bogdanfinn/tls-client) | zenobit |  | Net/http.Client like HTTP Client |
| Trilium | 0.106.1 | [home](https://github.com/TriliumNext/Trilium) | zenobit |  | Build your personal knowledge base with Trilium Notes |
| tufw | 0.2.8 | [home](https://github.com/peltho/tufw) | zenobit |  | Terminal UI for ufw |
| tuios | 0.12.0 | [home](https://github.com/Gaurav-Gosain/tuios) | zenobit |  | Terminal UI OS (Terminal Multiplexer) |
| tuisic | 2.5.2 | [home](https://github.com/Dark-Kernel/tuisic) | zenobit |  | TUI online music streaming application |
| typobuster | 1.0.0 | [home](https://github.com/nwg-piotr/typobuster) | zenobit |  | Lightweight editor with text transformations and auto-correction |
| umbriel-git | 0.1.0.20261031 | [home](https://github.com/noctalia-dev/umbriel) | Coolllyn |  | Wayland compositor built on wlroots |
| undelete-btrfs | 1.0 | [home](https://github.com/danthem/undelete-btrfs) | zenobit |  | Undelete files in a BTRFS file system |
| vbm | 1.0.2 | [home](https://codeberg.org/oSoWoSo/vbm) | zenobit |  | XBPS package management helper for VoidLinux |
| vibepanel | 0.17.2 | [home](https://github.com/prankstr/vibepanel) | LinuxNation |  | GTK4 panel for Wayland with notifications, OSD, and quick settings |
| Vish | 1.1.5 | [home](https://github.com/Lluciocc/Vish) | zenobit |  | Visual Scripting for Bash |
| vm-curator | 1.5.0 | [home](https://github.com/mroboff/vm-curator) | zenobit |  | TUI to build and manage QEMU/KVM virtual machines |
| void-hardwaremanager-git | 0.0.0 | [home](https://codeberg.org/pinguin-void/Void-Driver-App) | zenobit | x86_64 aarch64 | Modern GTK4 setup tool for Void Linux |
| void-live-creator-git | 0.0.0 | [home](https://codeberg.org/pinguin-void/void-live-creator) | zenobit |  | Create a live ISO from a running system |
| void-software-store | 1.9.4.02 | [home](https://codeberg.org/oSoWoSo/void-software-store) | zenobit |  | GUI Software Management |
| void-software-store-git | 999 | [home](https://codeberg.org/pinguin-void/void-software-store) | zenobit |  | GUI Software Management |
| void-src-builder-git | 0.0.0 | [home](https://codeberg.org/pinguin-void/void-src-builder) | zenobit |  | Build packages from the Void source code |
| void-user-manager-git | 0.0.0 | [home](https://codeberg.org/pinguin-void/void-user-manager) | zenobit | x86_64 | Modern, lightweight user and service management application |
| vote | 0.92 | [home](https://codeberg.org/oSoWoSo/vote) | zenobit |  | XBPS package management helper for VoidLinux |
| vtm | 2026.10.12 | [home](https://github.com/directvt/vtm) | zenobit |  | Text-based desktop environment |
| waterfox-bin | 6.7.7 | [home](https://www.waterfox.net) | zenobit | x86_64 aarch64 | Fast and private web browser |
| wpgtk | 6.7.1 | [home](https://github.com/deviantfero/wpgtk/) | zenobit |  | Colorscheme, wallpaper and template manager for *nix |
| xdg-desktop-portal-cosmic | 1.11.0 | [home](https://github.com/pop-os/xdg-desktop-portal-cosmic) | zenobit |  | Backend implementation for xdg-desktop-portal for COSMIC |
| xdg-desktop-portal-hyprland | 1.4.1 | [home](https://github.com/hyprwm/xdg-desktop-portal-hyprland) | zenobit |  | Backend of xdg-desktop-portal for Hyprland |
| xdg-desktop-portal-sonicde | 6.8.0 | [home](https://github.com/Sonic-DE/xdg-desktop-portal-sonicde) | zenobit |  | Backend implementation for xdg-desktop-portal that is using Qt/Sonic |
| xdg-desktop-portal-umbriel-git | 0.1.0.20261030 | [home](https://github.com/noctalia-dev/xdg-desktop-portal-umbriel) | Coolllyn |  | XDG Desktop Portal backend for the Umbriel compositor |
| xut | 0.4.2 | [home](https://codeberg.org/mobinmob/xut) | mobinmob |  | Work with templates from unofficial repositories |
| xxtools-git | 0.0.0 | [home](https://github.com/Piraty/xxtools) | zenobit |  | Tools to ease packaging tasks for Void Linux |
| zen-browser-bin | 1.24 | [home](https://github.com/zen-browser/desktop) | Bella109 | x86_64 aarch64 | New Browser based on Firefox |
| zig | 0.16.0 | [home](https://ziglang.org) | Bella109 | x86_64* aarch64* | Programming language designed for robustness, optimality, and clarity |
