#!/usr/bin/env bash
# Installs the latest stable Go toolchain into /usr/local/go (run as root).
set -euo pipefail
V="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
echo "Latest Go: ${V}"
curl -fsSL "https://dl.google.com/go/${V}.linux-amd64.tar.gz" -o /tmp/go.tgz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm -f /tmp/go.tgz
cat > /etc/profile.d/go.sh <<'EOF'
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
EOF
/usr/local/go/bin/go version
