# Buddy Companion

Companion extension for the Buddy macOS app. It connects to `~/Library/Application Support/Buddy/buddy.sock`. It types prompts into, and focuses, integrated terminals on request.

## Build

    npm ci
    npm run build
    npm test
    npm run package

## Install

    code --install-extension vscode-ext/buddy-companion-<version>.vsix
    cursor --install-extension vscode-ext/buddy-companion-<version>.vsix

## Commands

- **Buddy: Show Log** opens the extension log.
