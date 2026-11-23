#!/usr/bin/env bash
# Install what the Wine tests need on a GitHub Ubuntu runner:
#
#   ci/wine/install-wine.sh winehq   x86_64 runner: WineHQ's stable Wine (11.x)
#   ci/wine/install-wine.sh distro   arm64 runner: the distribution's Wine (WineHQ builds none for arm64)
#
# Why WineHQ on x86_64: under the runner's own Wine (Ubuntu 26.04's 10.0) ghostty.exe exited
# before its window appeared, and Ubuntu 24.04's 9.0 showed the window black and unfocused,
# while the same zip passes under Wine 11. WineHQ's key is ASCII-armored; apt 3 reads armor
# only from a .asc file, and the .sources file names winehq-archive.key, so it is stored
# dearmored. Both add a virtual X server, xdotool, ImageMagick and Mesa (llvmpipe).
set -euo pipefail
case ${1:-} in
winehq)
	sudo dpkg --add-architecture i386
	sudo mkdir -pm755 /etc/apt/keyrings
	wget -q -O- https://dl.winehq.org/wine-builds/winehq.key | sudo gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key
	codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
	sudo wget -q -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/$codename/winehq-$codename.sources"
	sudo apt-get update -q
	sudo apt-get install -y -q --install-recommends winehq-stable > /dev/null
	;;
distro)
	sudo apt-get update -q
	sudo apt-get install -y -q --no-install-recommends wine > /dev/null
	;;
*) echo "usage: $0 winehq|distro" >&2; exit 2 ;;
esac
sudo apt-get install -y -q --no-install-recommends xvfb xauth xdotool imagemagick mesa-utils libgl1-mesa-dri python3 > /dev/null
wine --version
