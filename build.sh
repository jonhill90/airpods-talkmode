#!/bin/zsh
# Rebuild and install TalkMode.app to ~/Applications and the talkmode CLI to ~/.local/bin
set -e; cd "${0:a:h}"
APP="$HOME/Applications/TalkMode.app"
mkdir -p "$APP/Contents/MacOS" "$HOME/.local/bin"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/TalkMode"
codesign --force -s - "$APP"
ln -sf "$PWD/talkmode" "$HOME/.local/bin/talkmode"
echo "installed $APP and ~/.local/bin/talkmode"
