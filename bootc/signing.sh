#!/bin/sh
# Makes machines running the image refuse updates that aren't signed with
# bootc/cosign.pub (used by bootc/Containerfile when IMAGE_REPO is set and
# bootc/cosign.pub exists). Machines then track the image as
#   ostree-image-signed:docker://<IMAGE_REPO>:<tag>
set -eux
repo="$1"     # e.g. ghcr.io/philng/machine-setup-sway
pub="$2"      # the public key

install -D -m 0644 "$pub" /etc/pki/containers/machine-setup.pub

# Signatures live next to the image in the registry (sigstore attachments).
install -d -m 0755 /etc/containers/registries.d
cat > /etc/containers/registries.d/machine-setup.yaml <<YAML
docker:
  $repo:
    use-sigstore-attachments: true
YAML

# Add a rule for this repository to the existing policy; everything else is
# left as it was.
python3 - "$repo" <<'PY'
import json, sys
repo = sys.argv[1]
path = "/etc/containers/policy.json"
policy = json.load(open(path))
policy.setdefault("transports", {}).setdefault("docker", {})[repo] = [{
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/machine-setup.pub",
    "signedIdentity": {"type": "matchRepository"},
}]
with open(path, "w") as f:
    json.dump(policy, f, indent=2)
    f.write("\n")
PY
python3 -c 'import json; json.load(open("/etc/containers/policy.json"))'
