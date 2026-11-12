# gitleaks, the latest release binary, checked against the checksums its release publishes.
gitleaks_install() {
  if [ ! -x "$ARENA_TOOLS/gitleaks/gitleaks" ]; then
    mkdir -p "$ARENA_TOOLS/gitleaks"
    local tag v
    tag=$(latest_tag gitleaks/gitleaks)
    v=${tag#v}
    curl -sS -L -m 120 -o "$ARENA_TOOLS/gitleaks/gitleaks.tgz" "https://github.com/gitleaks/gitleaks/releases/download/$tag/gitleaks_${v}_linux_x64.tar.gz"
    local want got
    want=$(curl -sS -L -m 30 "https://github.com/gitleaks/gitleaks/releases/download/$tag/gitleaks_${v}_checksums.txt" | grep "gitleaks_${v}_linux_x64.tar.gz" | cut -d' ' -f1)
    got=$(sha256sum "$ARENA_TOOLS/gitleaks/gitleaks.tgz" | cut -d' ' -f1)
    [ "$want" = "$got" ] || { echo "gitleaks: the download's hash isn't the published one" >&2; return 1; }
    tar -xzf "$ARENA_TOOLS/gitleaks/gitleaks.tgz" -C "$ARENA_TOOLS/gitleaks" gitleaks && rm "$ARENA_TOOLS/gitleaks/gitleaks.tgz"
  fi
  version gitleaks "$("$ARENA_TOOLS/gitleaks/gitleaks" version)"
}
