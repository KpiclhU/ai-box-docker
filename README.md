# ai-box-docker

The other half of the ai-box setup: a small Ubuntu VM on Proxmox running Docker, with
**Open WebUI**, **Open Terminal** and **OpenClaw** — each container on its own static address
on `192.168.150.0/24`.

The model box stays where it is. llama.cpp and ComfyUI live in the `ai-box` repository and are
reached over the LAN at `192.168.150.40`; nothing here does inference.

## What runs where

| Who | Address | Port | What it is |
|---|---|---|---|
| `open-webui` | `192.168.150.51` | 8080 | chat, per-person accounts, image workspace |
| `open-terminal` | `192.168.150.52` | 8000 | a container an agent can run commands in |
| `openclaw` | `192.168.150.53` | 18789 | gateway / assistant, control UI on `/` |
| `docker-vm` | `192.168.150.50` | 22 | the Ubuntu VM itself |
| `mv-shim` | `192.168.150.54` | — | host-side shim, so the VM can reach its own containers |

```
README.md                        this file
proxmox/create-vm.sh             runs on the Proxmox host: cloud image → VM → static IP
proxmox/cloud-init/user-data     installs Docker Engine + compose plugin at first boot
proxmox/cloud-init/meta-data     cloud-init identity
compose/docker-compose.yml       the three services, one macvlan address each
compose/.env.example             addresses, image tags, secrets
compose/install.sh               fills .env, builds the shim, starts the stack
compose/shim.sh                  up/down for the macvlan shim
compose/comfy/sdxl.api.json      the SDXL graph Open WebUI imports
compose/comfy/flux-schnell.api.json   the 4-step Flux alternative
```

## Why macvlan

A normal Docker stack would publish `-p 3000:8080` and let everything share the VM's address.
That gives you one IP and a port table to remember, and every service is only reachable while
the VM is. Instead each container gets a **real** address on the LAN: from the router's point
of view they are three separate machines with three separate MAC addresses.

```yaml
networks:
  lan:
    driver: macvlan
    driver_opts:
      parent: eth0
```

The costs, all real:

- **The VM cannot reach its own containers.** Macvlan children and their parent cannot talk:
  the traffic would have to leave `eth0` and come back to it. `compose/shim.sh` adds a second
  macvlan interface (`192.168.150.54`) plus a `/32` route per container, which is enough for
  `curl` and for debugging. Nothing in the stack depends on it — the containers talk to
  `192.168.150.40` and to each other.
- **The switch has to accept several MACs on that port.** A normal hypervisor bridge does;
  some managed switches have port security that does not. If a container can ping but not
  answer, look there first.
- **The addresses are yours to manage.** No DHCP, no DNS registration. Pick addresses outside
  the router's DHCP pool and either reserve them or leave them out of its range.

There are no published ports and no proxy. Every service is plain HTTP on the LAN, which is
also why nothing here should ever be port-forwarded.

## Requirements

- Proxmox VE 8 or 9, with a bridge on the LAN (`vmbr0`) and a storage for VM disks
  (`local-lvm` by default).
- A storage with the **snippets** content type enabled — cloud-init needs it:
  *Datacenter → Storage → local → Edit → Content → Snippets*.
- Five free addresses: `.50` for the VM, `.51`–`.53` for the containers, `.54` for the shim.
- The model box answering on `192.168.150.40:8080` (see the `ai-box` repository).

## 1. Create the VM (on the Proxmox host)

```bash
sudo ./proxmox/create-vm.sh --ssh-key /root/.ssh/id_ed25519.pub
```

It downloads the Ubuntu 24.04 cloud image once (cached under
`/var/lib/vz/template/iso/`), imports it, and creates `docker-vm`:

| Flag | Default | Note |
|---|---|---|
| `--vmid` | `150` | refuses an ID that already exists |
| `--ip` / `--gateway` | `192.168.150.50/24` / `192.168.150.1` | the VM's own address |
| `--cores` / `--memory` / `--disk` | `4` / `8192` / `40` | 8 GB is comfortable without a model |
| `--storage` | `local-lvm` | where the disk and the cloud-init drive go |
| `--bridge` | `vmbr0` | the LAN bridge |
| `--ssh-key` | — | public key for the admin user; omit it and a password is generated and printed |
| `--user` | `ai-admin` | cloud-init user |
| `--dry-run` | off | prints every `qm` command without running one |

First boot runs `ai-docker-bootstrap` from the cloud-init payload: Docker's apt repository,
`docker-ce`, `docker-compose-plugin`, and `/opt/ai-docker` owned by uid 1000. Give it two or
three minutes.

```bash
ssh ai-admin@192.168.150.50
docker compose version
```

## 2. Put the stack on the VM

```bash
git clone <this repo> ~/ai-docker
cd ~/ai-docker/compose
```

Or copy it, since the repository may be local-only: `scp -r compose ai-admin@192.168.150.50:~/ai-docker`

## 3. Install

```bash
sudo ./install.sh
```

In order, it:

1. copies `.env.example` to `.env` (mode 600) and generates the four secrets that are empty:
   `OPENWEBUI_SECRET_KEY`, `OPEN_TERMINAL_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`,
   `OPENWEBUI_ADMIN_PASSWORD` — re-running never replaces an existing one;
2. detects the LAN interface if `LAN_PARENT` names something that does not exist;
3. writes `open-webui.env` with the SDXL graph minified onto one line, so the first image
   needs no import in the UI;
4. creates `openclaw/` owned by **uid 1000**, which is what that image runs as;
5. brings up the macvlan shim and a systemd unit so it survives a reboot;
6. `docker compose up -d`, then waits for all three to answer and prints the addresses and
   the generated keys.

Re-run it after editing `.env`. `docker compose up -d` alone is enough for an image tag
change.

## 4. First run, per service

**Open WebUI** — `http://192.168.150.51:8080`. Sign in with `OPENWEBUI_ADMIN_EMAIL` and
`OPENWEBUI_ADMIN_PASSWORD` from `.env`, change the password, then *Admin → Settings → Users*
for one account per person (`ENABLE_SIGNUP=false`). The model connection is already
`http://192.168.150.40:8080/v1` from `.env`, and images are already ComfyUI at
`http://192.168.150.40:8188` with the SDXL graph.

**Open Terminal** — *Admin → Settings → Integrations → Terminal → +*: URL
`http://192.168.150.52:8000`, key `OPEN_TERMINAL_API_KEY`, auth `Bearer`. A quick check from
any machine on the LAN: `http://192.168.150.52:8000/docs`.

**OpenClaw** — `http://192.168.150.53:18789`, paste `OPENCLAW_GATEWAY_TOKEN` into Settings.
Finish onboarding first:

```bash
docker compose run --rm --no-deps --entrypoint node openclaw \
  dist/index.js onboard --mode local --no-install-daemon
```

Its model provider should be an OpenAI-compatible endpoint with base URL
`http://192.168.150.40:8080/v1`; llama-server does not check the key, so any non-empty value
works.

## Operations

```bash
cd ~/ai-docker/compose
docker compose ps
docker compose logs -f open-webui
docker compose pull && docker compose up -d      # update everything
docker compose up -d --force-recreate open-webui # recreate one service
```

State lives in named volumes `ai-docker_open-webui` and `ai-docker_open-terminal`, plus the
`openclaw/` directory next to the compose file. Back them up with the VM stopped, or with
`docker run --rm -v ai-docker_open-webui:/data -v "$PWD":/backup alpine tar czf
/backup/openwebui.tgz /data` while it runs.

Changing a container's address: edit that `*_IP` in `.env`, `docker compose up -d`, and if
other things point at it (the Open Terminal connection in Open WebUI, a bookmark) update them
too. Add the new address to `SHIM_IP`'s route set by re-running `install.sh`.

Undo the shim only: `sudo bash compose/shim.sh down` (and `systemctl disable --now
ai-docker-shim`).

## Security

- **The keys in `.env` are the whole lock.** `OPEN_TERMINAL_API_KEY` runs commands in a
  container that has passwordless `sudo`; `OPENCLAW_GATEWAY_TOKEN` controls the gateway. Both
  are generated locally, never hard-coded, and never leave `.env`.
- **No firewall on the VM, on purpose.** With macvlan there is no port publishing to trip over,
  and each service has its own login. If you want ufw anyway, allow `192.168.150.0/24` on the
  container addresses *and* keep SSH open — Docker's iptables rules are a separate layer and
  the shim looks like an outside host to the VM.
- **Nothing here is exposed to the internet.** No port forwarding, no tunnel. The model box is
  the same: one subnet, no accounts in front of llama.cpp.
- Open Terminal is a real shell for whoever holds the key, with an egress firewall inside the
  container by default. Treat the key like an SSH key.

## Honest status

Everything here is written against the projects' published Docker instructions but **none of it
has been run**: no VM has been created, `docker compose up` has never executed these files, and
the macvlan addresses, the shim and the three first-run flows are all untested. Treat the first
run as supervised, and read `docker compose logs` before assuming a service is happy just
because the container is `Up`.
