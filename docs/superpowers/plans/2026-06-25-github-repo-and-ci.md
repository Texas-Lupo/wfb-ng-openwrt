# GitHub Repo + Rolling-Build CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish this build to a public GitHub repo and add one GitHub Actions workflow that builds the CPE510 firmware on every `master` push and publishes it to a rolling `latest` prerelease.

**Architecture:** A single workflow on `ubuntu-latest` frees disk, builds the two heavy Docker images with `docker buildx` + GitHub Actions layer cache, runs the existing `WFB_REUSE_IMAGES=1 ./build.sh all`, and publishes `output/` to a fixed `latest` prerelease. A one-line `build.sh` flag lets CI reuse the buildx-built images instead of rebuilding them.

**Tech Stack:** GitHub Actions, `docker/build-push-action@v6` (buildx + `type=gha` cache), `softprops/action-gh-release@v2`, `gh` CLI, POSIX sh / bash.

## Global Constraints

- **Repo:** `gilankpam/wfb-ng-openwrt`, **public**, default branch `master`.
- **Execute on `master` directly** — the repo is local-only until Task 3 publishes it; there is no remote default branch to protect, and publishing `master` is the goal.
- **Trigger:** `push` to `master` + `workflow_dispatch`. **Concurrency** `rolling-build`, `cancel-in-progress: true`.
- **Publish:** the 6 `…tplink_cpe510-v{1,2,3}-squashfs-{factory,sysupgrade}.bin` + `drone.key` to a **`latest` prerelease** (fixed tag, assets replaced each run).
- **Permissions:** `contents: write`. **No external secrets** (fork is public; default `GITHUB_TOKEN`).
- **Docker image tags must match `build.sh`:** `wfbng-sdk:${OPENWRT_VERSION}`, `wfbng-ib:${OPENWRT_VERSION}`.
- **Pinned values come from `versions.env`** (`OPENWRT_VERSION=25.12.4`, `OPENWRT_TARGET=ath79`, `OPENWRT_SUBTARGET=generic`, `WFB_REPO`, `WFB_COMMIT`, `WFB_VERSION`).
- **`build.sh` local behavior must not change** when `WFB_REUSE_IMAGES` is unset.

---

## File Structure

| File | Responsibility |
|---|---|
| `build.sh` | **Modify:** skip `docker build` of the SDK/IB images when `WFB_REUSE_IMAGES` is set (CI reuses buildx-built images). |
| `tests/test_build_reuse.sh` | **Create:** stub-`docker` test proving the reuse flag skips image builds and the default still builds. |
| `.github/workflows/build.yml` | **Create:** the rolling build+publish workflow. |
| `README.md` | **Modify:** CI status badge + "download latest firmware" link. |

---

## Task 1: `build.sh` image-reuse flag (+ test)

**Files:**
- Modify: `build.sh` (functions `build_sdk_image`, `build_ib_image`)
- Test: `tests/test_build_reuse.sh`

**Interfaces:**
- Produces: env contract `WFB_REUSE_IMAGES` — when set to a non-empty value, `build.sh` does **not** run `docker build` for the SDK/IB images (it assumes they already exist in the daemon); when unset, behavior is unchanged. CI (Task 2) sets `WFB_REUSE_IMAGES=1`.

- [ ] **Step 1: Write the failing test `tests/test_build_reuse.sh`**

```sh
#!/bin/sh
# Verify WFB_REUSE_IMAGES controls whether build.sh runs `docker build` for the
# SDK/IB images. Uses a stub `docker` on PATH that logs only its subcommand.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
fail=0

run_with_stub() {  # $1 = value for WFB_REUSE_IMAGES ; echoes the docker-call log
  TMP=$(mktemp -d); BIN="$TMP/bin"; mkdir -p "$BIN"
  printf '#!/bin/sh\necho "$1" >> "%s/log"\nexit 0\n' "$TMP" > "$BIN/docker"
  chmod +x "$BIN/docker"
  ( cd "$ROOT" && PATH="$BIN:$PATH" WFB_REUSE_IMAGES="$1" ./build.sh package >/dev/null 2>&1 )
  cat "$TMP/log" 2>/dev/null
  rm -rf "$TMP"
}

reuse=$(run_with_stub 1)
if printf '%s\n' "$reuse" | grep -qx build; then echo "NOT ok - docker build ran with WFB_REUSE_IMAGES=1"; fail=1; else echo "ok - image build skipped when WFB_REUSE_IMAGES=1"; fi
if printf '%s\n' "$reuse" | grep -qx run;   then echo "ok - stage container still runs"; else echo "NOT ok - stage 'docker run' missing"; fail=1; fi

default=$(run_with_stub "")
if printf '%s\n' "$default" | grep -qx build; then echo "ok - image build runs by default"; else echo "NOT ok - docker build missing by default"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `sh tests/test_build_reuse.sh`
Expected: FAIL — with `WFB_REUSE_IMAGES=1` the current `build.sh` still runs `docker build`, so the first check prints `NOT ok - docker build ran with WFB_REUSE_IMAGES=1` and the script exits non-zero with `FAILURES`.

- [ ] **Step 3: Add the guard to both image-build functions in `build.sh`**

In `build_sdk_image()`, make the first line of the body:
```sh
build_sdk_image() {
  if [ -n "${WFB_REUSE_IMAGES:-}" ]; then
    echo "Reusing $SDK_IMAGE (WFB_REUSE_IMAGES set)"; return 0
  fi
  docker build -t "$SDK_IMAGE" \
```
In `build_ib_image()`, the same:
```sh
build_ib_image() {
  if [ -n "${WFB_REUSE_IMAGES:-}" ]; then
    echo "Reusing $IB_IMAGE (WFB_REUSE_IMAGES set)"; return 0
  fi
  docker build -t "$IB_IMAGE" \
```
(Leave the rest of each function unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `sh tests/test_build_reuse.sh`
Expected: three `ok -` lines and `ALL PASS`.

- [ ] **Step 5: Make the test executable and commit**

```bash
chmod +x tests/test_build_reuse.sh
git add build.sh tests/test_build_reuse.sh
git commit -m "build.sh: add WFB_REUSE_IMAGES to skip image builds in CI"
```

---

## Task 2: GitHub Actions workflow + README

**Files:**
- Create: `.github/workflows/build.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `WFB_REUSE_IMAGES` (Task 1); `build.sh` targets `package`/`image`/`all`; the Dockerfiles' `OPENWRT_*` build-args; `versions.env`.
- Produces: a workflow named `build` that publishes a `latest` prerelease with the firmware assets.

- [ ] **Step 1: Write `.github/workflows/build.yml`**

```yaml
name: build

on:
  push:
    branches: [master]
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: rolling-build
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Free disk space
        run: |
          sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/.ghcup \
                      /usr/local/lib/android /opt/hostedtoolcache/CodeQL
          sudo docker image prune -af || true
          df -h /

      - name: Load pinned versions into env
        run: grep -E '^(OPENWRT|WFB)_' versions.env >> "$GITHUB_ENV"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build SDK image (gha cache)
        uses: docker/build-push-action@v6
        with:
          context: docker
          file: docker/Dockerfile.sdk
          load: true
          tags: wfbng-sdk:${{ env.OPENWRT_VERSION }}
          build-args: |
            OPENWRT_VERSION=${{ env.OPENWRT_VERSION }}
            OPENWRT_TARGET=${{ env.OPENWRT_TARGET }}
            OPENWRT_SUBTARGET=${{ env.OPENWRT_SUBTARGET }}
          cache-from: type=gha,scope=sdk
          cache-to: type=gha,scope=sdk,mode=max

      - name: Build ImageBuilder image (gha cache)
        uses: docker/build-push-action@v6
        with:
          context: docker
          file: docker/Dockerfile.imagebuilder
          load: true
          tags: wfbng-ib:${{ env.OPENWRT_VERSION }}
          build-args: |
            OPENWRT_VERSION=${{ env.OPENWRT_VERSION }}
            OPENWRT_TARGET=${{ env.OPENWRT_TARGET }}
            OPENWRT_SUBTARGET=${{ env.OPENWRT_SUBTARGET }}
          cache-from: type=gha,scope=ib
          cache-to: type=gha,scope=ib,mode=max

      - name: Build firmware
        run: WFB_REUSE_IMAGES=1 ./build.sh all

      - name: Generate release notes
        run: |
          {
            echo "Rolling firmware build from commit \`${GITHUB_SHA}\`."
            echo
            echo "- OpenWrt: ${OPENWRT_VERSION} (${OPENWRT_TARGET}/${OPENWRT_SUBTARGET})"
            echo "- wfb-ng: ${WFB_REPO} @ \`${WFB_COMMIT}\`"
            echo "- Built (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo
            echo "### Images"
            ( cd output && for f in *.bin; do printf -- '- `%s` (%s)\n' "$f" "$(du -h "$f" | cut -f1)"; done )
            echo
            echo "> The baked \`gs.key\`/\`drone.key\` are a shared **test** key — regenerate and reflash for a real link."
          } > release-notes.md
          cat release-notes.md

      - name: Publish rolling 'latest' release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          prerelease: true
          name: Latest firmware build (${{ github.sha }})
          body_path: release-notes.md
          files: |
            output/*.bin
            output/drone.key
```

- [ ] **Step 2: Validate the workflow YAML**

Run (uses actionlint if present, else a YAML parse + key checks). The script handles
the PyYAML quirk where the key `on:` is parsed as the boolean `True`:
```bash
if command -v actionlint >/dev/null; then actionlint .github/workflows/build.yml; fi
python3 - <<'PY'
import yaml
text = open(".github/workflows/build.yml").read()
d = yaml.safe_load(text)
on = d.get("on", d.get(True))          # PyYAML may key `on:` as True
assert on["push"]["branches"] == ["master"], on
assert "workflow_dispatch" in on, on
assert d["permissions"]["contents"] == "write"
steps = d["jobs"]["build"]["steps"]
assert "WFB_REUSE_IMAGES=1 ./build.sh all" in text, "build step missing"
assert "softprops/action-gh-release@v2" in text, "release action missing"
assert "tag_name: latest" in text, "rolling tag missing"
print("workflow OK:", len(steps), "steps")
PY
```
Expected: `workflow OK: 9 steps` (and no actionlint errors if installed).

- [ ] **Step 3: Add the badge + latest-release link to `README.md`**

Insert immediately after the first heading line (`# wfb-ng firmware for TP-Link CPE510`):
```markdown

[![build](https://github.com/gilankpam/wfb-ng-openwrt/actions/workflows/build.yml/badge.svg)](https://github.com/gilankpam/wfb-ng-openwrt/actions/workflows/build.yml)

**[⬇ Download the latest firmware](https://github.com/gilankpam/wfb-ng-openwrt/releases/latest)** — built by CI from every push to `master` (rolling `latest` prerelease).
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build.yml README.md
git commit -m "Add rolling-build GitHub Actions workflow + README badge/link"
```

---

## Task 3: Create the public repo, push, and verify the first run

**Files:** none (publishing + verification).

**Interfaces:**
- Consumes: a committed `master` containing Tasks 1–2.
- Produces: the public repo `gilankpam/wfb-ng-openwrt` with `origin` set, and a green first workflow run that publishes the `latest` prerelease.

> This task performs an **irreversible, outward-facing** action (publishing a public repo, including the committed test keys). The user explicitly requested a public repo, so this is authorized; still confirm `master` is the intended content before pushing.

- [ ] **Step 1: Pre-flight — confirm clean state on master with the CI files present**

Run:
```bash
git branch --show-current && git status --short
ls .github/workflows/build.yml tests/test_build_reuse.sh
git log --oneline -3
```
Expected: on `master`, clean tree (nothing to commit), both files present, and the two new commits from Tasks 1–2 at the top.

- [ ] **Step 2: Create the public repo and push `master`**

Run:
```bash
gh repo create gilankpam/wfb-ng-openwrt --public --source=. --remote=origin --push \
  --description "Minimal wfb-ng ground-station firmware for the TP-Link CPE510 (OpenWrt 25.12)"
```
Expected: repo created, `origin` added, `master` pushed. Verify:
```bash
git remote -v
gh repo view gilankpam/wfb-ng-openwrt --json visibility,url
```
Expected: `origin` points to the new repo; `visibility` is `PUBLIC`.

- [ ] **Step 3: Watch the first workflow run to completion**

The push triggers the `build` workflow. Run:
```bash
gh run watch --exit-status "$(gh run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: the run finishes with **success** (exit 0). First run is ~25 min (cold GHA cache). If it fails, open the logs (`gh run view --log-failed`) and fix the cause (most likely a disk-space or action-version issue); re-run with `gh run rerun <id>` or push a fix.

- [ ] **Step 4: Verify the `latest` release assets**

Run:
```bash
gh release view latest --json assets --jq '.assets[].name' | sort
```
Expected: the six `…tplink_cpe510-v{1,2,3}-squashfs-{factory,sysupgrade}.bin` names plus `drone.key`.

- [ ] **Step 5: Verify the cache actually helps (second run is faster)**

Trigger a manual run and compare its duration to the first:
```bash
gh workflow run build.yml
sleep 5
gh run watch --exit-status "$(gh run list --workflow build.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run list --workflow build.yml --limit 2 --json durationMS,conclusion
```
Expected: both `success`; the second run materially shorter than the first (GHA cache hit on the SDK/IB layers) — roughly ~12–15 min vs ~25 min.

---

## Notes for the implementer

- **Public repos get free Actions minutes**, so build frequency is not cost-constrained; the ~25-min cold build and ~12–15-min warm builds are expected.
- **Disk** is the main runner risk; the `Free disk space` step removes the large preinstalled toolchains. If a run still fails on `No space left on device`, also remove `/usr/local/lib/node_modules` and run `sudo apt-get clean`.
- The workflow pins well-known actions to major tags (`@v4`/`@v6`/`@v3`/`@v2`); the disk-free step is inline (no third-party action) to avoid a floating dependency holding a `contents: write` token.
- `cache-to: mode=max` caches all intermediate layers (the SDK/IB tarball download + feed clones), which is what makes warm runs fast; it counts against the ~10 GB/repo GHA cache budget (LRU-evicted if exceeded).
