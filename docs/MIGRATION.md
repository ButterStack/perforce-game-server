# Migration Guide

Moving from another Perforce Docker image? This guide covers the differences and how to migrate.

## From hawkmoth-studio/docker-perforce

**What's different:**
- hawkmoth uses CentOS (EOL) — we use Ubuntu 24.04 LTS
- hawkmoth doesn't include REST API — we include the p4d 2025.2 REST API webserver
- hawkmoth has no game engine typemaps — we include comprehensive UE5, Unity, and common typemaps
- hawkmoth requires manual trigger setup — we auto-apply typemaps based on `ENGINE` env var

**Migration steps:**
1. Your Perforce data volume is compatible — mount it at `/data`
2. Update your `docker-compose.yml` to use our image/build
3. Set `ENGINE=unreal` or `ENGINE=unity` for automatic typemap
4. The server will run `p4d -xu` on startup to handle any schema upgrades

```yaml
# Before (hawkmoth)
services:
  perforce:
    image: hawkmoth/perforce
    volumes:
      - p4data:/perforce-data

# After (perforce-game-server)
services:
  perforce:
    build: ./dev
    environment:
      - ENGINE=unreal
    volumes:
      - p4data:/data  # Note: different mount path
```

> **Volume path change:** hawkmoth mounts at `/perforce-data`. We mount at `/data`. You may need to copy your data: `docker cp old-container:/perforce-data/. ./p4data && docker cp ./p4data new-container:/data/`

## From Snipe3000/helix-p4d-docker

**What's different:**
- Snipe3000 has a good UE typemap but no REST API or Unity support
- We include both dev and prod configurations
- We include SSL support in prod
- We auto-handle password expiration recovery

**Migration steps:**
1. Data volumes are compatible (both use `/data` or similar)
2. If you customized the Snipe3000 typemap, compare with our `shared/typemaps/unreal-engine.txt` — ours incorporates Snipe3000's best entries (PDB handling, compressed binary optimization)
3. Switch your compose file and set environment variables

## From HaberkornJonas/perforce-docker

**What's different:**
- HaberkornJonas is minimal (good for CI, less for game dev)
- No typemaps, no REST API, no game engine support
- We add all of that while keeping the Docker simplicity

**Migration:**
1. Replace the image in your compose file
2. Mount your data volume at `/data`
3. Set `ENGINE` and other env vars

## Preserving Existing Data

All configurations mount Perforce data at `/data`. On startup, the entrypoint:

1. Checks for existing `db.config` in the data directory
2. Runs `p4d -xu` (schema upgrade) — safe and idempotent
3. Verifies/creates the super user
4. Applies typemap (won't break existing file types in the depot)

**Your existing changelists, users, workspaces, and files are preserved.**

## Typemap Migration

If you have an existing typemap and want to keep it:

```bash
# Export your current typemap
p4 typemap -o > my-typemap.txt

# Set ENGINE=none to skip auto-typemap
docker compose up -d  # with ENGINE=none

# Apply your custom typemap
p4 typemap -i < my-typemap.txt
```

Or merge the best of both by comparing your typemap with ours:

```bash
# See what we'd apply
cat shared/typemaps/game-dev-common.txt
cat shared/typemaps/unreal-engine.txt

# Compare with yours
diff <(p4 typemap -o) shared/typemaps/unreal-engine.txt
```
