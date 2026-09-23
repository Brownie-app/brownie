#!/bin/zsh
# Generate the Sparkle EdDSA keypair once. The private key goes to your Keychain (Sparkle's tool
# stores it) and the public key must be added to Info.plist as SUPublicEDKey (bundle.sh reads
# SPARKLE_PUBLIC_KEY from .secrets/brownie.env).
set -e
cd "$(dirname "$0")/.."
GEN=$(find .build -name generate_keys -type f | head -1)
[ -z "$GEN" ] && { echo "build once first (swift build) so Sparkle's tools are present"; exit 1; }
"$GEN" | tee /dev/stderr | grep -o 'SUPublicEDKey.*' || true
echo "Paste the public key into .secrets/brownie.env as SPARKLE_PUBLIC_KEY=… and set APPCAST_URL=https://<your domain>/appcast.xml"
