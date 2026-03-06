import yaml
import sys

def merge(base, patch):
    if isinstance(base, dict) and isinstance(patch, dict):
        for k, v in patch.items():
            if k in base:
                base[k] = merge(base[k], v)
            else:
                base[k] = v
    elif isinstance(base, list) and isinstance(patch, list):
        # Simplistic merge for lists: replace for this test or append?
        # Talos usually merges lists by index or replaces them.
        # Let's see what happens if we replace them.
        return patch
    else:
        return patch
    return base

with open('common_config/k8s/talos/config/controlplane.yaml', 'r') as f:
    base = yaml.safe_load(f)

with open('configs/machine-patches.yaml', 'r') as f:
    patch = yaml.safe_load(f)

result = merge(base, patch)
print(yaml.dump(result))
