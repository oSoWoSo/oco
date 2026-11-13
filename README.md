## This is:
vOid Community repOsitory (oco)  
aka
- Void User Repository
- testing repository (CI candidate packages)
- waiting list
- void unstable

Providing:
- templates
- binaries

by community for community

## DISCLAIMER
This project is **not affiliated with or endorsed by the Void Linux project** or its maintainers.  
It is an **unofficial community repository** designed to simplify managing and building user-contributed packages using the void-packages build system.  
Use at your own discretion.

## Overview
A collection of template files for building packages on Void Linux.  
If you dont wish to build the packages locally,  
https://repo.osowoso.org repository provides prebuilt binaries.  
Pick your architecture there and you will see

## Structure (PRs accepted on Codeberg and GitHub 🤗)
- Codeberg repository with templates  
https://codeberg.org/oSoWoSo/oco
- Github repository (CI - Here we build binary packages)  
https://github.com/oSoWoSo/oco
- To make CI quicker we use daily updated Bootstrap Docker images from  
https://github.com/oSoWoSo/oco-builder
- Binary repositories  
https://repo.osowoso.org
- Just built (RSS feed)  
https://repo.osowoso.org/feed.xml
- GitLab mirror (only push, no PRs or issues accepted)  
https://gitlab.com/osowoso/oco

## What we don't build? (From source)
Browsers: It's waste of energy and when you finish building is maybe already new version out  
We provide repackaged binaries, they all have `-bin` after <pkgname>  
(You can use AppImages and manage them with [AM](https://github.com/ivan-hc/AM), or flatpaks. They are usualy always latest)

## How to use
in https://repo.osowoso.org/`(architecture)`  
are easy to understand READMEs  
Just pick your architecture

### Testing repository
CI candidate packages are kept separate from production at  `https://repo.osowoso.org/testing/<architecture>/`  
Browse the [testing repository guide](https://repo.osowoso.org/testing.html) for target architectures,  
publication rules, and install instructions.

For a one-off install without changing permanent configuration:

```sh
sudo xbps-install -S -R https://repo.osowoso.org/testing/x86_64 package-name
```

For several installs, temporarily enable the channel and remove it afterwards:

```sh
printf 'repository=https://repo.osowoso.org/testing/x86_64\n' | sudo tee /etc/xbps.d/99-oco-testing.conf
sudo xbps-install -S package-name
sudo rm /etc/xbps.d/99-oco-testing.conf
sudo xbps-install -S
```

### Developers only
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
When you change any shlib from upstream void-packages,  
changes must be reflected in `shlibs_remove` and `shlibe_append`  
When you add new shlib add it only to `shlibe_append`

### Updating package groups
`./bump.sh <group> <operation>` manages the package groups defined in  
`.github/autobump-packs.tsv` against the void-packages checkout at `~/void` by  
default. Add a group and its package-name glob patterns to that file to make  
the group available to both the helper and CI autobumping. Set `XBPS_DISTDIR`  
(or `CLONE_DEST`) to use another checkout; `sourceDir` and `destinationDir`  
can override the source and OCO template directories. Operations include  
`--lint`, `--build`, `--bump`, `--copy`, `--install`, `--order`, and `--all`.  
Review template and shlibs changes before committing them.

The helper's `--order` and `--build` use `xbps-src sort-dependencies` to sort  
the XBPS-known dependency graph without compiling packages. XBPS evaluates  
template-declared dependencies and subpackages; runtime dependencies that are  
only discoverable from built binaries cannot be guaranteed before a build.  
Sonic's `sonic-*` pattern automatically includes new Sonic templates.

The autobump workflow runs in the `oco-builder` image and resolves the current  
graph with `xbps-src show-build-deps`, without compiling packages. When a  
package in a configured pack has an upstream update, CI checks the whole pack  
for newer versions and revision-bumps only known direct consumers of changed  
packages. The resulting PR uses the ordinary template-change build workflow;  
XBPS can discover any remaining build-time dependencies there. Add a pattern  
row to `.github/autobump-packs.tsv` when introducing another pack.

The GitHub build workflow detects changed templates under `srcpkgs/` and builds  
the affected packages with their required build dependencies in `oco-builder`  
images. The local `bump.sh` helper is not run directly by CI.  
After adding template, run `./ocoman -u` to regenerate templates list and table  
One commit per template, mesage: `<pkgname> <version>`

Create PR to Codeberg or GitHub

## Void official documentation
- [Manual](https://github.com/void-linux/void-packages/blob/master/Manual.md)
- [Contributing](https://github.com/void-linux/void-packages/blob/master/CONTRIBUTING.md)
- [Readme](https://github.com/void-linux/void-packages/blob/master/README.md)

## Available packages lists on website
