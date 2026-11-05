# Buddy Companion

Companion extension for the Buddy macOS app. It connects to `~/Library/Application Support/Buddy/buddy.sock`. It types prompts into, and focuses, integrated terminals on request.

## Build

    npm ci
    npm run build
    npm test
    npm run package

## Install

From Open VSX (once published): open the Extensions view in Cursor or VS Code and search "Buddy Companion" (`tiagosantos-local.buddy-companion`). Updates arrive through the editor.

From the Buddy app: Settings → Hooks & Extension → **Install in VS Code** / **Install in Cursor**. This installs the `.vsix` bundled with the app and still works without the registry.

From a local build:

    code --install-extension vscode-ext/buddy-companion-<version>.vsix
    cursor --install-extension vscode-ext/buddy-companion-<version>.vsix

## Publish

    OVSX_PAT=<token> npm run publish:ovsx

Details: `docs/RELEASING.md`, section "Extension on Open VSX".

## Commands

- **Buddy: Show Log** opens the extension log.
